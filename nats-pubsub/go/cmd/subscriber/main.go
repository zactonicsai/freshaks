// subscriber receives messages from a NATS subject and prints them.
//
//	go run ./cmd/subscriber                       # run until Ctrl-C
//	go run ./cmd/subscriber -expect 1000 -quiet   # count 1000 messages, report rate, exit
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"

	"natspubsub/internal/common"
)

func main() {
	url := flag.String("url", common.URL(), "NATS server URL (or set NATS_URL)")
	subject := flag.String("subject", common.DefaultSubject, "subject to subscribe to (wildcards * and > allowed)")
	queue := flag.String("queue", "", "optional queue group; members of a group share the messages")
	expect := flag.Int64("expect", 0, "exit after this many messages (0 = run until Ctrl-C)")
	quiet := flag.Bool("quiet", false, "do not print each message (use for load tests)")
	flag.Parse()

	nc, err := nats.Connect(*url, nats.Name("go-subscriber"))
	if err != nil {
		log.Fatalf("connect %s: %v", *url, err)
	}
	defer nc.Close()

	var (
		received  atomic.Int64
		firstOnce sync.Once
		doneOnce  sync.Once
		first     time.Time
		last      atomic.Int64 // UnixNano of the most recent message
		done      = make(chan struct{})
	)

	handler := func(m *nats.Msg) {
		now := time.Now()
		firstOnce.Do(func() { first = now })
		last.Store(now.UnixNano())
		n := received.Add(1)
		if !*quiet {
			fmt.Printf("received [%s] #%d %s\n", m.Subject, n, m.Data)
		}
		if *expect > 0 && n >= *expect {
			doneOnce.Do(func() { close(done) })
		}
	}

	if *queue != "" {
		_, err = nc.QueueSubscribe(*subject, *queue, handler)
	} else {
		_, err = nc.Subscribe(*subject, handler)
	}
	if err != nil {
		log.Fatalf("subscribe: %v", err)
	}
	// Flush so the subscription is registered on the server before we announce it.
	if err := nc.Flush(); err != nil {
		log.Fatalf("flush: %v", err)
	}
	fmt.Printf("listening on [%s] at %s\n", *subject, *url)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-done:
	case <-sig:
	}

	n := received.Load()
	fmt.Printf("received %d messages", n)
	if n > 1 {
		elapsed := time.Unix(0, last.Load()).Sub(first)
		if elapsed > 0 {
			fmt.Printf(" in %.3fs (%.0f msgs/sec)", elapsed.Seconds(), float64(n)/elapsed.Seconds())
		}
	}
	fmt.Println()
}
