#!/usr/bin/env bash
# Read-only look at NFS across the station, run from Erebus in the repo root:
#
#   ./nfs/check-nfs.sh
#
# Shows what the NAS exports, what the cluster provisioner points at, and for
# every node whether the NFS client is installed and the share is mounted.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../kagchat/k8s/station-env.sh"
: "${NAS_IP:?add NAS_IP=... to private/station.env}"
NAS_PATH="${NAS_PATH:-/nfs/Public}"
NAS_MOUNT="${NAS_MOUNT:-/mnt/nas}"

echo "=== NAS $NAS_IP exports ==="
showmount -e "$NAS_IP" 2>&1 || echo "   (showmount failed; install nfs-common on erebus or check the NAS NFS service)"

echo
echo "=== cluster ==="
sudo kubectl -n nfs-storage get deploy -o jsonpath='{range .items[*]}   provisioner {.metadata.name}: server={.spec.template.spec.containers[0].env[?(@.name=="NFS_SERVER")].value} path={.spec.template.spec.containers[0].env[?(@.name=="NFS_PATH")].value}{"\n"}{end}'
sudo kubectl get storageclass nfs-shared -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy 2>/dev/null | sed 's/^/   /'
echo "   PVCs on nfs-shared:"
sudo kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,SC:.spec.storageClassName,SIZE:.spec.resources.requests.storage | awk 'NR==1 || $4=="nfs-shared"' | sed 's/^/     /'

probe='
  hn=$(hostname)
  pkg=$(dpkg -l nfs-common 2>/dev/null | grep -c "^ii")
  if [ "$pkg" = 1 ]; then pkg=yes; else pkg=NO; fi
  if findmnt -n -t nfs,nfs4 '"$NAS_MOUNT"' >/dev/null 2>&1; then m="mounted"; else m="not mounted"; fi
  fs=$(grep -c "'"$NAS_IP:$NAS_PATH"'" /etc/fstab 2>/dev/null)
  if [ "$fs" != 0 ]; then fs="in fstab"; else fs="not in fstab"; fi
  root=$(df -h / | awk "NR==2{print \$4\" free on /\"}")
  printf "   %-14s nfs-common=%-3s %-12s %-13s %s\n" "$hn" "$pkg" "$m" "$fs" "$root"
'
echo
echo "=== nodes ==="
bash -c "$probe"
for pair in ${WORKERS:-} $BOARDS; do
  name="${pair%%=*}"; ip="${pair##*=}"
  ssh -o ConnectTimeout=5 -o BatchMode=yes "$BOARD_USER@$ip" "$probe" 2>/dev/null \
    || printf "   %-14s ssh failed (%s)\n" "$name" "$ip"
done
echo
echo "DONE"
