# Sleep Deprivation Station — infrastructure, as of 2026-09-18

What runs where, how traffic gets in, and how to operate it. Facts below were
read off the machines during setup; anything marked *(unverified)* was
inferred and should be checked before relying on it.

## Machines

| Node | IP | Arch | Role | Notes |
|---|---|---|---|---|
| **erebus** | 10.0.0.202 | amd64 | K3s **control plane** + worker | Docker host too. Tunnel, Tor, registry live here. Single point of failure (see Gaps). |
| aeacus | 10.0.0.91 | amd64 | K3s worker | |
| minos | 10.0.0.127 | amd64 | K3s worker | Hosts the `request.` service (port 5055) |
| rhadamantus | 10.0.0.229 | amd64 | K3s worker | Hosts `watch.` (30096) and `signup.` (30097) |
| goon-vim3-1 | 10.0.0.165 | arm64 | K3s worker, `sds.role=chat` | Khadas VIM3 |
| goon-vim3-2 | 10.0.0.192 | arm64 | K3s worker, `sds.role=chat` | |
| goon-vim3-3 | 10.0.0.19 | arm64 | K3s worker, `sds.role=chat` | |
| goon-vim3-4 | 10.0.0.26 | arm64 | K3s worker, `sds.role=chat` | |

K3s v1.36.x, containerd. `kubectl` and `helm` on erebus need `sudo`; helm
also needs `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` spelled out (sudo drops the
environment on this box; `-E` is not permitted).

SSH: `goon@<ip>`, key-based from erebus to every board. `kaggy` is the
Windows desktop; it is not part of the cluster.

## What runs on erebus outside the cluster (Docker / systemd)

| Service | How | Ports | Purpose |
|---|---|---|---|
| Pi-hole | Docker `pihole` | 53 tcp/udp, **8080** (admin) | LAN DNS. This is why the chat can never use 8080 on erebus. |
| lancache | Docker `lancache` | **80, 443** | Game download cache. Owns 80/443 on erebus. |
| registry | Docker `registry` (registry:2) | **5000** | Private image registry for the boards. Plain http on the LAN. Data in volume `registry-data`. |
| buildx builder | Docker `buildx_buildkit_kagbuilder0` | — | Builds the chat image (host network, http registry per `kagchat/k8s/buildkitd.toml`). |
| cloudflared | systemd `cloudflared` | outbound only | The tunnel. Config `/etc/cloudflared/config.yml`, credentials `/home/goon/.cloudflared/<tunnel-id>.json`. |
| tor | systemd `tor` | outbound only | Hidden service for the chat. Key in `/var/lib/tor/kagchat/` (**backed up to kaggy as `kagchat-onion-key.tgz`**). |
| Palworld | *(unverified: how it runs)* | | Game server; the reason a long build on erebus is noticeable. |

Firewall: ufw is active on erebus (5000/tcp opened to 10.0.0.0/24 for the
registry). ufw is **not** active on the four boards.

## Cloudflare tunnel (`kagflix`, id `4c672ebd-c9e5-4528-8280-70ec2044e800`)

Ingress in `/etc/cloudflared/config.yml`, in order:

| Hostname | Service | What it is |
|---|---|---|
| watch.sleepdeprivationstation.com | http://10.0.0.229:30096 | Kagflix media server *(unverified: Jellyfin)* |
| request.sleepdeprivationstation.com | http://10.0.0.127:5055 | Media requests *(unverified: Jellyseerr)* |
| signup.sleepdeprivationstation.com | http://10.0.0.229:30097 | Kagflix account signup |
| chat.sleepdeprivationstation.com | http://localhost:30080 | **kagchat** (NodePort on erebus → relay pods on the boards) |
| *(catch-all)* | http_status:404 | |

DNS for each hostname is a CNAME to `<tunnel-id>.cfargotunnel.com`, added
with `cloudflared tunnel route dns kagflix <hostname>`.

Cloudflare zone settings that matter for the chat: **Web Analytics automatic
injection is OFF** (it was injecting a beacon into the chat page; verified
`0` with `curl -s https://chat.sleepdeprivationstation.com/ | grep -c
cloudflareinsights`). A **Page Rule** for `chat.sleepdeprivationstation.com/*`
turns off Rocket Loader, Email Obfuscation and Browser Integrity Check.

The main site `sleepdeprivationstation.com` is **not** behind the tunnel: it
is a static site on Netlify, deployed automatically from the `master` branch
of `Kagger911/sleepdeprivationstation`.

## Helm releases (namespace)

| Release | Chart | State | Notes |
|---|---|---|---|
| monitoring (monitoring) | kube-prometheus-stack 88.5.4 | deployed, rev 3 | Grafana at **http://10.0.0.202:30030**. Now has a 5 Gi `local-path` PVC (`monitoring-grafana`); before rev 3 it was an emptyDir and lost everything on every restart. Admin password: `sudo kubectl -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' \| base64 -d` |
| nfs-provisioner (nfs-storage) | nfs-subdir-external-provisioner | deployed | Provides storage class `nfs-shared` |
| traefik / traefik-crd (kube-system) | traefik 40.x | deployed | K3s default ingress |
| cert-manager (cert-manager) | cert-manager v1.21.1 | **failed** | Install never completed. Nothing depends on it today. |

