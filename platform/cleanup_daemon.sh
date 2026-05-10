#!/usr/bin/env bash
#
# cleanup_daemon.sh — auto-destroy expired environments.
#
# Loops every 60s, scans envs/*.json, and calls destroy_env.sh for any
# env whose now > created_at + ttl. Every action is timestamped and
# appended to logs/cleanup.log.
#
# Run in the background:
#   nohup ./platform/cleanup_daemon.sh >> logs/cleanup.log 2>&1 &
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INTERVAL="${CLEANUP_INTERVAL:-60}"
LOG_FILE="$ROOT/logs/cleanup.log"
mkdir -p "$ROOT/logs"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"
}

# Extract a numeric JSON field without depending on jq.
extract_int() {
    local file="$1" key="$2"
    grep -oE "\"$key\"[[:space:]]*:[[:space:]]*[0-9]+" "$file" \
        | grep -oE '[0-9]+$' \
        | head -n1
}

extract_str() {
    local file="$1" key="$2"
    grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" \
        | sed -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/" \
        | head -n1
}

trap 'log "[daemon] received signal — exiting"; exit 0' INT TERM

log "[daemon] starting (interval=${INTERVAL}s, root=$ROOT)"

while true; do
    NOW=$(date +%s)
    if [[ -d "$ROOT/envs" ]]; then
        # `nullglob` so an empty envs/ dir doesn't hand us a literal "*.json".
        shopt -s nullglob
        for state_file in "$ROOT/envs"/*.json; do
            ENV_ID="$(extract_str "$state_file" id)"
            CREATED_AT="$(extract_int "$state_file" created_at)"
            TTL="$(extract_int "$state_file" ttl)"

            if [[ -z "$ENV_ID" || -z "$CREATED_AT" || -z "$TTL" ]]; then
                log "[daemon] WARN: malformed state file $state_file — skipping"
                continue
            fi

            EXPIRES_AT=$((CREATED_AT + TTL))
            if (( NOW > EXPIRES_AT )); then
                AGE=$((NOW - CREATED_AT))
                log "[daemon] expiring $ENV_ID (age=${AGE}s, ttl=${TTL}s)"
                if "$ROOT/platform/destroy_env.sh" "$ENV_ID" >>"$LOG_FILE" 2>&1; then
                    log "[daemon] destroyed $ENV_ID"
                else
                    log "[daemon] ERROR: destroy_env.sh failed for $ENV_ID"
                fi
            fi
        done
        shopt -u nullglob
    fi
    sleep "$INTERVAL"
done
