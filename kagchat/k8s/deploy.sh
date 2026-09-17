#!/usr/bin/env bash
# Build the image for the boards, push it to the registry on Erebus, and
# roll the relay pods onto it. Run from Erebus in the kagchat directory,
# every time the code changes:
#
#   ./k8s/deploy.sh
#
# First run also creates the buildx builder. No QEMU: the Dockerfile
# compiles Go natively for arm64 and only the (empty) final image is arm64.
set -eu
cd "$(dirname "$0")/.."
IMAGE=10.0.0.202:5000/kagchat:latest

# The registry must be reachable from the boards. If ufw is on, open 5000
# to the LAN (idempotent).
if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow from 10.0.0.0/24 to any port 5000 proto tcp >/dev/null && echo "== ufw: 5000/tcp open to the LAN"
fi

# The builder runs with the host's network, so it reaches the registry the
# same way the shell does (no Docker bridge, no firewall in between), and
# it is told via buildkitd.toml that the registry is plain http. The flag
# for that file was renamed in newer buildx; try the new name first.
if docker buildx inspect kagbuilder 2>/dev/null | grep -q 'network=host'; then
  :
else
  docker buildx rm kagbuilder >/dev/null 2>&1 || true
  echo "== creating buildx builder (host network, http registry)"
  docker buildx create --name kagbuilder --driver-opt network=host --buildkitd-config k8s/buildkitd.toml >/dev/null 2>&1 \
    || docker buildx create --name kagbuilder --driver-opt network=host --config k8s/buildkitd.toml >/dev/null
fi

echo "== building amd64 + arm64 and pushing $IMAGE"
docker buildx build --builder kagbuilder -f server/Dockerfile \
  --platform linux/amd64,linux/arm64 -t "$IMAGE" --push .

echo "== applying manifests"
sudo kubectl apply -f k8s/kagchat.yaml >/dev/null

echo "== rolling the relay onto the new image"
sudo kubectl -n kagchat rollout restart deploy/relay >/dev/null
sudo kubectl -n kagchat rollout status deploy/relay --timeout=180s

echo
sudo kubectl -n kagchat get pods -o wide
echo
printf "healthz via NodePort on Erebus: "
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30080/healthz
