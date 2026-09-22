#!/usr/bin/env bash
# The station vault: one encrypted file, committed to the repo, holding
# everything that identifies or unlocks the station.
#
#   ./vault.sh lock      private/ (+ live secrets, if on erebus) -> station.vault
#   ./vault.sh unlock    station.vault -> private/
#   ./vault.sh list      what is inside, without extracting
#
# AES-256-CBC, key derived from your passphrase with PBKDF2 (600k rounds).
# Needs only openssl and tar: present on every Linux and in Git Bash on
# Windows. Lose the passphrase and the contents are gone; there is no
# recovery. Use a long one.
#
# What goes in:
#   private/STATION-PRIVATE.md    the doc with IPs, IDs, paths, users
#   private/station.env           values the k8s/ scripts read
#   private/secrets/              only when lock runs on erebus:
#       tor-kagchat/              the onion service key (the .onion address)
#       cloudflared/              tunnel credentials json + config.yml
set -euo pipefail
cd "$(dirname "$0")"
VAULT=station.vault
# Interactive prompt by default. VAULT_PASS=... in the environment skips it
# (for scripts); never put a passphrase on a command line, it lands in
# shell history.
PASS=(); [ -n "${VAULT_PASS:-}" ] && PASS=(-pass env:VAULT_PASS)

case "${1:-}" in
  lock)
    [ -d private ] || { echo "nothing to lock: private/ is missing (run unlock first, or create it)"; exit 1; }
    # A previous lock run under sudo leaves root-owned files behind; take them back.
    if [ -n "$(find private ! -user "$(id -u)" -print -quit 2>/dev/null)" ]; then
      sudo chown -R "$(id -u):$(id -g)" private
    fi
    chmod -R u+rwX private
    # Gather live secrets if this machine has them.
    if sudo -n test -d /var/lib/tor/kagchat 2>/dev/null || [ -d /var/lib/tor/kagchat ]; then
      mkdir -p private/secrets/tor-kagchat
      sudo cp -a /var/lib/tor/kagchat/. private/secrets/tor-kagchat/ && sudo chown -R "$(id -u):$(id -g)" private/secrets
      echo "included: tor onion key"
    fi
    if ls "$HOME"/.cloudflared/*.json >/dev/null 2>&1; then
      mkdir -p private/secrets/cloudflared
      cp "$HOME"/.cloudflared/*.json private/secrets/cloudflared/
      [ -f /etc/cloudflared/config.yml ] && cp /etc/cloudflared/config.yml private/secrets/cloudflared/
      echo "included: cloudflared credentials + config"
    fi
    chmod -R go-rwx private
    tar czf - -C private . | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt "${PASS[@]}" -out "$VAULT"
    echo "locked -> $VAULT ($(stat -c%s "$VAULT" 2>/dev/null || stat -f%z "$VAULT") bytes). Commit it. private/ stays on disk and is gitignored."
    ;;
  unlock)
    [ -f "$VAULT" ] || { echo "no $VAULT here"; exit 1; }
    mkdir -p private && chmod 700 private
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 "${PASS[@]}" -in "$VAULT" | tar xzf - -C private
    echo "unlocked -> private/"; find private -type f | sort | sed 's/^/   /'
    ;;
  list)
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 "${PASS[@]}" -in "$VAULT" | tar tzf - | sort
    ;;
  *)
    sed -n '2,20p' "$0"; exit 1 ;;
esac
