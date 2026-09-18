# Sourced by the k8s/ scripts. Loads private/station.env (from the vault)
# and refuses to run without it, so no IP or ID has to live in git.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_env="$_here/private/station.env"
if [ ! -f "$_env" ]; then
  echo "private/station.env is missing. Run ./vault.sh unlock in the repo root first." >&2
  exit 1
fi
set -a; . "$_env"; set +a
: "${REGISTRY:?}" "${BOARDS:?}" "${BOARD_USER:?}" "${EREBUS_IP:?}"
IMAGE="$REGISTRY/kagchat:latest"
