# Sleep Deprivation Station — infrastructure

The architecture and the runbooks. Everything that identifies a machine —
addresses, IDs, users, key locations — is in the **vault**, not here:

```bash
./vault.sh unlock        # asks for the passphrase -> private/
cat private/STATION-PRIVATE.md
```

## Shape

```
internet ──▶ Cloudflare ──tunnel──▶ erebus ──▶ NodePort ──▶ relay pods on the boards
Tor      ──▶ onion service on erebus ────────▶ same NodePort ──▶ same pods
LAN      ──▶ erebus registry :5000 ◀── boards pull the chat image
```

- **erebus** — amd64, K3s control plane and worker, Docker host. Runs the
  Cloudflare tunnel, the Tor hidden service, the private image registry, the
  buildx builder, Pi-hole (LAN DNS) and lancache. Single point of failure.
- **three more amd64 workers** — Kagflix and friends live here (exposed
  through the tunnel as `watch.`, `request.`, `signup.`).
- **four Khadas VIM3 boards** (arm64) — labelled `sds.role=chat`; the chat
  runs only on these.
- **The main site** is static on Netlify, deployed from `master` of the site
  repo; it is not behind the tunnel.

`kubectl` and `helm` on erebus need `sudo`; helm additionally needs
`KUBECONFIG=/etc/rancher/k3s/k3s.yaml` on the command line (sudo does not
pass the environment on this box).

## Cluster software

| Release | What | Notes |
|---|---|---|
| monitoring | kube-prometheus-stack | Grafana on a NodePort. Has a 5 Gi `local-path` PVC since rev 3; before that an emptyDir wiped it on every restart. Admin password lives in the `monitoring-grafana` secret. |
| nfs-provisioner | nfs-subdir-external-provisioner | storage class `nfs-shared` (RWX; **not** for SQLite) |
| traefik | K3s default ingress | |
| cert-manager | **failed** install | nothing depends on it; clean up before something does |

Storage classes: `local-path` (default; pins a pod to one node's disk),
`nfs-shared`.

## kagchat

End-to-end encrypted chat; the server relays ciphertext it cannot read.
`kagchat/README.md` is the full story. Operationally:

- Namespace `kagchat`: `redis` ×1 (memory only, 24 h TTL), `relay` ×3 spread
  across the boards, NodePort `30080`. Image pulled from the erebus registry.
- Two addresses: the clearnet hostname through the tunnel, and a v3 `.onion`
  through Tor on erebus. Same relay, same rooms. The clearnet address sends
  `Onion-Location`, so Tor Browser offers the `.onion` on its own.
- **Scripts** in `kagchat/k8s/`, run on erebus from the repo checkout. They
  read `private/station.env` (unlock the vault first):

  | Script | When |
  |---|---|
  | `deploy.sh` | every code change: build, push, roll, health-check (~30 s) |
  | `prep-boards.sh` | after re-imaging a board: registry trust, ufw, label |
  | `onion.sh` | create or repair the hidden service |
  | `failover-test.sh` | kill a relay and Redis on purpose, watch recovery |
  | `move.sh` | the original one-shot move; idempotent |

- **Failure behaviour:** a board dies → pods leave it after 20 s, the other
  relays keep serving, clients reconnect themselves. Redis dies → seconds of
  "store unavailable", scrollback gone (by design), relays wait and recover;
  `/healthz` says 503 until Redis answers. A PodDisruptionBudget keeps two
  relays through drains.
- **Security posture:** CSP with hashed `<script>`/`<style>` (no
  `unsafe-inline`), same-origin connect/media; build commit in the footer and
  at `/version`; signatures bound to the room; replay guard; no IP logged.
  Known limits: web-delivered client trust, no forward secrecy, clearnet
  metadata (use the `.onion`).
- The old docker-compose stack on erebus is retired; it remains a fallback
  (`docker compose up -d`, repoint the tunnel to `:8081`).

## Backups

The vault (`station.vault`, committed) holds, when locked **on erebus**: the
private doc, `station.env`, the Tor onion key (the `.onion` address), and the
tunnel credentials and config. Re-lock after anything changes. Keep a copy of
the vault *and* the passphrase somewhere that is not erebus.

Not backed up: Grafana's PVC (dashboards built in the UI, bookmarks, users),
and chat history (by design).

## Gaps, ranked

1. **erebus is everything.** A second cloudflared connector on another amd64
   worker, with the same tunnel credentials, would let the tunnel — chat and
   Kagflix — survive an erebus outage. Not done.
2. Redis is one pod (accepted).
3. cert-manager is in `failed` state.
4. Grafana's PVC pins it to one node and has no off-node copy.

## Runbooks

- **Update the chat:** `git pull && ./k8s/deploy.sh` in `kagchat/`, then
  `Ctrl+F5`.
- **Prove failover:** `./k8s/failover-test.sh` with a room open in two
  windows.
- **Check for injected scripts:** `curl -s <chat-url> | grep -c
  cloudflareinsights` → `0`.
- **Verify the served client:** footer `BUILD <sha>`, then `git show
  <sha>:kagchat/web/index.html | diff - <(curl -s <chat-url>)` — no output
  means identical.
- **Tunnel back to compose:** see kagchat above.
- **Re-image a board:** join it to K3s, `prep-boards.sh`, `deploy.sh`.
- **Rotate the vault passphrase:** `./vault.sh unlock` with the old one,
  `./vault.sh lock` with the new one, commit.
