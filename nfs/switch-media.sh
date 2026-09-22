#!/usr/bin/env bash
# One-off: point the Kagflix nodes at the new `media` share on the Synology
# (Volume 1, SHR) instead of the old `docker/media` folder (Volume 2, single
# disk). Run from Erebus in the repo root, after the File Station copy has
# finished and a second pass has picked up the stragglers:
#
#   ./nfs/switch-media.sh
#
# What it does, in order:
#   1. scales jellyfin and qbittorrent to 0 so nothing holds /mnt/media
#   2. on each media host: backs up /etc/fstab, rewrites the SMB source,
#      remounts /mnt/media, lists it
#   3. scales both back to 1 and waits for them
# Re-runnable: if the fstab line already points at the new share it is left alone.
set -u
failed=0
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../kagchat/k8s/station-env.sh"
: "${GOON_IP:?add GOON_IP=... (the Synology) to private/station.env}"
OLD="//$GOON_IP/docker/media"
NEW="//$GOON_IP/media"
# the two nodes that mount the library: minos and rhadamantus, looked up in WORKERS
hosts=""
for pair in ${WORKERS:-}; do
  case "${pair%%=*}" in minos|rhadamantus) hosts="$hosts ${pair##*=}";; esac
done
[ -n "$hosts" ] || { echo "minos/rhadamantus not found in WORKERS"; exit 1; }

echo "=== stopping the pods that use /mnt/media ==="
sudo kubectl -n default scale deploy jellyfin qbittorrent --replicas=0
sudo kubectl -n default wait --for=delete pod -l app=jellyfin --timeout=90s 2>/dev/null || true
sudo kubectl -n default wait --for=delete pod -l app=qbittorrent --timeout=90s 2>/dev/null || true
sleep 3

for ip in $hosts; do
  echo
  echo "=== $ip ==="
  ssh -t -o ConnectTimeout=5 "$BOARD_USER@$ip" '
    set -e
    if grep -qF "'"$NEW"' " /etc/fstab; then
      echo "   fstab already points at '"$NEW"'"
    else
      sudo cp -a /etc/fstab /etc/fstab.bak-media-$(date +%Y%m%d)
      sudo sed -i "s|'"$OLD"' |'"$NEW"' |" /etc/fstab
      echo "   fstab rewritten (backup /etc/fstab.bak-media-*)"
    fi
    sudo systemctl daemon-reload
    sudo umount -l /mnt/media 2>/dev/null || true
    sudo mount /mnt/media
    findmnt -n -o SOURCE /mnt/media | grep -qF "'"$NEW"'"
    echo "   mounted: $(findmnt -n -o SOURCE /mnt/media)"
    echo "   top level: $(ls /mnt/media | tr "\n" " ")"
  ' || { echo "   failed on $ip"; failed=1; }
done

echo
echo "=== starting the pods again ==="
sudo kubectl -n default scale deploy jellyfin qbittorrent --replicas=1
sudo kubectl -n default rollout status deploy/jellyfin --timeout=180s
sudo kubectl -n default rollout status deploy/qbittorrent --timeout=180s
echo
[ "$failed" = 0 ] && echo "both hosts now mount $NEW at /mnt/media" || { echo "one host failed, see above; pods were started anyway"; exit 1; }
