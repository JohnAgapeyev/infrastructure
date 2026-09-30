"""Matter server health: are any commissioned nodes reachable?

Exit 0 if the server has no nodes or at least one node is available; exit 1
if every node is unavailable or the server does not answer. A bare TCP check
on 5580 is useless here: after a boot-time network race the server listens
and HA stays connected while all nodes remain unavailable forever (observed
2026-09-30: 12 nodes, 0 available, 3 h after boot; a restart fixes it).

Runs with the python-matter-server image's own python3 + aiohttp:
  k3s probe:  python3 /probe/health.py
  Docker:     docker exec -i matter-server python3 - < apps/home/matter-server/health.py
"""
import asyncio
import os
import sys

import aiohttp

URL = os.environ.get("MATTER_WS", "http://127.0.0.1:5580/ws")
TIMEOUT = float(os.environ.get("MATTER_HEALTH_TIMEOUT", "8"))


async def check() -> int:
    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(URL) as ws:
            await ws.receive_json()  # server_info greeting
            await ws.send_json({"message_id": "health", "command": "get_nodes"})
            while True:
                msg = await ws.receive_json()
                if msg.get("message_id") == "health":
                    break
    if "result" not in msg:
        print(f"get_nodes failed: {msg}")
        return 1
    nodes = msg["result"]
    available = sum(1 for n in nodes if n.get("available"))
    print(f"nodes={len(nodes)} available={available}")
    return 0 if not nodes or available > 0 else 1


def main() -> int:
    try:
        return asyncio.run(asyncio.wait_for(check(), TIMEOUT))
    except Exception as exc:  # timeout, connection refused, bad frame
        print(f"health check error: {exc!r}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
