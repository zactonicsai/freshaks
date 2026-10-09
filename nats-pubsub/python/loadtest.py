#!/usr/bin/env python3
"""Publish N messages split across T threads.

Each thread runs its own asyncio event loop with its own NATS connection.

    python loadtest.py                               # 1000 messages, 4 threads
    python loadtest.py -n 100000 --threads 16 --size 512
"""
import argparse
import asyncio
import sys
import threading
import time

from common import DEFAULT_SUBJECT, DEFAULT_URL, connect, envelope


async def worker(wid: int, n: int, args, result: dict) -> None:
    sender = f"python-loadtest-{wid}"
    data = "x" * args.size
    nc = await connect(args.url, sender)
    try:
        for i in range(1, n + 1):
            await nc.publish(args.subject, envelope(i, sender, data))
            result["sent"] += 1
        await nc.flush(timeout=30)  # wait until the server has everything
    finally:
        await nc.close()


def run_thread(wid: int, n: int, args, result: dict) -> None:
    try:
        asyncio.run(worker(wid, n, args, result))
    except Exception as exc:  # report and let the main thread count the shortfall
        result["error"] = exc
        print(f"thread {wid}: {exc!r}", file=sys.stderr)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--url", default=DEFAULT_URL, help="NATS server URL (or set NATS_URL)")
    p.add_argument("--subject", default=DEFAULT_SUBJECT)
    p.add_argument("-n", "--messages", type=int, default=1000, help="total messages to send")
    p.add_argument("-t", "--threads", type=int, default=4, help="number of publisher threads")
    p.add_argument("--size", type=int, default=64, help="payload size in bytes (the data field)")
    args = p.parse_args()

    if args.messages < 1 or args.threads < 1 or args.size < 0:
        p.error("--messages and --threads must be >= 1, --size must be >= 0")
    threads_n = min(args.threads, args.messages)

    print(
        f"load test: {args.messages} messages, {threads_n} threads, "
        f"{args.size}-byte payload -> [{args.subject}] at {args.url}",
        flush=True,
    )

    # Spread the total evenly; the first (total % threads) workers send one extra.
    base, extra = divmod(args.messages, threads_n)
    results, threads = [], []
    start = time.perf_counter()
    for wid in range(threads_n):
        n = base + (1 if wid < extra else 0)
        result = {"sent": 0}
        results.append(result)
        t = threading.Thread(target=run_thread, args=(wid, n, args, result))
        threads.append(t)
        t.start()
    for t in threads:
        t.join()
    elapsed = time.perf_counter() - start

    sent = sum(r["sent"] for r in results)
    failed = args.messages - sent
    print(f"sent {sent} messages ({failed} failed) in {elapsed:.3f}s = {sent / elapsed:.0f} msgs/sec")
    return 1 if failed or any("error" in r for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
