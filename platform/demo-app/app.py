"""
Tiny Flask demo app for sandbox environments.

Endpoints:
    GET  /          → identity message (env id, name, hostname).
    GET  /health    → 200 OK for the health monitor.
    GET  /info      → JSON payload echoing the request path / headers.
    GET  /<path>    → echo, useful for verifying nginx routing.
"""
import os
import socket
from datetime import datetime, timezone

from flask import Flask, jsonify, request

app = Flask(__name__)

ENV_ID = os.environ.get("ENV_ID", "unknown")
ENV_NAME = os.environ.get("ENV_NAME", "unnamed")
HOSTNAME = socket.gethostname()


@app.get("/health")
def health():
    return "OK\n", 200, {"Content-Type": "text/plain"}


@app.get("/info")
def info():
    return jsonify(
        env_id=ENV_ID,
        env_name=ENV_NAME,
        hostname=HOSTNAME,
        path=request.path,
        method=request.method,
        time=datetime.now(timezone.utc).isoformat(),
    )


@app.get("/")
@app.get("/<path:path>")
def root(path: str = ""):
    body = (
        f"Hello from sandbox env '{ENV_NAME}' (id={ENV_ID})\n"
        f"hostname: {HOSTNAME}\n"
        f"path:     /{path}\n"
        f"time:     {datetime.now(timezone.utc).isoformat()}\n"
    )
    return body, 200, {"Content-Type": "text/plain"}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
