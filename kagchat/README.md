# kagchat

End-to-end encrypted chat. The server relays blobs it cannot read.

## Getting it onto Erebus

No zip, no scp, no rebuilding the folder structure by hand. Pull it straight
from git on the box that is going to build it:

```bash
ssh goon@10.0.0.202
git clone -b claude/erebus-docker-build-l5bm8z https://github.com/kagger911/test.git
cd test/kagchat
```

Everything below runs from that `kagchat/` directory — it is the build context
the Dockerfile expects (`COPY server/...`, `COPY web`), so do not run docker
from `server/`.

## What each piece does

| Path | Role |
|---|---|
| `server/main.go` | WebSocket relay. Never sees plaintext, never logs an IP. |
| `web/index.html` | The whole client. All encryption happens here. |
| `server/Dockerfile` | Multi-arch build (amd64 + arm64). |
| `k8s/kagchat.yaml` | Redis + 3 relay pods, pinned to labelled nodes. |
| `docker-compose.yml` | Local test stack. Start here. |

## Run it locally first

Requires Docker. Nothing else.

```bash
docker compose up --build
```

It listens on host port **8081** (Pi-hole has 8080 on Erebus). To use a
different port for one run:

```bash
KAGCHAT_PORT=8090 docker compose up --build
```

Open <http://localhost:8081>, click **Open a new room**, then paste the same
URL into a second browser window. Both windows are now in the same room.

Testing from another machine, do **not** browse to `http://10.0.0.202:8081`.
Browsers only expose the encryption API (`crypto.subtle`) in a secure context:
https, or a localhost address. A plain-http LAN IP is neither, so the client
cannot start; it tells you so on the entry screen instead of hanging. Tunnel it
to localhost instead:

```bash
ssh -L 8081:localhost:8081 goon@10.0.0.202     # leave this open
```

then browse to <http://localhost:8081>. This affects LAN testing only — behind
the tunnel on https it is a secure context and the restriction disappears.

The address bar will look like:

```
http://localhost:8081/#k=xkQ2...43-characters...9fA
```

Everything after the `#` is the room key. Browsers never send that part to the
server, which is the whole mechanism.

To confirm the server really cannot read anything:

```bash
docker compose exec redis redis-cli --scan
docker compose exec redis redis-cli lrange hist:<the-id-from-above> 0 -1
```

You will see base64 noise. That is what is stored, and it is all that is
stored.

Stop with `docker compose down`. Redis is memory-only, so that erases
everything.

## Build and push

The cluster is mixed architecture. A single-arch image will crash-loop on half
the nodes with `exec format error`, so build both:

Run from the `kagchat/` directory, not from `server/`.

```bash
docker buildx create --use --name kagbuilder   # once

docker buildx build -f server/Dockerfile \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/kagger911/kagchat:latest \
  --push .
```

Change the image name in `k8s/kagchat.yaml` to match.

Erebus is amd64 and the VIM3s are arm64, so the arm64 half of that build needs
emulation registered once per boot:

```bash
docker run --privileged --rm tonistiigi/binfmt --install all
```

A two-platform build will saturate every core on Erebus for a minute or two.
Palworld players will feel it.

## Deploy

```bash
for n in goon-vim3-1 goon-vim3-2 goon-vim3-3 goon-vim3-4; do
  kubectl label node $n sds.role=chat
done

kubectl apply -f k8s/kagchat.yaml
kubectl -n kagchat rollout status deploy/relay
```

## Expose through the existing tunnel

Add to `config.yml` on Erebus, alongside the `watch.` and `request.` entries:

```yaml
  - hostname: chat.sleepdeprivationstation.com
    service: http://10.0.0.202:30080
```

Then `systemctl restart cloudflared` and add the DNS route.

## Firewall

Same class of problem that broke Grafana. On every node carrying a relay pod:

```bash
sudo ufw allow 8472/udp        # flannel VXLAN
sudo ufw allow 10250/tcp       # kubelet
sudo ufw allow from 10.42.0.0/16   # pod CIDR
sudo ufw allow from 10.43.0.0/16   # service CIDR
sudo ufw allow 30080/tcp       # this NodePort
sudo ufw reload
```

Without these, messages will appear to deliver only when both users happen to
be served by pods on the same board.

## Using it

Open `https://chat.sleepdeprivationstation.com`, click **Open a new room**, and
send the resulting URL to whoever should be in it. The key is the part after
the `#`. Browsers never transmit that, so the server cannot learn it.

Anyone holding the link can read the room, permanently. There is no revocation.
To remove someone, make a new room.

## What is and is not hidden

Hidden from the server and from anything in front of it:

- message text
- nicknames
- the room's human-readable name (the server only sees `SHA-256(key)`)

Not hidden:

- your IP address, from whatever terminates the connection — currently
  Cloudflare. Encryption cannot fix this.
- that *someone* connected, when, and roughly how much they typed.

Removing the IP exposure requires an onion service, not a code change.

## Deliberate omissions

Do not add these without understanding what they cost:

- **HTTP access logging.** Any standard logging middleware writes client IPs.
  The server has none for this reason.
- **IP-based rate limiting.** Would require storing IPs. The limiter is keyed
  to the socket instead.
- **Web fonts or CDN assets.** One external request hands your visitor list to
  a third party and undoes the encryption work.
- **Redis persistence.** Turning it on puts readable-by-nobody blobs on eMMC
  and creates something seizable.

## Known limits

- One Redis, no failover. It restarts, scrollback is gone. Acceptable given
  the 24h TTL; not acceptable if you later want durable history.
- Signing needs Ed25519 in WebCrypto (Chrome 137+, Firefox 129+, Safari 17+).
  Older browsers still work, but their messages show a red `?` next to the
  nickname and cannot be verified.
- No moderation tools. Anyone with the link can post until you rotate the room.
