#!/usr/bin/env bash
# One-time prep of the four VIM3 boards, run from Erebus in the kagchat
# directory. Safe to run again: every step is idempotent.
#
#   ./k8s/prep-boards.sh
#
# Per board:  registries.yaml -> /etc/rancher/k3s/, restart the k3s agent,
#             open the firewall ports the pods need (only if ufw is active),
#             label the node sds.role=chat so the manifest can pin to it.
set -u
failed=0
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/station-env.sh"
USER_ON_BOARD="$BOARD_USER"
# registries.yaml is written from the env, not shipped with an IP in it
sed "s|REGISTRY|$REGISTRY|g" "$HERE/registries.yaml.tmpl" > "$HERE/registries.yaml"

for pair in $BOARDS; do
  name="${pair%%=*}"; ip="${pair##*=}"
  echo
  echo "=== $name ($ip) ==="
  scp -q "$HERE/registries.yaml" "$USER_ON_BOARD@$ip:/tmp/registries.yaml" || { echo "   scp failed, skipping"; failed=1; continue; }
  # -t so sudo can ask for a password if the board wants one
  ssh -t "$USER_ON_BOARD@$ip" '
    set -e
    sudo install -D -m 644 /tmp/registries.yaml /etc/rancher/k3s/registries.yaml
    sudo systemctl restart k3s-agent
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
      sudo ufw allow 8472/udp  >/dev/null   # flannel VXLAN between nodes
      sudo ufw allow 10250/tcp >/dev/null   # kubelet
      sudo ufw allow from 10.42.0.0/16 >/dev/null   # pod CIDR
      sudo ufw allow from 10.43.0.0/16 >/dev/null   # service CIDR
      sudo ufw allow 30080/tcp >/dev/null   # the kagchat NodePort
      echo "   ufw: rules present"
    else
      echo "   ufw: not active, nothing to open"
    fi
    echo "   registry trust installed, k3s-agent restarted"
  ' || { echo "   ssh step failed on $name"; failed=1; continue; }
  sudo kubectl label node "$name" sds.role=chat --overwrite >/dev/null && echo "   labelled sds.role=chat"
done

echo
echo "Labelled nodes:"
sudo kubectl get nodes -l sds.role=chat -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,READY:.status.conditions[-1].type
[ "$failed" = 0 ] || { echo; echo "one or more boards failed, see above"; exit 1; }
