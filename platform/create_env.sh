#!/usr/bin/env bash
#
# create_env.sh — provision a sandbox environment.
#
# Usage:
#   create_env.sh <name> [ttl_seconds]
#
# Steps:
#   1. Generate a unique env ID.
#   2. Create a dedicated docker network.
#   3. Run the demo app container, labelled sandbox.env=<id>.
#   4. Connect the container to the shared sandbox-net so nginx can reach it.
#   5. Drop a per-env nginx location block into nginx/conf.d/<id>.conf and reload.
#   6. Begin log shipping (docker logs -f >> logs/<id>/app.log) in the background.
#   7. Write envs/<id>.json atomically.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAME="${1:-}"
TTL="${2:-1800}"

if [[ -z "$NAME" ]]; then
    echo "Usage: $0 <name> [ttl_seconds]" >&2
    exit 2
fi

if ! [[ "$TTL" =~ ^[0-9]+$ ]]; then
    echo "ttl_seconds must be a positive integer" >&2
    exit 2
fi

# Load .env if present (DEMO_IMAGE, NGINX_CONTAINER, SHARED_NET).
if [[ -f "$ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi

DEMO_IMAGE="${DEMO_IMAGE:-devops-sandbox/demo-app:latest}"
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"
SHARED_NET="${SHARED_NET:-sandbox-net}"
APP_PORT="${APP_PORT:-8080}"

# Generate a short, collision-resistant env ID.
ENV_ID="env-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6 || true)"
CONTAINER_NAME="$ENV_ID"
NETWORK_NAME="${ENV_ID}-net"

mkdir -p "$ROOT/envs" "$ROOT/logs/$ENV_ID" "$ROOT/nginx/conf.d"

# Build the demo image on first use so create works on a fresh machine.
if ! docker image inspect "$DEMO_IMAGE" >/dev/null 2>&1; then
    echo "[create] building demo image $DEMO_IMAGE ..."
    docker build -q -t "$DEMO_IMAGE" "$ROOT/platform/demo-app" >/dev/null
fi

# Ensure the shared network exists (created lazily on first env).
if ! docker network inspect "$SHARED_NET" >/dev/null 2>&1; then
    docker network create "$SHARED_NET" >/dev/null
fi

# 1. Dedicated network for this env.
docker network create "$NETWORK_NAME" >/dev/null

# 2. Run the app container on the dedicated network.
docker run -d \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    --label "sandbox.env=$ENV_ID" \
    --label "sandbox.role=app" \
    --label "sandbox.name=$NAME" \
    -e "ENV_ID=$ENV_ID" \
    -e "ENV_NAME=$NAME" \
    "$DEMO_IMAGE" >/dev/null

# 3. Also attach to the shared network so nginx can resolve it.
docker network connect "$SHARED_NET" "$CONTAINER_NAME" >/dev/null

# 4. Per-env nginx location block. Trailing slashes on location + proxy_pass
#    strip the /env/<id>/ prefix before forwarding to the upstream.
NGINX_CONF="$ROOT/nginx/conf.d/$ENV_ID.conf"
TMP_CONF="$(mktemp)"
cat > "$TMP_CONF" <<EOF
# Auto-generated for $ENV_ID ($NAME) — do not edit by hand.
location /env/$ENV_ID/ {
    proxy_pass         http://$CONTAINER_NAME:$APP_PORT/;
    proxy_set_header   Host \$host;
    proxy_set_header   X-Real-IP \$remote_addr;
    proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Sandbox-Env $ENV_ID;
    proxy_read_timeout 30s;
}
EOF
mv "$TMP_CONF" "$NGINX_CONF"

# Reload nginx (skip gracefully if the proxy is not running yet).
if docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER"; then
    docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1 || \
        echo "[create] WARN: nginx reload failed for $ENV_ID" >&2
else
    echo "[create] WARN: nginx container '$NGINX_CONTAINER' not running; route registered but not yet served" >&2
fi

# 5. Log shipping (Approach A — docker logs -f to a file).
LOG_FILE="$ROOT/logs/$ENV_ID/app.log"
nohup docker logs -f "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 &
LOG_PID=$!
disown "$LOG_PID" 2>/dev/null || true

# 6. State file (atomic write — temp then mv).
CREATED_AT=$(date +%s)
STATE_FILE="$ROOT/envs/$ENV_ID.json"
TMP_STATE="$(mktemp)"
cat > "$TMP_STATE" <<EOF
{
  "id": "$ENV_ID",
  "name": "$NAME",
  "created_at": $CREATED_AT,
  "ttl": $TTL,
  "status": "running",
  "container": "$CONTAINER_NAME",
  "network": "$NETWORK_NAME",
  "shared_network": "$SHARED_NET",
  "app_port": $APP_PORT,
  "log_pid": $LOG_PID,
  "consecutive_failures": 0,
  "url": "http://localhost/env/$ENV_ID/"
}
EOF
mv "$TMP_STATE" "$STATE_FILE"

cat <<EOF
[create] env_id : $ENV_ID
[create] name   : $NAME
[create] url    : http://localhost/env/$ENV_ID/
[create] ttl    : ${TTL}s (expires $(date -d "@$((CREATED_AT + TTL))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "in ${TTL}s"))
EOF
