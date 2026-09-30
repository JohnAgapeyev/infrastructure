"""Prometheus exporter for python-matter-server node availability.

Why this exists: the 2026-09-30 incident had matter-server listening on
5580, HA connected, zero restarts - and all 12 nodes unavailable for 3 h.
Every stock signal (up, restarts, TCP probes) was green; the only metric
that mattered was "nodes available". health.py uses that as a k8s probe
(restart self-heal); this exporter turns it into a time series so it can
be graphed and alerted on without waiting for a restart loop.

Metrics (text format, port MATTER_EXPORTER_PORT, default 9566):
  matter_up                      1 if the WS API answered get_nodes
  matter_nodes                   commissioned nodes
  matter_nodes_available         nodes currently reachable
  matter_scrape_duration_seconds wall time of the last scrape

Each /metrics request performs a FRESH WebSocket query (no background
polling that could go stale); scrape interval 30 s / timeout 15 s.

Runs on the python-matter-server image (python3 + aiohttp in-image):
  python3 /exporter/matter-exporter.py
"""
import asyncio
import os
import time

from aiohttp import web
import aiohttp

WS = os.environ.get("MATTER_WS", "http://10.0.0.4:5580/ws")
# NOT named MATTER_EXPORTER_PORT: kubelet injects that exact name as a
# service-link var ("tcp://<clusterIP>:9566") for the pod's own Service
# named matter-exporter, which int() cannot parse (hit 2026-09-30).
PORT = int(os.environ.get("MATTER_EXPORTER_LISTEN_PORT", "9566"))
TIMEOUT = float(os.environ.get("MATTER_HEALTH_TIMEOUT", "10"))


async def collect() -> tuple[int, int]:
    """Return (nodes_total, nodes_available) via get_nodes."""
    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(WS) as ws:
            await ws.receive_json()  # server_info greeting
            await ws.send_json({"message_id": "health", "command": "get_nodes"})
            while True:
                msg = await ws.receive_json()
                if msg.get("message_id") == "health":
                    break
    if "result" not in msg:
        raise ValueError(f"get_nodes failed: {msg}")
    nodes = msg["result"]
    return len(nodes), sum(1 for n in nodes if n.get("available"))


async def metrics(_request: web.Request) -> web.Response:
    t0 = time.monotonic()
    up, total, avail = 0, 0, 0
    try:
        total, avail = await asyncio.wait_for(collect(), TIMEOUT)
        up = 1
    except Exception as exc:  # timeout, refused, bad frame -> matter_up 0
        print(f"scrape error: {exc!r}", flush=True)
    dur = time.monotonic() - t0
    body = (
        "# HELP matter_up 1 if the matter-server WebSocket API answered get_nodes during the last scrape.\n"
        "# TYPE matter_up gauge\n"
        f"matter_up {up}\n"
        "# HELP matter_nodes Number of commissioned Matter nodes.\n"
        "# TYPE matter_nodes gauge\n"
        f"matter_nodes {total}\n"
        "# HELP matter_nodes_available Number of Matter nodes currently reachable.\n"
        "# TYPE matter_nodes_available gauge\n"
        f"matter_nodes_available {avail}\n"
        "# HELP matter_scrape_duration_seconds Duration of the last scrape.\n"
        "# TYPE matter_scrape_duration_seconds gauge\n"
        f"matter_scrape_duration_seconds {dur:.3f}\n"
    )
    return web.Response(text=body, content_type="text/plain")


def main() -> None:
    app = web.Application()
    app.router.add_get("/metrics", metrics)
    web.run_app(app, host="0.0.0.0", port=PORT, print=None)


if __name__ == "__main__":
    main()
