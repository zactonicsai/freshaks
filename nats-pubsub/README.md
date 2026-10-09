# NATS pub/sub demo — Go, C++ and Python clients

A small publish/subscribe system built on a [NATS](https://nats.io) server, with
a **publisher**, a **subscriber** and a **threaded load tester** in each of
three languages. Every client uses the same subject and the same JSON message
format, so any publisher works with any subscriber.

```
 publisher (Go | C++ | Python) ──┐                    ┌──> subscriber (Go)
 loadtest  (Go | C++ | Python) ──┼──> nats-server ────┼──> subscriber (C++)
                                 ┘   subject:          └──> subscriber (Python)
                                     demo.telemetry
```

## A note on RTI / DDS

This project uses NATS as the publish/subscribe middleware. RTI Connext DDS is
a separate, commercially licensed product with its own wire protocol (RTPS);
NATS clients and DDS participants cannot talk to each other directly, and no
RTI code is included here. The concepts line up like this:

| DDS                         | Here (NATS)                              |
|-----------------------------|------------------------------------------|
| Topic                       | Subject (`demo.telemetry`)               |
| DataWriter / DataReader     | publisher / subscriber                   |
| IDL data type               | JSON envelope (below)                    |
| Discovery (peer-to-peer)    | Central `nats-server` broker             |
| QoS: best-effort            | Core NATS (at-most-once)                 |
| QoS: reliable / durable     | Not used here — NATS JetStream adds this |

If you need real DDS participants on the same data, the usual approach is a
small bridge process that is both a DDS DataReader and a NATS publisher.

## Layout

```
docker-compose.yml        NATS server in Docker
server/nats-server.conf   server config (port 4222, monitoring on 8222)
go/                       Go clients      (official nats.go library)
  cmd/publisher  cmd/subscriber  cmd/loadtest
cpp/                      C++17 clients   (official nats.c library, fetched by CMake)
  publisher.cpp  subscriber.cpp  loadtest.cpp
python/                   Python clients  (official nats-py library)
  publisher.py   subscriber.py   loadtest.py
Makefile                  build shortcuts
```

## 1. Start the NATS server

With Docker:

```sh
docker compose up -d          # or: make server
```

Or with a native binary (https://nats.io/download/):

```sh
nats-server -c server/nats-server.conf
```

Clients connect to `nats://127.0.0.1:4222` by default. To use another server,
set `NATS_URL` or pass `--url`.

## 2. Build

| Language | Needs                       | Build                 |
|----------|-----------------------------|-----------------------|
| Go       | Go 1.21+ (see note)         | `make go`             |
| C++      | CMake 3.14+, C++17 compiler, git | `make cpp`       |
| Python   | Python 3.8+                 | `make python`         |

Binaries land in `bin/go/` and `bin/cpp/`. The first Go build runs
`go mod tidy` to download nats.go and write `go.sum`. `go.mod` pins nats.go
v1.54.0, which requires Go 1.26; an older Go will download that toolchain
automatically. The first C++ build clones and compiles nats.c (about a minute).

## 3. Run: one client publishes, one receives

Terminal 1 — the Go subscriber:

```sh
bin/go/subscriber
```

Terminal 2 — publish from any language:

```sh
bin/go/publisher  -count 5 -msg "hello"
bin/cpp/publisher --count 5 --msg "hello"
python3 python/publisher.py --count 5 --msg "hello"
```

The subscriber prints:

```
listening on [demo.telemetry] at nats://127.0.0.1:4222
received [demo.telemetry] #1 {"seq":1,"sender":"go-publisher","ts":1791489813211254909,"data":"hello"}
```

The other subscribers work the same way: `bin/cpp/subscriber`,
`python3 python/subscriber.py`. Stop any of them with Ctrl-C.

## 4. Load test

The load tester sends **1000 messages over 4 threads by default**; both numbers
are configurable. Each thread opens its own connection, and the total is split
evenly across threads.

Terminal 1 — a subscriber that counts 1000 messages, reports the rate and exits:

```sh
bin/go/subscriber -expect 1000 -quiet
```

Terminal 2:

```sh
bin/go/loadtest                              # 1000 messages, 4 threads
bin/go/loadtest  -n 100000 -threads 16 -size 512
bin/cpp/loadtest --n 100000 --threads 16 --size 512
python3 python/loadtest.py -n 100000 --threads 16 --size 512
```

Output:

```
load test: 1000 messages, 4 threads, 64-byte payload -> [demo.telemetry] at nats://127.0.0.1:4222
sent 1000 messages (0 failed) in 0.011s = 91537 msgs/sec
```

The load tester exits non-zero if any message failed to send.

## Options

Go uses single-dash flags (`-n`); C++ and Python use double-dash (`--n`).

**publisher**

| Option       | Default           | Meaning                                  |
|--------------|-------------------|------------------------------------------|
| `url`        | `$NATS_URL` or `nats://127.0.0.1:4222` | server address      |
| `subject`    | `demo.telemetry`  | subject to publish on                    |
| `count`      | `10`              | messages to send                         |
| `interval`   | `500ms`           | gap between messages (Go: duration like `100ms`; C++: milliseconds; Python: seconds) |
| `msg`        | `hello from <lang>` | payload text                           |

**subscriber**

| Option       | Default           | Meaning                                  |
|--------------|-------------------|------------------------------------------|
| `url`, `subject` | as above      | subject may use wildcards (`demo.*`, `demo.>`) |
| `queue`      | none              | queue group: members share messages instead of each getting a copy |
| `expect`     | `0`               | exit after N messages (0 = until Ctrl-C) |
| `quiet`      | off               | don't print each message                 |

**loadtest**

| Option       | Default           | Meaning                                  |
|--------------|-------------------|------------------------------------------|
| `url`, `subject` | as above      |                                          |
| `n` (Python also `--messages`) | `1000` | total messages to send            |
| `threads` (Python also `-t`)   | `4`    | concurrent publisher threads      |
| `size`       | `64`              | bytes in the `data` field                |

## Message format

```json
{"seq": 1, "sender": "go-publisher", "ts": 1791489813211254909, "data": "hello"}
```

`seq` counts per sender, `ts` is the publish time in Unix nanoseconds.

## Good to know

- **Start the subscriber first.** Core NATS is at-most-once with no storage:
  messages published while nobody is subscribed are discarded.
- **Slow subscribers can lose messages under heavy load.** If a subscriber
  falls too far behind, the server or client library drops messages for it
  rather than slowing the publishers. If `-expect` never completes on a large
  run, that is why; NATS JetStream is the fix when delivery must be guaranteed.
- Server stats are at http://localhost:8222/varz and `/connz`.
