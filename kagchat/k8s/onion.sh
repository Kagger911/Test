#!/usr/bin/env bash
# Give the chat a Tor onion address, alongside the normal one. Run on
# Erebus, from the kagchat directory:
#
#   ./k8s/onion.sh
#
# Tor runs on Erebus and forwards the .onion to the cluster's NodePort on
# this machine. Users on Tor Browser reach the same relay and the same
# rooms, but nothing in the path learns both who they are and where they
# went: not Cloudflare (not involved), not Erebus (sees a Tor circuit, not
# an IP), not their ISP (sees Tor, not this site). Idempotent.
set -eu
cd "$(dirname "$0")/.."
TORRC=/etc/tor/torrc
DIR=/var/lib/tor/kagchat

if ! command -v tor >/dev/null 2>&1; then
  echo "== installing tor"
  sudo apt-get update -q && sudo apt-get install -y -q tor
fi

if ! sudo grep -q "HiddenServiceDir $DIR" "$TORRC"; then
  echo "== adding the hidden service to $TORRC"
  printf '\n# kagchat onion service (added by k8s/onion.sh)\nHiddenServiceDir %s/\nHiddenServicePort 80 127.0.0.1:30080\n' "$DIR" | sudo tee -a "$TORRC" >/dev/null
fi

sudo systemctl enable --now tor >/dev/null 2>&1 || true
sudo systemctl restart tor
for _ in $(seq 1 30); do sudo test -f "$DIR/hostname" && break; sleep 1; done
sudo test -f "$DIR/hostname" || { echo "tor did not create $DIR/hostname; check: sudo journalctl -u tor -n 30"; exit 1; }
ADDR=$(sudo cat "$DIR/hostname")

echo "== telling the relay its onion address (Onion-Location header)"
sudo kubectl -n kagchat set env deploy/relay ONION_ADDR="$ADDR" >/dev/null
sudo kubectl -n kagchat rollout status deploy/relay --timeout=180s >/dev/null

echo
echo "onion address:  http://$ADDR"
echo
echo "Open it in Tor Browser. Visitors on the clearnet address get a"
echo "'.onion available' prompt from Tor Browser automatically."
echo "The address is derived from a key in $DIR; back that directory up"
echo "if you ever want the same .onion on a rebuilt Erebus."
