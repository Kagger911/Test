// kagchat relay server.
//
// DESIGN RULE: this server is deliberately stupid. It moves opaque blobs of
// bytes between browsers. It cannot read messages, does not know channel
// names, does not know nicknames, and never touches an IP address.
//
// Everything a human would recognise (channel name, nickname, message text)
// is encrypted in the browser before it gets here. See web/index.html.
//
// What the server DOES know:
//   - a channel ID, which is a hash of the channel key (not the name)
//   - how many sockets are attached to that ID
//   - the size and timing of blobs
//
// That is the irreducible metadata. You cannot remove it without onion
// routing. Everything else has been stripped on purpose.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/redis/go-redis/v9"
)

// ---------------------------------------------------------------------------
// Tunables. Change these; nothing else in the file needs to move.
// ---------------------------------------------------------------------------

const (
	historyLen  = 200              // messages kept per channel for scrollback
	historyTTL  = 24 * time.Hour   // channel history self-destructs after this
	maxBlobSize = 16 * 1024        // reject anything larger (16 KB ciphertext)
	msgsPerMin  = 30               // per-socket rate limit
	pingEvery   = 30 * time.Second // keepalive; Cloudflare kills idle sockets ~100s

	// Presence: each pod records how many sockets it holds per room, in
	// Redis, with a short expiry. The room's "N here" is the sum over pods.
	// Nothing about *who* is counted, and nothing outlives the socket +
	// the expiry. This surfaces a number the relay already had to know.
	presenceTTL     = 90 * time.Second
	presenceRefresh = 30 * time.Second
)

// Channel IDs are client-generated hashes. Validate the shape so a hostile
// client cannot inject Redis key syntax or unbounded garbage.
var validChannelID = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)

// ---------------------------------------------------------------------------
// Wire format. Both directions use this single envelope.
// ---------------------------------------------------------------------------

type frame struct {
	Op   string   `json:"op"`             // join | msg | history | error
	Ch   string   `json:"ch,omitempty"`   // channel ID
	Body string   `json:"body,omitempty"` // base64 ciphertext blob (opaque)
	Msgs []string `json:"msgs,omitempty"` // scrollback, on op=history
	N    int      `json:"n,omitempty"`    // sockets in the room, on op=presence
	Err  string   `json:"err,omitempty"`  // human-readable failure reason
}

// ---------------------------------------------------------------------------
// Hub: tracks which local sockets care about which channel.
//
// With multiple pods, a message published on pod A must reach a subscriber on
// pod B. Redis pub/sub does that: every pod publishes to Redis and every pod
// listens to Redis, then fans out to its own local sockets.
// ---------------------------------------------------------------------------

type client struct {
	out      chan frame      // buffered; dropped-on-full means slow client
	channels map[string]bool // channels this socket has joined
}

type hub struct {
	mu   sync.RWMutex
	subs map[string]map[*client]bool // channelID -> set of local clients
}

func newHub() *hub {
	return &hub{subs: make(map[string]map[*client]bool)}
}

func (h *hub) join(ch string, c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subs[ch] == nil {
		h.subs[ch] = make(map[*client]bool)
	}
	h.subs[ch][c] = true
	c.channels[ch] = true
}

// leaveAll is called once when a socket closes.
func (h *hub) leaveAll(c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range c.channels {
		delete(h.subs[ch], c)
		if len(h.subs[ch]) == 0 {
			delete(h.subs, ch) // don't leak empty maps
		}
	}
}

// deliver pushes a blob to every local socket in a channel.
func (h *hub) deliver(ch, body string) {
	h.broadcast(ch, frame{Op: "msg", Ch: ch, Body: body})
}

// broadcast pushes a frame to every local socket in a channel.
// A full outbound buffer means that client is too slow; we drop the frame
// rather than block the whole pod. Chat is not worth head-of-line blocking.
func (h *hub) broadcast(ch string, f frame) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.subs[ch] {
		select {
		case c.out <- f:
		default:
		}
	}
}

