package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const (
	opContinuation = 0x0
	opText         = 0x1
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xA
)

// wsConn implements minimal RFC 6455 server framing over Go's standard library.
type wsConn struct {
	netConn  net.Conn
	r        *bufio.Reader
	writeMu  sync.Mutex
	closed   bool
	maxBytes int
}

func upgradeWebSocket(w http.ResponseWriter, r *http.Request, maxBytes int) (*wsConn, error) {
	if !headerContainsToken(r.Header, "Connection", "upgrade") ||
		!strings.EqualFold(strings.TrimSpace(r.Header.Get("Upgrade")), "websocket") ||
		strings.TrimSpace(r.Header.Get("Sec-WebSocket-Version")) != "13" {
		http.Error(w, "bad websocket upgrade", http.StatusBadRequest)
		return nil, errors.New("invalid upgrade headers")
	}
	key := strings.TrimSpace(r.Header.Get("Sec-WebSocket-Key"))
	if key == "" {
		http.Error(w, "missing websocket key", http.StatusBadRequest)
		return nil, errors.New("missing websocket key")
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijacking unsupported", http.StatusInternalServerError)
		return nil, errors.New("hijacking unsupported")
	}
	conn, rw, err := hj.Hijack()
	if err != nil {
		return nil, err
	}
	sum := sha1.Sum([]byte(key + wsGUID))
	accept := base64.StdEncoding.EncodeToString(sum[:])
	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
	if _, err := rw.WriteString(resp); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if err := rw.Flush(); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return &wsConn{
		netConn:  conn,
		r:        rw.Reader,
		maxBytes: maxBytes,
	}, nil
}

func headerContainsToken(h http.Header, name, token string) bool {
	for _, v := range h.Values(name) {
		for _, part := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(part), token) {
				return true
			}
		}
	}
	return false
}

func (c *wsConn) ReadText(timeout time.Duration) ([]byte, error) {
	var msg []byte
	var assembling bool
	for {
		if timeout > 0 {
			_ = c.netConn.SetReadDeadline(time.Now().Add(timeout))
		}
		var hdr [2]byte
		if _, err := io.ReadFull(c.r, hdr[:]); err != nil {
			return nil, err
		}
		fin := (hdr[0] & 0x80) != 0
		opcode := hdr[0] & 0x0F
		masked := (hdr[1] & 0x80) != 0
		if !masked {
			_ = c.WriteClose(1002)
			return nil, errors.New("unmasked client frame")
		}
		length := uint64(hdr[1] & 0x7F)
		switch length {
		case 126:
			var ext [2]byte
			if _, err := io.ReadFull(c.r, ext[:]); err != nil {
				return nil, err
			}
			length = uint64(binary.BigEndian.Uint16(ext[:]))
		case 127:
			var ext [8]byte
			if _, err := io.ReadFull(c.r, ext[:]); err != nil {
				return nil, err
			}
			length = binary.BigEndian.Uint64(ext[:])
		}
		if length > uint64(c.maxBytes) || len(msg)+int(length) > c.maxBytes {
			_ = c.WriteClose(1009)
			return nil, errors.New("frame exceeds maximum message size")
		}
		var mask [4]byte
		if _, err := io.ReadFull(c.r, mask[:]); err != nil {
			return nil, err
		}
		payload := make([]byte, int(length))
		if _, err := io.ReadFull(c.r, payload); err != nil {
			return nil, err
		}
		for i := range payload {
			payload[i] ^= mask[i&3]
		}
		switch opcode {
		case opPing:
			_ = c.writeFrame(opPong, payload)
		case opPong:
			continue
		case opClose:
			_ = c.WriteClose(1000)
			return nil, io.EOF
		case opText, opBinary:
			if assembling {
				return nil, errors.New("unexpected new data opcode during continuation")
			}
			msg = append(msg[:0], payload...)
			if fin {
				return msg, nil
			}
			assembling = true
		case opContinuation:
			if !assembling {
				return nil, errors.New("unexpected continuation frame")
			}
			msg = append(msg, payload...)
			if fin {
				return msg, nil
			}
		default:
			_ = c.WriteClose(1003)
			return nil, errors.New("unsupported opcode")
		}
	}
}

func (c *wsConn) WriteText(data []byte) error {
	return c.writeFrame(opText, data)
}

func (c *wsConn) Ping() error {
	return c.writeFrame(opPing, []byte("kk"))
}

func (c *wsConn) WriteClose(code uint16) error {
	var body [2]byte
	binary.BigEndian.PutUint16(body[:], code)
	err := c.writeFrame(opClose, body[:])
	_ = c.Close()
	return err
}

func (c *wsConn) writeFrame(opcode byte, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.closed {
		return errors.New("connection closed")
	}
	_ = c.netConn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	var hdr []byte
	hdr = append(hdr, 0x80|opcode)
	n := len(payload)
	switch {
	case n < 126:
		hdr = append(hdr, byte(n))
	case n <= 65535:
		hdr = append(hdr, 126, byte(n>>8), byte(n))
	default:
		hdr = append(hdr, 127, 0, 0, 0, 0, byte(n>>24), byte(n>>16), byte(n>>8), byte(n))
	}
	if _, err := c.netConn.Write(hdr); err != nil {
		return err
	}
	if n > 0 {
		if _, err := c.netConn.Write(payload); err != nil {
			return err
		}
	}
	return nil
}

func (c *wsConn) Close() error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.closed {
		return nil
	}
	c.closed = true
	return c.netConn.Close()
}
