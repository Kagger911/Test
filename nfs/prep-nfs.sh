#!/usr/bin/env bash
# Put the NAS share on every node, run from Erebus in the repo root:
#
#   ./nfs/prep-nfs.sh
#
# Per node (erebus itself, the amd64 workers, the four VIM3s):
#   install nfs-common, create the mount point, add one fstab line, mount it,
#   then prove it works by writing a file from that node and reading it back
#   from erebus. Safe to run again: every step is idempotent.
#
# The fstab line uses nofail + x-systemd.automount, so a node still boots
# cleanly when the NAS is off, and the share mounts on first access.
set -u
failed=0
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../kagchat/k8s/station-env.sh"
: "${NAS_IP:?add NAS_IP=... to private/station.env}"
NAS_PATH="${NAS_PATH:-/nfs/Public}"
NAS_MOUNT="${NAS_MOUNT:-/mnt/nas}"
SRC="$NAS_IP:$NAS_PATH"
LINE="$SRC $NAS_MOUNT nfs defaults,_netdev,nofail,soft,timeo=150,retrans=3,x-systemd.automount,x-systemd.idle-timeout=600 0 0"

# runs on each node under sudo
step='
  set -e
  export DEBIAN_FRONTEND=noninteractive
  if ! dpkg -l nfs-common 2>/dev/null | grep -q "^ii"; then
    sudo apt-get -qq update && sudo apt-get -qq -y install nfs-common
  fi
  sudo mkdir -p "'"$NAS_MOUNT"'"
  if ! grep -qF "'"$SRC $NAS_MOUNT"'" /etc/fstab; then
    echo "'"$LINE"'" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo systemctl daemon-reload
  sudo mount -a 2>/dev/null || true
  ls "'"$NAS_MOUNT"'" >/dev/null       # first access triggers the automount
  findmnt -n -t nfs,nfs4 "'"$NAS_MOUNT"'" >/dev/null
  echo "$(hostname) $(date +%s)" | sudo tee "'"$NAS_MOUNT"'/.station-$(hostname)" >/dev/null
  echo "   ok: '"$NAS_MOUNT"' mounted, wrote .station-$(hostname)"
'

echo "=== erebus (local) ==="
bash -c "$step" || { echo "   failed on erebus"; failed=1; }

for pair in ${WORKERS:-} $BOARDS; do
  name="${pair%%=*}"; ip="${pair##*=}"
  echo
  echo "=== $name ($ip) ==="
  # -t so sudo can ask for a password if the node wants one
  ssh -t -o ConnectTimeout=5 "$BOARD_USER@$ip" "$step" || { echo "   failed on $name"; failed=1; }
done

echo
echo "=== seen from erebus at $NAS_MOUNT ==="
ls -l "$NAS_MOUNT"/.station-* 2>/dev/null | sed 's/^/   /' || echo "   nothing written yet"
rm -f "$NAS_MOUNT"/.station-* 2>/dev/null || sudo rm -f "$NAS_MOUNT"/.station-*
echo
[ "$failed" = 0 ] && echo "every node has $SRC on $NAS_MOUNT" || { echo "one or more nodes failed, see above"; exit 1; }
