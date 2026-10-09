"""Shared settings and the JSON message envelope used by all clients."""
import json
import os
import time

DEFAULT_URL = os.environ.get("NATS_URL", "nats://127.0.0.1:4222")
DEFAULT_SUBJECT = "demo.telemetry"


def envelope(seq: int, sender: str, data: str) -> bytes:
    """Build the wire message. Same JSON shape as the Go and C++ clients."""
    return json.dumps(
        {"seq": seq, "sender": sender, "ts": time.time_ns(), "data": data},
        separators=(",", ":"),
    ).encode()


async def connect(url: str, name: str):
    """Connect to NATS, giving up after a few seconds if the server is unreachable
    (the library default is to keep retrying for about two minutes)."""
    import nats

    return await nats.connect(url, name=name, max_reconnect_attempts=5, reconnect_time_wait=0.5)
