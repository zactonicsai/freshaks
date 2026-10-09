#!/usr/bin/env python3
"""Receive messages from a NATS subject and print them.

    python subscriber.py                          # run until Ctrl-C
    python subscriber.py --expect 1000 --quiet    # count 1000, report rate, exit
"""
import argparse
import asyncio
import signal
import time

from common import DEFAULT_SUBJECT, DEFAULT_URL, connect


async def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--url", default=DEFAULT_URL, help="NATS server URL (or set NATS_URL)")
    p.add_argument("--subject", default=DEFAULT_SUBJECT, help="wildcards * and > allowed")
    p.add_argument("--queue", default="", help="optional queue group")
    p.add_argument("--expect", type=int, default=0, help="exit after this many messages (0 = forever)")
    p.add_argument("--quiet", action="store_true", help="do not print each message")
    args = p.parse_args()

    done = asyncio.Event()
    stats = {"n": 0, "first": 0.0, "last": 0.0}

    async def handler(msg) -> None:
        now = time.perf_counter()
        if stats["n"] == 0:
            stats["first"] = now
        stats["last"] = now
        stats["n"] += 1
        if not args.quiet:
            print(f"received [{msg.subject}] #{stats['n']} {msg.data.decode()}", flush=True)
        if args.expect and stats["n"] >= args.expect:
            done.set()

    nc = await connect(args.url, "python-subscriber")
    await nc.subscribe(args.subject, queue=args.queue, cb=handler)
    await nc.flush()  # subscription is now registered on the server
    print(f"listening on [{args.subject}] at {args.url}", flush=True)

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, done.set)
        except NotImplementedError:  # Windows
            pass
    try:
        await done.wait()
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass

    await nc.close()
    line = f"received {stats['n']} messages"
    elapsed = stats["last"] - stats["first"]
    if stats["n"] > 1 and elapsed > 0:
        line += f" in {elapsed:.3f}s ({stats['n'] / elapsed:.0f} msgs/sec)"
    print(line, flush=True)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
