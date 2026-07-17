#!/usr/bin/env python3
"""Tiny demo web app for the kuberik rollout demo.

Serves a page that prominently shows the running VERSION, so a progressive
rollout is visible in the browser. Also exposes a health endpoint and a
Prometheus metrics endpoint used by the rollout's health checks.

VERSION is baked into the image at build time (see Dockerfile) so that each
published image tag renders a different, visually distinct page.
"""
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = os.environ.get("VERSION", "dev")
PORT = int(os.environ.get("PORT", "8080"))
START = time.time()

# Derive a stable accent colour from the version string so successive
# versions look different at a glance during a rollout.
_PALETTE = ["#6366f1", "#0ea5e9", "#10b981", "#f59e0b", "#ef4444", "#ec4899"]
COLOR = _PALETTE[sum(map(ord, VERSION)) % len(_PALETTE)]

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>kuberik rollout demo</title>
<style>
  html,body{{margin:0;height:100%;font-family:ui-sans-serif,system-ui,sans-serif}}
  body{{display:grid;place-items:center;background:{color};color:#fff}}
  .card{{text-align:center}}
  .v{{font-size:clamp(3rem,14vw,9rem);font-weight:800;letter-spacing:-.03em}}
  .l{{text-transform:uppercase;letter-spacing:.35em;opacity:.85;font-size:.8rem}}
  .h{{margin-top:1.5rem;opacity:.85;font-size:.9rem}}
</style>
</head>
<body>
  <div class="card">
    <div class="l">kuberik rollout demo</div>
    <div class="v">v{version}</div>
    <div class="h">host {host} &middot; up {uptime}s</div>
  </div>
</body>
</html>
"""

_requests = 0


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        global _requests
        if self.path == "/healthz":
            self._send(200, "ok")
            return
        if self.path == "/metrics":
            uptime = time.time() - START
            body = (
                "# HELP demo_requests_total Total HTTP requests served.\n"
                "# TYPE demo_requests_total counter\n"
                f'demo_requests_total{{version="{VERSION}"}} {_requests}\n'
                "# HELP demo_uptime_seconds Process uptime in seconds.\n"
                "# TYPE demo_uptime_seconds gauge\n"
                f'demo_uptime_seconds{{version="{VERSION}"}} {uptime:.1f}\n'
            )
            self._send(200, body, "text/plain; version=0.0.4")
            return
        _requests += 1
        host = os.environ.get("HOSTNAME", "?")
        html = PAGE.format(
            color=COLOR, version=VERSION, host=host, uptime=int(time.time() - START)
        )
        self._send(200, html, "text/html; charset=utf-8")

    def log_message(self, *args):  # quieter logs
        pass


if __name__ == "__main__":
    print(f"kuberik-rollout-demo version={VERSION} listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
