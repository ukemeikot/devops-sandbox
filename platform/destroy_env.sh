#!/usr/bin/env bash
#
# destroy_env.sh — tear down a sandbox environment.
#
# Usage:
#   destroy_env.sh <env_id>
#
# Steps:
#   1. Kill the docker-logs follower (avoid zombie processes).
#   2. Stop and remove every container labelled sandbox.env=<id>.
#   3. Remove the dedicated network.
#   4. Delete the per-env nginx config and reload nginx.
#   5. Archive logs to logs/archived/<id>/<timestamp>/.
#   6. Delete the state file.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_ID="${1:-}"
if [[ -z "$ENV_ID" ]]; then
    echo "Usage: $0 <env_id>" >&2
    exit 2
fi

if [[ -f "$ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi

NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"
SHARED_NET="${SHARED_NET:-sandbox-net}"

STATE_FILE="$ROOT/envs/$ENV_ID.json"
NGINX_CONF="$ROOT/nginx/conf.d/$ENV_ID.conf"
NETWORK_NAME="${ENV_ID}-net"

# 1. Kill the log-shipping process if we still know its PID.
if [[ -f "$STATE_FILE" ]]; then
    LOG_PID="$(grep -oE '"log_pid"[[:space:]]*:[[:space:]]*[0-9]+' "$STATE_FILE" | grep -oE '[0-9]+$' || true)"
    if [[ -n "${LOG_PID:-}" ]] && kill -0 "$LOG_PID" 2>/dev/null; then
        kill "$LOG_PID" 2>/dev/null || true
    fi
fi

# 2. Stop + remove all containers carrying the label.
mapfile -t CONTAINERS < <(docker ps -aq --filter "label=sandbox.env=$ENV_ID")
if (( ${#CONTAINERS[@]} > 0 )); then
    docker rm -f "${CONTAINERS[@]}" >/dev/null 2>&1 || true
fi

# 3. Disconnect from shared net (best effort) and remove dedicated network.
if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || \
        echo "[destroy] WARN: failed to remove network $NETWORK_NAME" >&2
fi

# 4. Remove nginx config + reload.
if [[ -f "$NGINX_CONF" ]]; then
    rm -f "$NGINX_CONF"
fi
if docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER"; then
    docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1 || \
        echo "[destroy] WARN: nginx reload failed" >&2
fi

# 5. Archive logs.
if [[ -d "$ROOT/logs/$ENV_ID" ]]; then
    TS="$(date -u +%Y%m%dT%H%M%SZ)"
    ARCHIVE_DIR="$ROOT/logs/archived/$ENV_ID/$TS"
    mkdir -p "$ARCHIVE_DIR"
    # mv contents (preserves the live dir if anything else is writing). Then drop the live dir.
    if compgen -G "$ROOT/logs/$ENV_ID/*" > /dev/null; then
        mv "$ROOT/logs/$ENV_ID"/* "$ARCHIVE_DIR/" 2>/dev/null || true
    fi
    rmdir "$ROOT/logs/$ENV_ID" 2>/dev/null || true
fi

# 6. Drop the state file last so other tools observe the env vanish atomically.
if [[ -f "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE"
fi

echo "[destroy] env $ENV_ID destroyed"
