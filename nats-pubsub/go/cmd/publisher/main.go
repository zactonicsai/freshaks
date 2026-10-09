// publisher sends a fixed number of messages to a NATS subject.
//
//	go run ./cmd/publisher -count 5 -msg "hello"
package main

import (
	"flag"
	"fmt"
	"log"
	"time"

	"github.com/nats-io/nats.go"

	"natspubsub/internal/common"
)

func main() {
	url := flag.String("url", common.URL(), "NATS server URL (or set NATS_URL)")
	subject := flag.String("subject", common.DefaultSubject, "subject to publish on")
	count := flag.Int("count", 10, "number of messages to send")
	interval := flag.Duration("interval", 500*time.Millisecond, "delay between messages")
	text := flag.String("msg", "hello from go", "payload text")
	flag.Parse()

	nc, err := nats.Connect(*url, nats.Name("go-publisher"))
	if err != nil {
		log.Fatalf("connect %s: %v", *url, err)
	}
	defer nc.Close()

	for i := 1; i <= *count; i++ {
		payload := common.NewEnvelope(int64(i), "go-publisher", *text)
		if err := nc.Publish(*subject, payload); err != nil {
			log.Fatalf("publish: %v", err)
		}
		fmt.Printf("published [%s] %s\n", *subject, payload)
		if i < *count {
			time.Sleep(*interval)
		}
	}

	// Flush makes sure everything reached the server before we exit.
	if err := nc.Flush(); err != nil {
		log.Fatalf("flush: %v", err)
	}
}