// count is how many local sockets are in a channel.
func (h *hub) count(ch string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.subs[ch])
}

// active lists the channels with at least one local socket.
func (h *hub) active() []string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]string, 0, len(h.subs))
	for ch := range h.subs {
		out = append(out, ch)
	}
	return out
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

type server struct {
	hub *hub
	rdb *redis.Client
	pod string // this pod's name, the key suffix for its presence counts

	presMu   sync.Mutex
	presLast map[string]int // last total published per channel, to skip repeats
}

// presence records this pod's socket count for a room, sums every pod's
// count, and publishes the total so all pods tell their sockets. Called on
// join, on leave, and on a timer (to renew the expiry and to converge after
// a pod dies and its keys expire).
func (s *server) presence(ctx context.Context, ch string, force bool) {
	key := "n:" + ch + ":" + s.pod
	if n := s.hub.count(ch); n == 0 {
		s.rdb.Del(ctx, key)
	} else {
		s.rdb.Set(ctx, key, n, presenceTTL)
	}
	total := 0
	iter := s.rdb.Scan(ctx, 0, "n:"+ch+":*", 100).Iterator()
	for iter.Next(ctx) {
		if v, err := s.rdb.Get(ctx, iter.Val()).Int(); err == nil {
			total += v
		}
	}
	s.presMu.Lock()
	changed := s.presLast[ch] != total
	s.presLast[ch] = total
	s.presMu.Unlock()
	if changed || force {
		s.rdb.Publish(ctx, "pres:"+ch, strconv.Itoa(total))
	}
}

// presenceLoop renews this pod's counts before they expire. A pod that dies
// takes its keys with it within presenceTTL, and the survivors' next tick
// publishes the corrected total.
func (s *server) presenceLoop(ctx context.Context) {
	t := time.NewTicker(presenceRefresh)
	defer t.Stop()
	for range t.C {
		for _, ch := range s.hub.active() {
			s.presence(ctx, ch, false)
		}
	}
}

// build is the git commit the image was built from, set by the Dockerfile
// via -ldflags "-X main.build=...". Served at /version so anyone can diff
// the HTML they were given against that exact commit in the repo.
var build = "dev"

// onion is the service's .onion hostname, if one exists (ONION_ADDR, set
// by k8s/onion.sh). When set, clearnet responses carry an Onion-Location
// header, which Tor Browser turns into a ".onion available" prompt.
var onion = os.Getenv("ONION_ADDR")

// cspSources holds the script-src and style-src values: SHA-256 hashes of
// the exact <script> and <style> blocks in web/index.html, computed once at
// startup. With hashes instead of 'unsafe-inline', the browser runs only
// the blocks that shipped in the file: an inline snippet injected in
// transit, or by an XSS, does not match a hash and is refused. Editing
// index.html changes the hashes; they are recomputed on every start.
var cspScript, cspStyle = "'none'", "'none'"

func hashBlocks(html, tag string) string {
	re := regexp.MustCompile(`(?s)<` + tag + `>(.*?)</` + tag + `>`)
	var out []string
	for _, m := range re.FindAllStringSubmatch(html, -1) {
		sum := sha256.Sum256([]byte(m[1]))
		out = append(out, "'sha256-"+base64.StdEncoding.EncodeToString(sum[:])+"'")
	}
	if len(out) == 0 {
		return "'none'"
	}
	return strings.Join(out, " ")
}

func init() {
	b, err := os.ReadFile("./web/index.html")
	if err != nil {
		log.Printf("csp: cannot read web/index.html (%v); inline script and style will be blocked", err)
		return
	}
	cspScript = hashBlocks(string(b), "script")
	cspStyle = hashBlocks(string(b), "style")
	log.Printf("csp: script-src %s style-src %s", cspScript, cspStyle)
}

