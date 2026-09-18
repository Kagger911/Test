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
. k8s/station-env.sh
LAN="${EREBUS_IP%.*}.0/24"
sed "s|REGISTRY|$REGISTRY|g" k8s/buildkitd.toml.tmpl > k8s/buildkitd.toml

# The registry must be reachable from the boards. If ufw is on, open 5000
# to the LAN (idempotent).
if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow from "$LAN" to any port 5000 proto tcp >/dev/null && echo "== ufw: 5000/tcp open to the LAN"
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
BUILD=$(git rev-parse --short=12 HEAD 2>/dev/null || echo dev)
docker buildx build --builder kagbuilder -f server/Dockerfile \
  --build-arg BUILD="$BUILD" \
  --platform linux/amd64,linux/arm64 -t "$IMAGE" --push .

echo "== applying manifests"
sed "s|\${REGISTRY}|$REGISTRY|g" k8s/kagchat.yaml | sudo kubectl apply -f - >/dev/null

# Keep the onion address on the deployment across applies, if there is one.
if sudo test -f /var/lib/tor/kagchat/hostname 2>/dev/null; then
  sudo kubectl -n kagchat set env deploy/relay ONION_ADDR="$(sudo cat /var/lib/tor/kagchat/hostname)" >/dev/null
fi

echo "== rolling the relay onto the new image"
sudo kubectl -n kagchat rollout restart deploy/relay >/dev/null
sudo kubectl -n kagchat rollout status deploy/relay --timeout=180s

echo
sudo kubectl -n kagchat get pods -o wide
echo
printf "healthz via NodePort on Erebus: "
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30080/healthz
