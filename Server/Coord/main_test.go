package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"net/http/httptest"
	"net/url"
	"strconv"
	"testing"
	"time"
)

type testIdentity struct {
	id      string
	signKey *ecdsa.PrivateKey
	signPub string
	kexPub  string
}

func makeIdentity(t *testing.T) testIdentity {
	t.Helper()
	signPriv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	kexPriv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signDER, err := x509.MarshalPKIXPublicKey(&signPriv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	kexDER, err := x509.MarshalPKIXPublicKey(&kexPriv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return testIdentity{
		id:      deriveDeviceID(signDER),
		signKey: signPriv,
		signPub: base64.StdEncoding.EncodeToString(signDER),
		kexPub:  base64.StdEncoding.EncodeToString(kexDER),
	}
}

func (id testIdentity) signP1363(t *testing.T, text string) string {
	t.Helper()
	digest := sha256.Sum256([]byte(text))
	r, s, err := ecdsa.Sign(rand.Reader, id.signKey, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	var raw [64]byte
	r.FillBytes(raw[:32])
	s.FillBytes(raw[32:])
	return base64.StdEncoding.EncodeToString(raw[:])
}

type testWSClient struct {
	conn net.Conn
	r    *bufio.Reader
}

func dialWS(t *testing.T, rawURL string) *testWSClient {
	t.Helper()
	u, err := url.Parse(rawURL)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.DialTimeout("tcp", u.Host, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	req := "GET " + u.RequestURI() + " HTTP/1.1\r\n" +
		"Host: " + u.Host + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		t.Fatal(err)
	}
	r := bufio.NewReader(conn)
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if line == "\r\n" {
			break
		}
	}
	return &testWSClient{conn: conn, r: r}
}

func (c *testWSClient) sendJSON(t *testing.T, v any) {
	t.Helper()
	payload, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var mask [4]byte
	_, _ = rand.Read(mask[:])
	var frame []byte
	frame = append(frame, 0x81)
	if len(payload) < 126 {
		frame = append(frame, 0x80|byte(len(payload)))
	} else {
		frame = append(frame, 0x80|126, byte(len(payload)>>8), byte(len(payload)))
	}
	frame = append(frame, mask[:]...)
	for i, b := range payload {
		frame = append(frame, b^mask[i&3])
	}
	if _, err := c.conn.Write(frame); err != nil {
		t.Fatal(err)
	}
}

func (c *testWSClient) recvJSON(t *testing.T) wireMessage {
	t.Helper()
	_ = c.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	for {
		var hdr [2]byte
		if _, err := io.ReadFull(c.r, hdr[:]); err != nil {
			t.Fatal(err)
		}
		opcode := hdr[0] & 0x0F
		length := uint64(hdr[1] & 0x7F)
		if length == 126 {
			var ext [2]byte
			if _, err := io.ReadFull(c.r, ext[:]); err != nil {
				t.Fatal(err)
			}
			length = uint64(binary.BigEndian.Uint16(ext[:]))
		}
		buf := make([]byte, int(length))
		if _, err := io.ReadFull(c.r, buf); err != nil {
			t.Fatal(err)
		}
		if opcode == opPing {
			continue
		}
		var m wireMessage
		if err := json.Unmarshal(buf, &m); err != nil {
			t.Fatal(err)
		}
		return m
	}
}

func TestCoordHandshakeSpoofRejectionAndRelay(t *testing.T) {
	hub := newCoordHub([]string{"stun:198.51.100.10:3478"})
	mux, err := buildMux(hub)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(mux)
	defer srv.Close()

	hostID := makeIdentity(t)
	clientID := makeIdentity(t)
	otherID := makeIdentity(t)

	// 1. Spoofed signature must be rejected.
	bad := dialWS(t, srv.URL+"/v1/ws")
	defer bad.conn.Close()
	ts := time.Now().Unix()
	bad.sendJSON(t, wireMessage{
		Type:      "hostHello",
		HostID:    hostID.id,
		SignPub:   hostID.signPub,
		KexPub:    hostID.kexPub,
		Timestamp: ts,
		Nonce:     "nonce12345678",
		Sig:       otherID.signP1363(t, "kkremote-host-hello-v1|"+hostID.id+"|"+hostID.kexPub+"|"+strconv.FormatInt(ts, 10)+"|nonce12345678"),
	})
	errMsg := bad.recvJSON(t)
	if errMsg.Type != "error" {
		t.Fatalf("expected error on spoofed signature, got %+v", errMsg)
	}

	// 2. Client connects before host -> hostOnline=false, then receives hostPresence=true when host connects.
	cli := dialWS(t, srv.URL+"/v1/ws")
	defer cli.conn.Close()
	cNonce := "clientnonce123"
	cSigned := "kkremote-client-hello-v1|" + clientID.id + "|" + hostID.id + "|" + clientID.kexPub + "|" + strconv.FormatInt(ts, 10) + "|" + cNonce
	cli.sendJSON(t, wireMessage{
		Type:         "clientHello",
		ClientID:     clientID.id,
		TargetHostID: hostID.id,
		SignPub:      clientID.signPub,
		KexPub:       clientID.kexPub,
		Timestamp:    ts,
		Nonce:        cNonce,
		Sig:          clientID.signP1363(t, cSigned),
	})
	cWelcome := cli.recvJSON(t)
	if cWelcome.Type != "welcome" || cWelcome.HostOnline {
		t.Fatalf("unexpected client welcome: %+v", cWelcome)
	}

	hst := dialWS(t, srv.URL+"/v1/ws")
	defer hst.conn.Close()
	hNonce := "hostnonce12345"
	hSigned := "kkremote-host-hello-v1|" + hostID.id + "|" + hostID.kexPub + "|" + strconv.FormatInt(ts, 10) + "|" + hNonce
	hst.sendJSON(t, wireMessage{
		Type:      "hostHello",
		HostID:    hostID.id,
		Name:      "TestMac",
		SignPub:   hostID.signPub,
		KexPub:    hostID.kexPub,
		Timestamp: ts,
		Nonce:     hNonce,
		Sig:       hostID.signP1363(t, hSigned),
	})
	hWelcome := hst.recvJSON(t)
	if hWelcome.Type != "welcome" || len(hWelcome.StunServers) != 1 {
		t.Fatalf("unexpected host welcome: %+v", hWelcome)
	}
	presence := cli.recvJSON(t)
	if presence.Type != "hostPresence" || !presence.HostOnline || presence.HostName != "TestMac" {
		t.Fatalf("expected hostPresence online, got %+v", presence)
	}

	// 3. Relay enforces authentic sender identity and forwards opaque E2EE ciphertext.
	cli.sendJSON(t, wireMessage{
		Type:       "relay",
		To:         hostID.id,
		From:       otherID.id, // Attempted sender spoof must be overwritten by server!
		Session:    "sess-1234567890",
		Kind:       "connectRequest",
		E2ENonce:   "AAAAAAAAAAAAAAAA",
		Ciphertext: "YmFzZTY0Y2lwaGVydGV4dA==",
		PayloadSig: "c2ln",
	})
	relayed := hst.recvJSON(t)
	if relayed.Type != "relay" || relayed.From != clientID.id || relayed.Ciphertext != "YmFzZTY0Y2lwaGVydGV4dA==" {
		t.Fatalf("unexpected relayed message: %+v", relayed)
	}
}