// secure wraps the file server with headers that make the browser refuse
// anything the page did not ship with. The important one is the CSP:
// only the hashed script and style blocks run, and media and connections
// are same-origin only, so anything injected in transit (a CDN's analytics
// beacon, an inline snippet) is blocked by the browser even if it makes it
// into the HTML. Anything in front of this server could still strip the
// header; the client trust problem does not go away, but this closes the
// accidental version of it.
func secure(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		// 'self' does not reliably cover ws:/wss: in every browser, so the
		// socket origin is spelled out from the Host the request came in on.
		h.Set("Content-Security-Policy",
			"default-src 'none'; script-src "+cspScript+"; style-src "+cspStyle+"; "+
				"connect-src 'self' ws://"+r.Host+" wss://"+r.Host+"; media-src 'self'; img-src 'self'; "+
				"base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		h.Set("Cache-Control", "no-store")
		h.Set("X-Kagchat-Build", build)
		if onion != "" && !strings.HasSuffix(r.Host, ".onion") {
			h.Set("Onion-Location", "http://"+onion+r.URL.RequestURI())
		}
		next.ServeHTTP(w, r)
	})
}

func main() {
	addr := envOr("LISTEN_ADDR", ":8080")
	redisAddr := envOr("REDIS_ADDR", "127.0.0.1:6379")

	// log.Lshortfile only. No request logging middleware anywhere in this
	// file — that is what leaks IPs. Do not add one.
	log.SetFlags(0)

	s := &server{
		hub: newHub(),
		rdb: redis.NewClient(&redis.Options{Addr: redisAddr}),
		pod: envOr("HOSTNAME", "relay"),

		presLast: make(map[string]int),
	}

	// Wait for Redis rather than die without it. If Redis is being moved to
	// another node this pod would otherwise crash-loop with a growing backoff
	// and take minutes to notice Redis is back; polling every 2s means it is
	// serving again within seconds of Redis returning.
	ctx := context.Background()
	for s.rdb.Ping(ctx).Err() != nil {
		log.Printf("waiting for redis at %s", redisAddr)
		time.Sleep(2 * time.Second)
	}

	go s.fanIn(ctx) // Redis -> local sockets
	go s.presenceLoop(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", s.handleWS)
	// Readiness: only claim healthy while Redis answers. A relay that cannot
	// publish is worse than one fewer relay, so the Service stops routing new
	// connections here until Redis is back. Existing sockets stay open.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		pctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := s.rdb.Ping(pctx).Err(); err != nil {
			http.Error(w, "redis: "+err.Error(), http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/version", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte(build))
	})
	// Serve the client from ./web so the whole thing is one container.
	mux.Handle("/", secure(http.FileServer(http.Dir("./web"))))

	log.Printf("listening on %s", addr)
	srv := &http.Server{
		Addr:    addr,
		Handler: mux,
		// No ErrorLog override: Go's default does not log client addresses
		// for normal requests, only for TLS handshake failures, which we
		// don't terminate here (the tunnel does).
	}
	log.Fatal(srv.ListenAndServe())
}

// fanIn subscribes to every channel topic in Redis and hands blobs to the
// local hub. One subscription for the whole pod, pattern-matched.
func (s *server) fanIn(ctx context.Context) {
	sub := s.rdb.PSubscribe(ctx, "ch:*", "pres:*")
	defer sub.Close()
	for m := range sub.Channel() {
		switch {
		case strings.HasPrefix(m.Channel, "pres:"):
			ch := m.Channel[len("pres:"):]
			n, _ := strconv.Atoi(m.Payload)
			s.hub.broadcast(ch, frame{Op: "presence", Ch: ch, N: n})
		default:
			ch := m.Channel[len("ch:"):]
			s.hub.deliver(ch, m.Payload)
		}
	}
}

