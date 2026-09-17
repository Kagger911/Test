#!/usr/bin/env bash
# The whole move to the cluster, from Erebus, in one go:
#
#   ./k8s/move.sh
#
#   1. registry container on Erebus (skipped if already running)
#   2. prep the four boards (registry trust, firewall, label)
#   3. build, push, deploy, wait for the pods, check /healthz
#   4. only if /healthz answered 200: point cloudflared at the cluster
#
# Stops at the first step that fails. The compose stack on :8081 is never
# touched, so if this stops early nothing has changed for anyone.
set -eu
cd "$(dirname "$0")/.."

echo "################ 1/4  registry on Erebus"
if docker ps --format '{{.Names}}' | grep -qx registry; then
  echo "already running"
else
  if ss -lnt | grep -q ':5000 '; then echo "port 5000 is taken by something that is not our registry:"; ss -lntp | grep ':5000 '; exit 1; fi
  docker run -d --name registry --restart=always -p 5000:5000 -v registry-data:/var/lib/registry registry:2 >/dev/null
  echo "started"
fi
for i in 1 2 3 4 5; do curl -sf http://127.0.0.1:5000/v2/ >/dev/null && break || sleep 1; done
curl -sf http://127.0.0.1:5000/v2/ >/dev/null && echo "answering on :5000" || { echo "registry not answering"; exit 1; }

echo
echo "################ 2/4  the four boards"
./k8s/prep-boards.sh

echo
echo "################ 3/4  build, push, deploy"
./k8s/deploy.sh

echo
echo "################ 4/4  tunnel"
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:30080/healthz || true)
if [ "$code" != "200" ]; then
  echo "cluster /healthz returned '$code', leaving cloudflared on the compose stack (:8081)"; exit 1
fi
if grep -q 'service: http://localhost:30080' /etc/cloudflared/config.yml; then
  echo "cloudflared already points at the cluster"
elif grep -q 'service: http://localhost:8081' /etc/cloudflared/config.yml; then
  sudo sed -i 's|service: http://localhost:8081|service: http://localhost:30080|' /etc/cloudflared/config.yml
  cloudflared tunnel ingress validate
  sudo systemctl restart cloudflared
  echo "cloudflared now points at the cluster (:30080)"
  echo "to go back:  sudo sed -i 's|localhost:30080|localhost:8081|' /etc/cloudflared/config.yml && sudo systemctl restart cloudflared"
else
  echo "could not find the chat entry in /etc/cloudflared/config.yml; tunnel left as is"; exit 1
fi

echo
echo "done. chat.sleepdeprivationstation.com is served by the boards."
echo "when you have confirmed it in a browser:  docker compose down   (retires the old stack)"
