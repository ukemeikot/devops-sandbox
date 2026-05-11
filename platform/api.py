"""
Control API for the DevOps Sandbox Platform.

Wraps the platform shell scripts behind a small Flask service so the
lifecycle, log inspection, health inspection, and outage simulation all
work over HTTP.

Routes:
    POST   /envs                 create env  (body: {"name": "...", "ttl": 1800})
    GET    /envs                 list envs + ttl_remaining
    GET    /envs/<id>            single env state
    DELETE /envs/<id>            destroy env
    GET    /envs/<id>/logs       last 100 lines of app.log
    GET    /envs/<id>/health     last 10 health-check results
    POST   /envs/<id>/outage     run simulation  (body: {"mode": "crash"})
    GET    /health               API liveness
"""
from __future__ import annotations

import json
import os
import platform as _platform
import shutil
import subprocess
import time
from pathlib import Path

from flask import Flask, jsonify, request

ROOT = Path(__file__).resolve().parents[1]
ENVS_DIR = ROOT / "envs"
LOGS_DIR = ROOT / "logs"
PLATFORM_DIR = ROOT / "platform"

app = Flask(__name__)


def _detect_shell() -> str:
    # Prefer bash so the Linux / WSL2 / Git Bash path stays the source
    # of truth. Fall back to PowerShell only on bare Windows hosts.
    if shutil.which("bash"):
        return "bash"
    if _platform.system() == "Windows":
        for cand in ("pwsh", "powershell"):
            if shutil.which(cand):
                return cand
    raise RuntimeError(
        "No supported shell found. Install Git Bash, WSL2, or PowerShell."
    )


_SHELL = _detect_shell()


def _ps_args(script_basename: str, args: tuple[str, ...]) -> list[str]:
    # The .ps1 scripts use PowerShell-idiomatic params (-Env, -Mode,
    # -EnvId). Translate the bash-flavored call sites so route handlers
    # stay shell-agnostic.
    if script_basename == "simulate_outage":
        out: list[str] = []
        i = 0
        while i < len(args):
            if args[i] == "--env" and i + 1 < len(args):
                out += ["-Env", args[i + 1]]; i += 2
            elif args[i] == "--mode" and i + 1 < len(args):
                out += ["-Mode", args[i + 1]]; i += 2
            else:
                out.append(args[i]); i += 1
        return out
    if script_basename == "destroy_env":
        return ["-EnvId", *args]
    return list(args)


def _run(script_basename: str, *args: str) -> tuple[int, str, str]:
    """Invoke a platform script regardless of host shell."""
    if _SHELL == "bash":
        cmd = ["bash", str(PLATFORM_DIR / f"{script_basename}.sh"), *args]
    else:
        cmd = [
            _SHELL,
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", str(PLATFORM_DIR / f"{script_basename}.ps1"),
            *_ps_args(script_basename, args),
        ]
    proc = subprocess.run(
        cmd, cwd=str(ROOT), capture_output=True, text=True, timeout=120
    )
    return proc.returncode, proc.stdout, proc.stderr


def _load_env(env_id: str) -> dict | None:
    f = ENVS_DIR / f"{env_id}.json"
    if not f.exists():
        return None
    try:
        return json.loads(f.read_text())
    except json.JSONDecodeError:
        return None


def _is_env_id(env_id: str) -> bool:
    # Defence in depth: only allow lowercase alnum + hyphens.
    return bool(env_id) and env_id.startswith("env-") and all(
        c.isalnum() or c == "-" for c in env_id
    )


@app.get("/health")
def api_health():
    return jsonify(status="ok", service="sandbox-api")


