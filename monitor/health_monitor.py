"""
Health poller for the sandbox platform.

Every HEALTH_INTERVAL seconds (default 30) it iterates over envs/*.json,
hits the env's /health endpoint via nginx, and appends a line to
logs/<env_id>/health.log. After 3 consecutive failures it flips the
state file's `status` to "degraded" and emits a warning.

State writes are atomic — temp file, then os.replace.

Usage:
    nohup python3 monitor/health_monitor.py >> logs/monitor.log 2>&1 &
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENVS_DIR = ROOT / "envs"
LOGS_DIR = ROOT / "logs"
INTERVAL = int(os.environ.get("HEALTH_INTERVAL", "30"))
NGINX_HOST = os.environ.get("NGINX_HOST", "http://localhost")
TIMEOUT = float(os.environ.get("HEALTH_TIMEOUT", "5"))
FAILURE_THRESHOLD = int(os.environ.get("HEALTH_FAILURE_THRESHOLD", "3"))


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _stderr(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _write_atomic(path: Path, payload: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    os.replace(tmp, path)


def _check_one(state_path: Path) -> None:
    try:
        data = json.loads(state_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        _stderr(f"[monitor] cannot read {state_path.name}: {exc}")
        return

    env_id = data.get("id")
    if not env_id:
        return

    log_dir = LOGS_DIR / env_id
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "health.log"

    url = f"{NGINX_HOST}/env/{env_id}/health"
    started = time.monotonic()
    status = 0
    err = ""
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as resp:
            status = resp.status
            resp.read(64)
    except urllib.error.HTTPError as e:
        status = e.code
    except Exception as e:  # noqa: BLE001 — we want every failure mode here
        status = 0
        err = type(e).__name__

    latency_ms = round((time.monotonic() - started) * 1000, 2)
    line = f"{_now_iso()} status={status} latency_ms={latency_ms}"
    if err:
        line += f" error={err}"
    with log_file.open("a") as f:
        f.write(line + "\n")

    failures = int(data.get("consecutive_failures", 0))
    prev_status = data.get("status")
    if 200 <= status < 400:
        failures = 0
        if prev_status == "degraded":
            data["status"] = "running"
            print(f"[monitor] {env_id} recovered — status=running", flush=True)
    else:
        failures += 1
        if failures >= FAILURE_THRESHOLD and prev_status != "degraded":
            data["status"] = "degraded"
            print(
                f"[monitor] WARNING: {env_id} marked degraded "
                f"after {failures} consecutive failures (last status={status})",
                flush=True,
            )

    data["consecutive_failures"] = failures
    data["last_health"] = {
        "time": _now_iso(),
        "status": status,
        "latency_ms": latency_ms,
    }
    try:
        _write_atomic(state_path, data)
    except OSError as exc:
        _stderr(f"[monitor] cannot write {state_path.name}: {exc}")


def main() -> int:
    LOGS_DIR.mkdir(exist_ok=True)
    print(
        f"[monitor] starting (interval={INTERVAL}s, nginx={NGINX_HOST}, "
        f"threshold={FAILURE_THRESHOLD})",
        flush=True,
    )
    while True:
        if ENVS_DIR.exists():
            for state in sorted(ENVS_DIR.glob("env-*.json")):
                _check_one(state)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("[monitor] interrupted — exiting", flush=True)