Storage classes: `local-path` (default; disk on the node the pod lands on;
pins the pod to that node) and `nfs-shared` (RWX, node-independent; **do not
use for SQLite databases** such as Grafana's).

## kagchat

End-to-end encrypted chat. The server relays ciphertext it cannot read. Full
detail in `kagchat/README.md`; operations summary here.

**Where:** namespace `kagchat`, pinned to `sds.role=chat` nodes (the four
boards). `redis` ×1 (memory only, no persistence, 24 h TTL), `relay` ×3
spread one per board. Service `relay` NodePort **30080** on every node.
Image `10.0.0.202:5000/kagchat:latest`, `imagePullPolicy: Always`.

**Addresses:**
- https://chat.sleepdeprivationstation.com — any browser, via the tunnel
- http://2gno4ryzyyi7xnhe7p576hf24csltd46qe2thhfvpyx5knno5v4dqhqd.onion — Tor
  Browser; no party in the path learns the user's IP. The clearnet address
  sends `Onion-Location` so Tor Browser offers it automatically.

**Source:** `Kagger911/Test`, branch `claude/erebus-docker-build-l5bm8z`,
directory `kagchat/`, checked out on erebus at `~/test/kagchat`.

**Scripts (`kagchat/k8s/`, run on erebus from `~/test/kagchat`):**

| Script | When |
|---|---|
| `deploy.sh` | **Every code change.** Builds amd64+arm64, pushes to the registry, rolls the relays one at a time, checks `/healthz`. ~30 s. |
| `move.sh` | The original one-shot move to the cluster. Idempotent; not needed again unless rebuilding. |
| `prep-boards.sh` | Board setup: registry trust (`registries.yaml` → `/etc/rancher/k3s/`), ufw ports if active, `sds.role=chat` label. Rerun after re-imaging a board. |
| `onion.sh` | Creates/repairs the Tor hidden service and tells the relay its address. |
| `failover-test.sh` | Kills a relay pod, then Redis, and prints recovery. Run with a room open. |

**Failure behaviour:** a board dies → its pods are rescheduled after 20 s
(tolerations), the other relays keep serving, clients reconnect on their own.
Redis dies or moves → a few seconds of "store unavailable", scrollback lost
(by design), relays wait and recover automatically; `/healthz` reports 503
until Redis answers so the service routes around unready relays. A
PodDisruptionBudget keeps ≥2 relays through drains.

**Security posture (after the community review):** strict CSP with hashed
`<script>`/`<style>` (no `unsafe-inline`), same-origin connect/media; build
commit in the footer and at `/version` for diffing the served client against
the repo; signatures bound to the room id; replay guard; no IP ever logged.
Known and documented: web-delivered client trust (ceiling of the model), no
forward secrecy (one static key per room; rotate the room), IP/timing
metadata visible on the clearnet address (use the `.onion`).

**Old compose stack:** retired (`docker compose down` on erebus). It can be
brought back as a fallback with `docker compose up -d` (host port 8081) and
`sudo sed -i 's|localhost:30080|localhost:8081|' /etc/cloudflared/config.yml
&& sudo systemctl restart cloudflared`.

## Backups that exist

| What | Where | Why it matters |
|---|---|---|
| Tor onion key | `/var/lib/tor/kagchat/` on erebus; copy on kaggy `C:\Users\Kags\kagchat-onion-key.tgz` | Without it the `.onion` address changes on rebuild. Restore with `sudo tar xzf kagchat-onion-key.tgz -C /` before `onion.sh`. |
| Tunnel credentials | `/home/goon/.cloudflared/4c672ebd-….json` on erebus | Without it the tunnel must be recreated and every DNS route redone. **Not backed up anywhere else yet.** |
| Grafana data | PVC `monitoring-grafana` (local-path, on whichever node the pod first landed) | Dashboards built in the UI, bookmarks, users. Not backed up off-node. |
| Chat history | nowhere, on purpose | Redis is memory-only. |

## Gaps / single points of failure

1. **erebus.** Control plane, tunnel, Tor, registry, DNS (Pi-hole) all on one
   box. Pods on the boards keep running if it dies, but nothing can reach
   them and the LAN loses DNS. Cheapest big win: a **second cloudflared
   connector on rhadamantus** with the same credentials — Cloudflare balances
   across connectors, and `localhost:30080` works there too, so the chat and
   Kagflix survive an erebus outage. Not done yet.
2. **Redis is one pod.** Acceptable given 24 h memory-only history; a move
   costs seconds and the scrollback.
3. **cert-manager** is in `failed` state. Harmless until something needs it;
   clean it up before it does.
4. **Tunnel credentials** have no off-box copy.
5. **Grafana PVC** pins Grafana to one node and has no off-node backup.

## Runbooks

**Update the chat** — `cd ~/test/kagchat && git pull && ./k8s/deploy.sh`,
then `Ctrl+F5` in the browser.

**Prove failover** — `./k8s/failover-test.sh` with a room open in two
windows.

**Grafana password** — see Helm table above.

**Tunnel back to the compose stack** — see "Old compose stack".

**Check the chat is clean of injected scripts** —
`curl -s https://chat.sleepdeprivationstation.com/ \| grep -c cloudflareinsights`
→ `0`.

**Verify the served client against the repo** — read `BUILD <sha>` from the
chat footer, then `git show <sha>:kagchat/web/index.html | diff - <(curl -s
https://chat.sleepdeprivationstation.com/)`; no output means identical.

**Re-image a board** — join it to K3s as before, then `./k8s/prep-boards.sh`
(idempotent for the others), then `./k8s/deploy.sh`.
