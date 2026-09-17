#!/usr/bin/env bash
# Kill things on purpose and watch the chat stay up. Run on Erebus:
#
#   ./k8s/failover-test.sh
#
# Keep a room open in a browser while it runs, in two windows, and send a
# message after each step. The Redis step drops scrollback (by design).
set -u
K="sudo kubectl -n kagchat"
hz() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:30080/healthz; }
pods() { $K get pods -o wide --no-headers | awk '{printf "   %-28s %-12s %s\n",$1,$3,$7}'; }

echo "== before"; pods; echo "   healthz: $(hz)"

echo; echo "== 1. killing one relay pod"
victim=$($K get pods -l app=relay -o name | head -1)
$K delete "$victim" --wait=false >/dev/null
for i in $(seq 1 20); do
  ready=$($K get deploy relay -o jsonpath='{.status.readyReplicas}')
  printf "   t+%02ds ready relays: %s  healthz: %s\n" "$((i*2))" "${ready:-0}" "$(hz)"
  [ "${ready:-0}" = 3 ] && [ $i -gt 1 ] && break; sleep 2
done
pods

echo; echo "== 2. killing redis (scrollback is lost; relays wait, then recover)"
$K delete pod -l app=redis --wait=false >/dev/null
for i in $(seq 1 45); do
  code=$(hz); rr=$($K get deploy redis -o jsonpath='{.status.readyReplicas}')
  printf "   t+%02ds redis ready: %s  relay healthz: %s\n" "$((i*2))" "${rr:-0}" "$code"
  [ "$code" = 200 ] && [ $i -gt 2 ] && break; sleep 2
done
pods

echo; echo "== after: healthz $(hz)"
echo "send a message in the room now; both windows should see it."
