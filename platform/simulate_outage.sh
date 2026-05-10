#!/usr/bin/env bash
#
# simulate_outage.sh — chaos toggle for sandbox environments.
#
# Usage:
#   simulate_outage.sh --env <env_id> --mode <crash|pause|network|recover|stress>
#
# Modes:
#   crash    docker kill the app container (health monitor must catch it).
#   pause    docker pause (recovers via `--mode recover`).
#   network  detach the app from its dedicated network.
#   recover  restore whichever fault is currently active.
#   stress   spike CPU using stress-ng (requires --cap-add for some kernels).
#
# Guard: the script refuses to act on the nginx, daemon, api, or monitor
# containers — those would take the whole platform down.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)  ENV_ID="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}";   shift 2 ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0 ;;
        *)
            echo "Unknown arg: $1" >&2
            exit 2 ;;
    esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
    echo "Usage: $0 --env <env_id> --mode <crash|pause|network|recover|stress>" >&2
    exit 2
fi

# --- safety guard: never simulate an outage against platform infrastructure ---
PROTECTED_NAMES=("sandbox-nginx" "sandbox-api" "sandbox-cleanup" "sandbox-monitor")
PROTECTED_PREFIXES=("sandbox-" "nginx" "cleanup" "monitor" "api")

if [[ "$ENV_ID" != env-* ]]; then
    echo "[outage] REFUSING: env id '$ENV_ID' must start with 'env-' (chaos is sandbox-only)" >&2
    exit 3
fi
for name in "${PROTECTED_NAMES[@]}"; do
    if [[ "$ENV_ID" == "$name" ]]; then
        echo "[outage] REFUSING: '$ENV_ID' is a protected platform container" >&2
        exit 3
    fi
done

STATE_FILE="$ROOT/envs/$ENV_ID.json"
if [[ ! -f "$STATE_FILE" ]]; then
    echo "[outage] no such env: $ENV_ID" >&2
    exit 4
fi

CONTAINER="$(grep -oE '"container"[[:space:]]*:[[:space:]]*"[^"]+"' "$STATE_FILE" \
    | sed -E 's/.*"container"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
NETWORK="${ENV_ID}-net"

# Re-check the resolved container name.
for prefix in "${PROTECTED_PREFIXES[@]}"; do
    case "$CONTAINER" in
        "$prefix"|"$prefix"-*|"$prefix"_*)
            # only refuse if container is not an env- container
            if [[ "$CONTAINER" != env-* ]]; then
                echo "[outage] REFUSING: resolved container '$CONTAINER' looks like infrastructure" >&2
                exit 3
            fi ;;
    esac
done

# Confirm the container actually carries the sandbox.env label.
LABELS="$(docker inspect -f '{{ index .Config.Labels "sandbox.env" }}' "$CONTAINER" 2>/dev/null || true)"
if [[ "$LABELS" != "$ENV_ID" ]]; then
    echo "[outage] REFUSING: container '$CONTAINER' is not labelled sandbox.env=$ENV_ID" >&2
    exit 3
fi

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

case "$MODE" in
    crash)
        echo "[outage] $(ts) $ENV_ID: docker kill $CONTAINER"
        docker kill "$CONTAINER" >/dev/null
        ;;
    pause)
        echo "[outage] $(ts) $ENV_ID: docker pause $CONTAINER"
        docker pause "$CONTAINER" >/dev/null
        ;;
    network)
        echo "[outage] $(ts) $ENV_ID: docker network disconnect $NETWORK $CONTAINER"
        docker network disconnect "$NETWORK" "$CONTAINER" >/dev/null 2>&1 || \
            echo "[outage] WARN: disconnect from $NETWORK failed (already detached?)"
        ;;
    recover)
        # Try unpause first; if not paused, just (re)start, then ensure networks.
        STATE="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
        case "$STATE" in
            paused)
                echo "[outage] $(ts) $ENV_ID: docker unpause $CONTAINER"
                docker unpause "$CONTAINER" >/dev/null ;;
            exited|created)
                echo "[outage] $(ts) $ENV_ID: docker start $CONTAINER"
                docker start "$CONTAINER" >/dev/null ;;
            running)
                echo "[outage] $(ts) $ENV_ID: container already running" ;;
            missing)
                echo "[outage] container is gone; recreate the env instead" >&2
                exit 5 ;;
        esac
        # Make sure both networks are reattached.
        if ! docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CONTAINER" \
                | tr ' ' '\n' | grep -qx "$NETWORK"; then
            docker network connect "$NETWORK" "$CONTAINER" >/dev/null 2>&1 || true
        fi
        if ! docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CONTAINER" \
                | tr ' ' '\n' | grep -qx "${SHARED_NET:-sandbox-net}"; then
            docker network connect "${SHARED_NET:-sandbox-net}" "$CONTAINER" >/dev/null 2>&1 || true
        fi
        ;;
    stress)
        echo "[outage] $(ts) $ENV_ID: stress-ng --cpu 2 --timeout 60s (background)"
        # Best-effort; image may not have stress-ng. Falls back to a busy-loop.
        if docker exec "$CONTAINER" sh -c 'command -v stress-ng' >/dev/null 2>&1; then
            docker exec -d "$CONTAINER" stress-ng --cpu 2 --timeout 60s
        else
            echo "[outage] stress-ng not found in container — running awk busy-loop fallback"
            docker exec -d "$CONTAINER" sh -c 'awk "BEGIN{for(i=0;i<1e10;i++);}" &'
        fi
        ;;
    *)
        echo "[outage] unknown mode: $MODE" >&2
        exit 2 ;;
esac

echo "[outage] done"
