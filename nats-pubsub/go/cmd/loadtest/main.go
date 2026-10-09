// loadtest publishes N messages split across T concurrent workers.
// Each worker is a goroutine with its own NATS connection.
//
//	go run ./cmd/loadtest                       # 1000 messages, 4 threads
//	go run ./cmd/loadtest -n 100000 -threads 16 -size 512
package main

import (
	"flag"
	"fmt"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nats-io/nats.go"

	"natspubsub/internal/common"
)

func main() {
	url := flag.String("url", common.URL(), "NATS server URL (or set NATS_URL)")
	subject := flag.String("subject", common.DefaultSubject, "subject to publish on")
	total := flag.Int("n", 1000, "total number of messages to send")
	threads := flag.Int("threads", 4, "number of concurrent publisher threads")
	size := flag.Int("size", 64, "payload size in bytes (the data field)")
	flag.Parse()

	if *total < 1 || *threads < 1 || *size < 0 {
		log.Fatal("-n and -threads must be >= 1, -size must be >= 0")
	}
	if *threads > *total {
		*threads = *total
	}

	data := strings.Repeat("x", *size)
	var sent, failed atomic.Int64
	var wg sync.WaitGroup

	fmt.Printf("load test: %d messages, %d threads, %d-byte payload -> [%s] at %s\n",
		*total, *threads, *size, *subject, *url)

	start := time.Now()
	for t := 0; t < *threads; t++ {
		// Spread the total evenly; the first (total % threads) workers send one extra.
		n := *total / *threads
		if t < *total%*threads {
			n++
		}
		wg.Add(1)
		go func(id, n int) {
			defer wg.Done()
			sender := fmt.Sprintf("go-loadtest-%d", id)
			nc, err := nats.Connect(*url, nats.Name(sender))
			if err != nil {
				log.Printf("thread %d: connect: %v", id, err)
				failed.Add(int64(n))
				return
			}
			defer nc.Close()
			for i := 1; i <= n; i++ {
				if err := nc.Publish(*subject, common.NewEnvelope(int64(i), sender, data)); err != nil {
					failed.Add(1)
					continue
				}
				sent.Add(1)
			}
			// Publish only buffers; Flush waits until the server has everything.
			if err := nc.Flush(); err != nil {
				log.Printf("thread %d: flush: %v", id, err)
			}
		}(t, n)
	}
	wg.Wait()
	elapsed := time.Since(start)

	fmt.Printf("sent %d messages (%d failed) in %.3fs = %.0f msgs/sec\n",
		sent.Load(), failed.Load(), elapsed.Seconds(), float64(sent.Load())/elapsed.Seconds())
	if failed.Load() > 0 {
		log.Fatal("some messages failed")
	}
}
