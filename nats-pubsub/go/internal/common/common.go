// Package common holds the pieces shared by the Go publisher, subscriber and
// load tester: the default connection settings and the JSON message envelope
// that every client (Go, C++, Python) puts on the wire.
package common

import (
	"encoding/json"
	"os"
	"time"
)

const (
	DefaultURL     = "nats://127.0.0.1:4222"
	DefaultSubject = "demo.telemetry"
)

// Envelope is the wire format. All three language clients produce the same
// JSON so any publisher can talk to any subscriber.
type Envelope struct {
	Seq    int64  `json:"seq"`    // sequence number, unique per sender
	Sender string `json:"sender"` // who published it, e.g. "go-publisher"
	TS     int64  `json:"ts"`     // publish time, Unix nanoseconds
	Data   string `json:"data"`   // payload
}

// NewEnvelope builds and JSON-encodes an envelope stamped with the current time.
func NewEnvelope(seq int64, sender, data string) []byte {
	b, _ := json.Marshal(Envelope{Seq: seq, Sender: sender, TS: time.Now().UnixNano(), Data: data})
	return b
}

// URL returns the server URL: $NATS_URL if set, otherwise the default.
func URL() string {
	if u := os.Getenv("NATS_URL"); u != "" {
		return u
	}
	return DefaultURL
}
