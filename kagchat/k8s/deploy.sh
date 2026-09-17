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

if ! docker buildx inspect kagbuilder >/dev/null 2>&1; then
  echo "== creating buildx builder (once)"
  docker buildx create --name kagbuilder --config k8s/buildkitd.toml >/dev/null
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
