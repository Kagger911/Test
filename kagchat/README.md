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
| `k8s/prep-boards.sh` | One-time board setup: registry trust, firewall, label. |
| `k8s/deploy.sh` | Build for arm64, push to the Erebus registry, roll the pods. |
| `k8s/move.sh` | All of the above plus the tunnel switch, in one run. |
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

A room can carry a name in the same place — `#k=...&n=friends` — typed into the
**Room name** box in the rail. It rides in the link and the tab title, and
never reaches the server either. It is a label, not a credential: knowing a
room's name opens nothing without its key.

While a tab is in the background, the title shows an unread count and a soft
synthesised tone plays on arrival. Entering a room plays a short riff
(`web/join.mp3`, served by the relay itself — still no third party), once per
room per tab, at 60% volume. **sound: on/off** in the rail mutes both, per
browser.

To confirm the server really cannot read anything:

```bash
docker compose exec redis redis-cli --scan
docker compose exec redis redis-cli lrange hist:<the-id-from-above> 0 -1
```

You will see base64 noise. That is what is stored, and it is all that is
stored.

Stop with `docker compose down`. Redis is memory-only, so that erases
everything.

## Moving it onto the VIM3s

Erebus is the K3s control plane; the four boards are arm64 workers. One
command does the whole move from Erebus:

```bash
./k8s/move.sh
```

It runs the four steps below in order and stops at the first that fails; the
compose stack on `:8081` is never touched, so a failed run changes nothing for
users. The steps are also runnable on their own. `kubectl` needs `sudo` on
Erebus; the scripts include it.

### 1. A registry on Erebus (once)

The boards need somewhere to pull the image from. One container, LAN only, no
accounts. Check the port is free first:

```bash
ss -lntp | grep :5000 || echo "5000 is free"
docker run -d --name registry --restart=always -p 5000:5000 \
  -v registry-data:/var/lib/registry registry:2
```

### 2. Prep the boards (once)

```bash
./k8s/prep-boards.sh
```

Per board: installs `k8s/registries.yaml` so K3s trusts the registry over
plain http, restarts the agent, opens the firewall ports if ufw is on, and
labels the node `sds.role=chat`. Everything in the manifest is pinned to that
label, so nothing drifts onto Erebus, Minos, Rhadamantus or Aeacus. `sudo` on
a board may ask for a password.

### 3. Build, push, deploy (every time the code changes)

```bash
./k8s/deploy.sh
```

Builds the image for amd64 + arm64, pushes it to the registry, applies the
manifests, restarts the relay pods onto the new image, and hits `/healthz`
through the NodePort. No QEMU: the Dockerfile compiles Go natively for arm64
and only the empty final image is arm64, so the build costs Erebus a normal Go
compile, nothing more.

First run creates a buildx builder using `k8s/buildkitd.toml`, which tells
BuildKit the registry is http. Nothing under `/etc/docker` changes, so the
Docker daemon is never restarted and Pi-hole never blinks.

### 4. Repoint the tunnel

The compose stack on `:8081` and the cluster on `:30080` can run side by side.
Once `deploy.sh` reports `healthz via NodePort on Erebus: 200`:

```bash
sudo sed -i 's|service: http://localhost:8081|service: http://localhost:30080|' /etc/cloudflared/config.yml
cloudflared tunnel ingress validate
sudo systemctl restart cloudflared
```

Then, when the site is confirmed working on the cluster, retire the compose
stack: `docker compose down`.

### Firewall

Same class of problem that broke Grafana. `prep-boards.sh` opens these on
each board when ufw is active; here they are for reference:

```bash
sudo ufw allow 8472/udp            # flannel VXLAN
sudo ufw allow 10250/tcp           # kubelet
sudo ufw allow from 10.42.0.0/16   # pod CIDR
sudo ufw allow from 10.43.0.0/16   # service CIDR
sudo ufw allow 30080/tcp           # this NodePort
```

Without these, messages appear to deliver only when both users happen to be
served by pods on the same board.

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

## Trusting the client you were served

This is a web app, so the encryption runs in code the server hands you. If
the server, or anything between it and you, hands you different code, your
browser will run that instead. No web-delivered E2E system escapes this;
Signal's web client has the same property. What this project does about it:

- **The client is one file, in a public repo.** `web/index.html` is all of
  it. Nothing is bundled, minified or fetched from elsewhere.
- **Every page tells you its commit.** The footer shows `BUILD <sha>`, served
  from `/version`, baked into the binary at build time. Diff what you got:

  ```bash
  git show <sha>:kagchat/web/index.html | diff - <(curl -s https://chat.sleepdeprivationstation.com/)
  ```

  No output means byte-for-byte the published file.
- **A strict Content-Security-Policy** is sent with the page: scripts,
  styles, media and connections are same-origin only. Anything injected
  into the HTML in transit — a CDN's analytics beacon, for example — is
  refused by the browser even if it reaches you. Check with the Network tab:
  there should be exactly one host.
- **The relay never logs an IP**, and Cloudflare's optional injections must
  stay off for this hostname: Web Analytics, Rocket Loader, email
  obfuscation and the JS challenge. The CSP blocks their scripts anyway, but
  a page that tries to load a beacon and is refused still looks wrong in a
  network log.

What it does not do: prove the relay operator is honest. A malicious
operator could serve a client that leaks keys. The build tag and the diff
above make that visible after the fact, not impossible.

## Deliberate omissions

Do not add these without understanding what they cost:

- **HTTP access logging.** Any standard logging middleware writes client IPs.
  The server has none for this reason.
- **IP-based rate limiting.** Would require storing IPs. The limiter is keyed
  to the socket instead.
- **Web fonts or CDN assets.** One external request hands your visitor list to
  a third party and undoes the encryption work. The intro sound is fine
  because the relay serves it; a sound hosted anywhere else would not be.
- **Redis persistence.** Turning it on puts readable-by-nobody blobs on eMMC
  and creates something seizable.

## Known limits

- One Redis, no failover. It restarts, scrollback is gone. Acceptable given
  the 24h TTL; not acceptable if you later want durable history.
- Signing needs Ed25519 in WebCrypto (Chrome 137+, Firefox 129+, Safari 17+).
  Older browsers still work, but their messages show a red `?` next to the
  nickname and cannot be verified.
- No moderation tools. Anyone with the link can post until you rotate the room.
- **No forward secrecy.** One static key per room. Anyone who obtains the link
  can read everything still in the 24h window and everything after. Rotating
  the room (new link) is the only remedy. A ratcheting scheme would fix this
  and is a large change.
- Signatures are bound to the room id, so a message signed in one room does
  not verify in another, and each browser paints a given signature once per
  session, so re-sending an old blob does not produce a second message. This
  is per-browser and per-session; it is a nuisance guard, not a protocol
  guarantee.