@app.post("/envs")
def create_env():
    body = request.get_json(silent=True) or {}
    name = str(body.get("name") or "").strip()
    ttl = body.get("ttl", 1800)

    if not name or not all(c.isalnum() or c in "-_." for c in name):
        return jsonify(error="name is required (alnum, dash, underscore, dot)"), 400
    try:
        ttl = int(ttl)
        if ttl <= 0:
            raise ValueError
    except (TypeError, ValueError):
        return jsonify(error="ttl must be a positive integer (seconds)"), 400

    code, out, err = _run("create_env", name, str(ttl))
    if code != 0:
        return jsonify(error="create_env failed", stdout=out, stderr=err), 500

    # Find the env we just made — it's the newest file in envs/.
    state_files = sorted(ENVS_DIR.glob("env-*.json"), key=lambda p: p.stat().st_mtime)
    env = json.loads(state_files[-1].read_text()) if state_files else {}
    return jsonify(env=env, log=out.strip()), 201


@app.get("/envs")
def list_envs():
    now = int(time.time())
    envs = []
    for f in sorted(ENVS_DIR.glob("env-*.json")):
        try:
            data = json.loads(f.read_text())
        except json.JSONDecodeError:
            continue
        data["ttl_remaining"] = max(0, data.get("created_at", 0) + data.get("ttl", 0) - now)
        envs.append(data)
    return jsonify(envs=envs, count=len(envs))


@app.get("/envs/<env_id>")
def get_env(env_id: str):
    if not _is_env_id(env_id):
        return jsonify(error="invalid env id"), 400
    data = _load_env(env_id)
    if data is None:
        return jsonify(error="not found"), 404
    now = int(time.time())
    data["ttl_remaining"] = max(0, data.get("created_at", 0) + data.get("ttl", 0) - now)
    return jsonify(data)


@app.delete("/envs/<env_id>")
def delete_env(env_id: str):
    if not _is_env_id(env_id):
        return jsonify(error="invalid env id"), 400
    if _load_env(env_id) is None:
        return jsonify(error="not found"), 404
    code, out, err = _run("destroy_env", env_id)
    if code != 0:
        return jsonify(error="destroy_env failed", stdout=out, stderr=err), 500
    return jsonify(status="destroyed", env_id=env_id, log=out.strip())


@app.get("/envs/<env_id>/logs")
def env_logs(env_id: str):
    if not _is_env_id(env_id):
        return jsonify(error="invalid env id"), 400
    log = LOGS_DIR / env_id / "app.log"
    if not log.exists():
        return jsonify(error="no logs yet", env_id=env_id, lines=[]), 404
    text = log.read_text(errors="replace").splitlines()
    return jsonify(env_id=env_id, lines=text[-100:], total=len(text))


@app.get("/envs/<env_id>/health")
def env_health(env_id: str):
    if not _is_env_id(env_id):
        return jsonify(error="invalid env id"), 400
    log = LOGS_DIR / env_id / "health.log"
    if not log.exists():
        return jsonify(error="no health checks yet", env_id=env_id, samples=[]), 404
    samples = log.read_text(errors="replace").splitlines()[-10:]
    state = _load_env(env_id) or {}
    return jsonify(
        env_id=env_id,
        status=state.get("status"),
        consecutive_failures=state.get("consecutive_failures", 0),
        samples=samples,
    )


@app.post("/envs/<env_id>/outage")
def env_outage(env_id: str):
    if not _is_env_id(env_id):
        return jsonify(error="invalid env id"), 400
    if _load_env(env_id) is None:
        return jsonify(error="not found"), 404

    body = request.get_json(silent=True) or {}
    mode = str(body.get("mode") or "").strip()
    if mode not in {"crash", "pause", "network", "recover", "stress"}:
        return jsonify(error="mode must be one of: crash, pause, network, recover, stress"), 400

    code, out, err = _run("simulate_outage", "--env", env_id, "--mode", mode)
    if code != 0:
        return jsonify(error="simulate_outage failed", stdout=out, stderr=err), 500
    return jsonify(env_id=env_id, mode=mode, log=out.strip())


if __name__ == "__main__":
    port = int(os.environ.get("API_PORT", "5000"))
    # Threaded so subprocess.run during one request doesn't block another.
    app.run(host="0.0.0.0", port=port, threaded=True)