func (s *server) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// OriginPatterns empty = same-origin only. Set this if you serve the
		// client from a different host than the API.
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return // do not log: the error string contains the remote address
	}
	defer conn.CloseNow()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	c := &client{
		out:      make(chan frame, 64),
		channels: make(map[string]bool),
	}
	// On close: leave every room, then tell each room it has one fewer
	// socket. The request context is gone by then, so use a fresh one.
	defer func() {
		s.hub.leaveAll(c)
		bg, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for ch := range c.channels {
			s.presence(bg, ch, false)
		}
	}()

	go s.writeLoop(ctx, conn, c)
	s.readLoop(ctx, conn, c)
}

// writeLoop owns the socket's write side. Exactly one goroutine may write to
// a websocket at a time, which is why this is separated from readLoop.
func (s *server) writeLoop(ctx context.Context, conn *websocket.Conn, c *client) {
	ping := time.NewTicker(pingEvery)
	defer ping.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case f := <-c.out:
			wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := writeJSON(wctx, conn, f)
			cancel()
			if err != nil {
				return
			}
		case <-ping.C:
			// Keepalive. Without this, Cloudflare closes idle sockets and
			// every quiet user silently disconnects after ~100 seconds.
			pctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := conn.Ping(pctx)
			cancel()
			if err != nil {
				return
			}
		}
	}
}

func (s *server) readLoop(ctx context.Context, conn *websocket.Conn, c *client) {
	conn.SetReadLimit(maxBlobSize + 1024) // blob + envelope overhead

	// Fixed-window rate limit, keyed to the socket and NOT to an IP — an
	// IP-keyed limiter would mean storing IPs, which defeats the point.
	// Kept inline (rather than in a ticker goroutine) so there is no shared
	// state and therefore no data race.
	sent := 0
	window := time.Now()

	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}

		var f frame
		if err := json.Unmarshal(data, &f); err != nil {
			s.fail(c, "malformed frame")
			continue
		}
		if !validChannelID.MatchString(f.Ch) {
			s.fail(c, "bad channel id")
			continue
		}

		switch f.Op {
		case "join":
			s.hub.join(f.Ch, c)
			s.sendHistory(ctx, c, f.Ch)
			// force: even if the total is unchanged (a reconnect), the
			// joining socket needs to hear the number once.
			s.presence(ctx, f.Ch, true)

		case "msg":
			if time.Since(window) >= time.Minute {
				window, sent = time.Now(), 0 // new window, reset the counter
			}
			if sent >= msgsPerMin {
				s.fail(c, "slow down")
				continue
			}
			sent++
			if len(f.Body) == 0 || len(f.Body) > maxBlobSize {
				s.fail(c, "blob rejected")
				continue
			}
			if err := s.publish(ctx, f.Ch, f.Body); err != nil {
				s.fail(c, "store unavailable")
			}

		default:
			s.fail(c, "unknown op")
		}
	}
}

// publish appends the blob to the channel's capped history and broadcasts it.
// Both run in one Redis round trip via a pipeline.
func (s *server) publish(ctx context.Context, ch, body string) error {
	key := "hist:" + ch
	pipe := s.rdb.Pipeline()
	pipe.RPush(ctx, key, body)
	pipe.LTrim(ctx, key, -historyLen, -1) // keep only the newest N
	pipe.Expire(ctx, key, historyTTL)     // sliding 24h window
	pipe.Publish(ctx, "ch:"+ch, body)
	_, err := pipe.Exec(ctx)
	return err
}

func (s *server) sendHistory(ctx context.Context, c *client, ch string) {
	msgs, err := s.rdb.LRange(ctx, "hist:"+ch, 0, -1).Result()
	if err != nil && !errors.Is(err, redis.Nil) {
		s.fail(c, "history unavailable")
		return
	}
	select {
	case c.out <- frame{Op: "history", Ch: ch, Msgs: msgs}:
	default:
	}
}

func (s *server) fail(c *client, reason string) {
	select {
	case c.out <- frame{Op: "error", Err: reason}:
	default:
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func writeJSON(ctx context.Context, conn *websocket.Conn, f frame) error {
	b, err := json.Marshal(f)
	if err != nil {
		return err
	}
	return conn.Write(ctx, websocket.MessageText, b)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
