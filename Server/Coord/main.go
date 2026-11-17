package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"math/big"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web/*
var embeddedWeb embed.FS

const (
	maxWSFrameBytes     = 65536
	maxCiphertextBase64 = 60000
	readIdleTimeout     = 90 * time.Second
	pingInterval        = 25 * time.Second
	clockSkewSeconds    = 300
)

type wireMessage struct {
	Type         string   `json:"type"`
	Role         string   `json:"role,omitempty"`
	HostID       string   `json:"hostID,omitempty"`
	ClientID     string   `json:"clientID,omitempty"`
	TargetHostID string   `json:"targetHostID,omitempty"`
	Name         string   `json:"name,omitempty"`
	SignPub      string   `json:"signPub,omitempty"`
	KexPub       string   `json:"kexPub,omitempty"`
	Timestamp    int64    `json:"ts,omitempty"`
	Nonce        string   `json:"nonce,omitempty"`
	Sig          string   `json:"sig,omitempty"`
	StunServers  []string `json:"stunServers,omitempty"`
	HostOnline   bool     `json:"hostOnline,omitempty"`
	HostSignPub  string   `json:"hostSignPub,omitempty"`
	HostKexPub   string   `json:"hostKexPub,omitempty"`
	HostName     string   `json:"hostName,omitempty"`

	// Zero-knowledge E2EE relay fields (server never decrypts).
	To          string `json:"to,omitempty"`
	From        string `json:"from,omitempty"`
	FromSignPub string `json:"fromSignPub,omitempty"`
	FromKexPub  string `json:"fromKexPub,omitempty"`
	Session     string `json:"session,omitempty"`
	Kind        string `json:"kind,omitempty"`
	E2ENonce    string `json:"e2eNonce,omitempty"`
	Ciphertext  string `json:"ciphertext,omitempty"`
	PayloadSig  string `json:"payloadSig,omitempty"`

	Error string `json:"error,omitempty"`
}

type peerConn struct {
	ws           *wsConn
	role         string // "host" or "client"
	id           string
	name         string
	signPub      string
	kexPub       string
	targetHostID string

	rateMu     sync.Mutex
	tokens     float64
	lastRefill time.Time
}

func (p *peerConn) allowRelay() bool {
	p.rateMu.Lock()
	defer p.rateMu.Unlock()
	now := time.Now()
	elapsed := now.Sub(p.lastRefill).Seconds()
	p.lastRefill = now
	p.tokens += elapsed * 25.0
	if p.tokens > 80.0 {
		p.tokens = 80.0
	}
	if p.tokens < 1.0 {
		return false
	}
	p.tokens -= 1.0
	return true
}

func (p *peerConn) send(msg wireMessage) error {
	b, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return p.ws.WriteText(b)
}

type coordHub struct {
	mu          sync.RWMutex
	hosts       map[string]*peerConn
	clients     map[string]*peerConn
	stunServers []string
}

func newCoordHub(stunServers []string) *coordHub {
	return &coordHub{
		hosts:       make(map[string]*peerConn),
		clients:     make(map[string]*peerConn),
		stunServers: stunServers,
	}
}

func parseP256SPKI(b64 string) (*ecdsa.PublicKey, []byte, error) {
	der, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil || len(der) < 64 || len(der) > 160 {
		return nil, nil, errors.New("invalid SPKI base64")
	}
	pubAny, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, nil, errors.New("invalid SPKI DER")
	}
	pub, ok := pubAny.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return nil, nil, errors.New("expected P-256 public key")
	}
	return pub, der, nil
}

func deriveDeviceID(spkiDER []byte) string {
	sum := sha256.Sum256(spkiDER)
	return hex.EncodeToString(sum[:16])
}

func verifyP1363Signature(pub *ecdsa.PublicKey, message string, sigB64 string) bool {
	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(sigB64))
	if err != nil || len(sig) != 64 {
		return false
	}
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	digest := sha256.Sum256([]byte(message))
	return ecdsa.Verify(pub, digest[:], r, s)
}

func validTimestamp(ts int64) bool {
	now := time.Now().Unix()
	diff := now - ts
	if diff < 0 {
		diff = -diff
	}
	return diff <= clockSkewSeconds
}

func sanitizeLabel(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 64 {
		s = s[:64]
	}
	return s
}

func isHexDeviceID(s string) bool {
	if len(s) != 32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func (h *coordHub) handleWS(w http.ResponseWriter, r *http.Request) {
	ws, err := upgradeWebSocket(w, r, maxWSFrameBytes)
	if err != nil {
		return
	}
	var self *peerConn
	done := make(chan struct{})
	defer func() {
		close(done)
		_ = ws.Close()
		if self != nil {
			h.unregister(self)
		}
	}()

	go func() {
		ticker := time.NewTicker(pingInterval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				if err := ws.Ping(); err != nil {
					_ = ws.Close()
					return
				}
			}
		}
	}()

	// First message within 15s must authenticate device identity.
	raw, err := ws.ReadText(15 * time.Second)
	if err != nil {
		return
	}
	var hello wireMessage
	if err := json.Unmarshal(raw, &hello); err != nil {
		_ = ws.WriteText([]byte(`{"type":"error","error":"invalid hello json"}`))
		return
	}
	peer, err := h.authenticate(ws, hello)
	if err != nil {
		_ = (&peerConn{ws: ws}).send(wireMessage{Type: "error", Error: err.Error()})
		return
	}
	self = peer

	for {
		data, err := ws.ReadText(readIdleTimeout)
		if err != nil {
			return
		}
		var msg wireMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			_ = self.send(wireMessage{Type: "error", Error: "invalid message json"})
			return
		}
		switch msg.Type {
		case "ping":
			_ = self.send(wireMessage{Type: "pong", Timestamp: time.Now().UnixMilli()})
		case "relay":
			if !self.allowRelay() {
				_ = self.send(wireMessage{Type: "error", Error: "relay rate limit exceeded"})
				continue
			}
			if err := h.forwardRelay(self, msg); err != nil {
				_ = self.send(wireMessage{Type: "error", Session: msg.Session, Error: err.Error()})
			}
		default:
			_ = self.send(wireMessage{Type: "error", Error: "unsupported message type"})
		}
	}
}

func (h *coordHub) authenticate(ws *wsConn, hello wireMessage) (*peerConn, error) {
	if !validTimestamp(hello.Timestamp) {
		return nil, errors.New("hello timestamp out of window")
	}
	if len(hello.Nonce) < 8 || len(hello.Nonce) > 64 {
		return nil, errors.New("invalid hello nonce")
	}
	signKey, signDER, err := parseP256SPKI(hello.SignPub)
	if err != nil {
		return nil, errors.New("invalid signPub")
	}
	if _, _, err := parseP256SPKI(hello.KexPub); err != nil {
		return nil, errors.New("invalid kexPub")
	}
	derivedID := deriveDeviceID(signDER)

	switch hello.Type {
	case "hostHello":
		if hello.HostID != derivedID {
			return nil, errors.New("hostID does not match signPub")
		}
		signed := "kkremote-host-hello-v1|" + hello.HostID + "|" + strings.TrimSpace(hello.KexPub) + "|" + strconv.FormatInt(hello.Timestamp, 10) + "|" + hello.Nonce
		if !verifyP1363Signature(signKey, signed, hello.Sig) {
			return nil, errors.New("invalid hostHello signature")
		}
		p := &peerConn{
			ws:         ws,
			role:       "host",
			id:         hello.HostID,
			name:       sanitizeLabel(hello.Name),
			signPub:    strings.TrimSpace(hello.SignPub),
			kexPub:     strings.TrimSpace(hello.KexPub),
			tokens:     80.0,
			lastRefill: time.Now(),
		}
		h.registerHost(p)
		_ = p.send(wireMessage{
			Type:        "welcome",
			Role:        "host",
			HostID:      p.id,
			StunServers: h.stunServers,
		})
		return p, nil

	case "clientHello":
		if hello.ClientID != derivedID {
			return nil, errors.New("clientID does not match signPub")
		}
		if !isHexDeviceID(hello.TargetHostID) {
			return nil, errors.New("invalid targetHostID")
		}
		signed := "kkremote-client-hello-v1|" + hello.ClientID + "|" + hello.TargetHostID + "|" + strings.TrimSpace(hello.KexPub) + "|" + strconv.FormatInt(hello.Timestamp, 10) + "|" + hello.Nonce
		if !verifyP1363Signature(signKey, signed, hello.Sig) {
			return nil, errors.New("invalid clientHello signature")
		}
		p := &peerConn{
			ws:           ws,
			role:         "client",
			id:           hello.ClientID,
			name:         sanitizeLabel(hello.Name),
			signPub:      strings.TrimSpace(hello.SignPub),
			kexPub:       strings.TrimSpace(hello.KexPub),
			targetHostID: hello.TargetHostID,
			tokens:       80.0,
			lastRefill:   time.Now(),
		}
		hostSnap := h.registerClient(p)
		welcome := wireMessage{
			Type:        "welcome",
			Role:        "client",
			ClientID:    p.id,
			StunServers: h.stunServers,
			HostOnline:  hostSnap != nil,
		}
		if hostSnap != nil {
			welcome.HostSignPub = hostSnap.signPub
			welcome.HostKexPub = hostSnap.kexPub
			welcome.HostName = hostSnap.name
		}
		_ = p.send(welcome)
		return p, nil

	default:
		return nil, errors.New("expected hostHello or clientHello")
	}
}

func (h *coordHub) registerHost(p *peerConn) {
	var old *peerConn
	var watchers []*peerConn
	h.mu.Lock()
	old = h.hosts[p.id]
	h.hosts[p.id] = p
	for _, c := range h.clients {
		if c.targetHostID == p.id {
			watchers = append(watchers, c)
		}
	}
	h.mu.Unlock()
	if old != nil && old != p {
		_ = old.ws.Close()
	}
	notice := wireMessage{
		Type:        "hostPresence",
		HostID:      p.id,
		HostOnline:  true,
		HostSignPub: p.signPub,
		HostKexPub:  p.kexPub,
		HostName:    p.name,
	}
	for _, c := range watchers {
		_ = c.send(notice)
	}
}

func (h *coordHub) registerClient(p *peerConn) *peerConn {
	var old *peerConn
	h.mu.Lock()
	old = h.clients[p.id]
	h.clients[p.id] = p
	host := h.hosts[p.targetHostID]
	h.mu.Unlock()
	if old != nil && old != p {
		_ = old.ws.Close()
	}
	return host
}

func (h *coordHub) unregister(p *peerConn) {
	var watchers []*peerConn
	h.mu.Lock()
	if p.role == "host" {
		if h.hosts[p.id] == p {
			delete(h.hosts, p.id)
			for _, c := range h.clients {
				if c.targetHostID == p.id {
					watchers = append(watchers, c)
				}
			}
		}
	} else if p.role == "client" {
		if h.clients[p.id] == p {
			delete(h.clients, p.id)
		}
	}
	h.mu.Unlock()
	if len(watchers) > 0 {
		notice := wireMessage{
			Type:       "hostPresence",
			HostID:     p.id,
			HostOnline: false,
		}
		for _, c := range watchers {
			_ = c.send(notice)
		}
	}
}

func (h *coordHub) forwardRelay(sender *peerConn, msg wireMessage) error {
	if !isHexDeviceID(msg.To) {
		return errors.New("invalid relay destination")
	}
	if len(msg.Session) < 8 || len(msg.Session) > 64 || len(msg.Kind) == 0 || len(msg.Kind) > 32 {
		return errors.New("invalid relay session or kind")
	}
	if len(msg.E2ENonce) == 0 || len(msg.E2ENonce) > 32 || len(msg.Ciphertext) == 0 || len(msg.Ciphertext) > maxCiphertextBase64 {
		return errors.New("invalid relay ciphertext envelope")
	}

	h.mu.RLock()
	var dest *peerConn
	if sender.role == "client" {
		if msg.To != sender.targetHostID {
			h.mu.RUnlock()
			return errors.New("client may only relay to its target host")
		}
		dest = h.hosts[msg.To]
	} else {
		c := h.clients[msg.To]
		if c != nil && c.targetHostID == sender.id {
			dest = c
		}
	}
	h.mu.RUnlock()

	if dest == nil {
		return errors.New("target peer is offline")
	}

	out := wireMessage{
		Type:        "relay",
		To:          msg.To,
		From:        sender.id,
		FromSignPub: sender.signPub,
		FromKexPub:  sender.kexPub,
		Session:     msg.Session,
		Kind:        msg.Kind,
		E2ENonce:    msg.E2ENonce,
		Ciphertext:  msg.Ciphertext,
		PayloadSig:  msg.PayloadSig,
	}
	return dest.send(out)
}

func (h *coordHub) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	h.mu.RLock()
	hosts := len(h.hosts)
	clients := len(h.clients)
	h.mu.RUnlock()
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok":            true,
		"service":       "kkremote-coord",
		"version":       1,
		"onlineHosts":   hosts,
		"onlineClients": clients,
		"stunCount":     len(h.stunServers),
	})
}

func buildMux(hub *coordHub) (http.Handler, error) {
	webSub, err := fs.Sub(embeddedWeb, "web")
	if err != nil {
		return nil, err
	}
	fileServer := http.FileServer(http.FS(webSub))
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/healthz", hub.handleHealthz)
	mux.HandleFunc("/v1/ws", hub.handleWS)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		fileServer.ServeHTTP(w, r)
	})
	return mux, nil
}

func parseStunEnv(raw string) []string {
	var out []string
	for _, item := range strings.Split(raw, ",") {
		item = strings.TrimSpace(item)
		if strings.HasPrefix(item, "stun:") {
			out = append(out, item)
		}
	}
	return out
}

func main() {
	listenAddr := strings.TrimSpace(os.Getenv("KKREMOTE_COORD_LISTEN"))
	if listenAddr == "" {
		listenAddr = "127.0.0.1:18480"
	}
	stunServers := parseStunEnv(os.Getenv("KKREMOTE_STUN_URLS"))
	hub := newCoordHub(stunServers)
	handler, err := buildMux(hub)
	if err != nil {
		log.Fatalf("failed to mount embedded web assets: %v", err)
	}
	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("kkremote-coord listening on %s (stun endpoints: %d)", listenAddr, len(stunServers))
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server exited: %v", err)
	}
}
