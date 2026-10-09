#!/usr/bin/env python3
"""Publish a fixed number of messages to a NATS subject.

    python publisher.py --count 5 --msg "hello"
"""
import argparse
import asyncio

from common import DEFAULT_SUBJECT, DEFAULT_URL, connect, envelope


async def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--url", default=DEFAULT_URL, help="NATS server URL (or set NATS_URL)")
    p.add_argument("--subject", default=DEFAULT_SUBJECT)
    p.add_argument("--count", type=int, default=10, help="number of messages to send")
    p.add_argument("--interval", type=float, default=0.5, help="seconds between messages")
    p.add_argument("--msg", default="hello from python", help="payload text")
    args = p.parse_args()

    nc = await connect(args.url, "python-publisher")
    try:
        for i in range(1, args.count + 1):
            payload = envelope(i, "python-publisher", args.msg)
            await nc.publish(args.subject, payload)
            print(f"published [{args.subject}] {payload.decode()}", flush=True)
            if i < args.count:
                await asyncio.sleep(args.interval)
        await nc.flush()  # make sure everything reached the server
    finally:
        await nc.close()


if __name__ == "__main__":
    asyncio.run(main())
