# Test Plan — DevOps Sandbox Platform

This document is the **acceptance test plan** for the platform. Every
spec requirement maps to a numbered check below. Run these in order on
a fresh Linux VM (or WSL2). Each check has its own setup, command,
expected result, and tear-down.

> All commands assume your shell is at the repo root and that `make up`
> has finished (steps **0.1**–**0.3**). Replace `<env_id>` with the id
> printed by `make create`.

---

## 0. Setup

### 0.1 Prereqs are present

```bash
docker --version          # ≥ 20
docker compose version    # ≥ 2
python3 --version         # ≥ 3.10
make --version
```

**Pass:** all four print a version. **Fail:** install whatever's missing.

### 0.2 Configure environment

```bash
cp .env.example .env
make install              # pip installs flask
```

**Pass:** `.env` exists, `pip install` exits 0.

### 0.3 Bring up the platform

```bash
make up
```

**Pass:** prints four lines (`nginx`, `api`, `daemon`, `monitor`) with PIDs.
Confirm with `docker ps | grep sandbox-nginx` and `curl -s http://localhost/health` → `OK`.

---

## 1. Environment lifecycle

### 1.1 `create_env.sh` provisions everything

```bash
./platform/create_env.sh demo 600
```

**Pass:**

- Stdout includes `env_id`, `name`, `url`, `ttl`.
- `envs/<env_id>.json` exists and parses as JSON.
- `docker network ls | grep <env_id>-net` shows the dedicated network.
- `docker ps --filter label=sandbox.env=<env_id>` shows the container.
- `nginx/conf.d/<env_id>.conf` exists.
- `curl http://localhost/env/<env_id>/` returns 200 with the demo body.

### 1.2 State file shape

```bash
cat envs/<env_id>.json
```

**Pass:** contains `id`, `name`, `created_at`, `ttl`, `status="running"`,
`container`, `network`, `log_pid`, `consecutive_failures`, `url`.

### 1.3 Atomic state writes

```bash
ls envs/*.tmp 2>/dev/null
```

**Pass:** no leftover `.tmp` files. (If `create_env.sh` is interrupted,
the temp file remains under `/tmp` from `mktemp` — never under `envs/`.)

### 1.4 `destroy_env.sh` removes everything

```bash
./platform/destroy_env.sh <env_id>
```

**Pass:**

- `envs/<env_id>.json` is gone.
- `docker network ls | grep <env_id>-net` is empty.
- `docker ps -a --filter label=sandbox.env=<env_id>` is empty.
- `nginx/conf.d/<env_id>.conf` is gone.
- `logs/archived/<env_id>/<timestamp>/app.log` exists.
- `ps -ef | grep "docker logs -f <env_id>"` is empty (no zombie follower).

---

## 2. Auto-cleanup daemon

### 2.1 Daemon is running

```bash
cat logs/cleanup_daemon.pid
ps -p $(cat logs/cleanup_daemon.pid) -o cmd=
```

**Pass:** PID exists and the command line is `cleanup_daemon.sh`.

### 2.2 Daemon destroys expired envs within ~60 s of expiry

```bash
make create NAME=ttltest TTL=30
ENV=$(ls -t envs/env-*.json | head -n1 | xargs -n1 basename | sed 's/.json//')
sleep 100
ls envs/$ENV.json 2>/dev/null && echo FAIL || echo PASS
```

**Pass:** the file is gone. Confirm a cleanup line landed in
`logs/cleanup.log`:

```bash
grep "$ENV" logs/cleanup.log
```

Expect `[daemon] expiring <env_id>` and `[daemon] destroyed <env_id>`,
each timestamped.

---

## 3. Nginx dynamic routing

### 3.1 Per-env config dropped on create

```bash
make create NAME=routing TTL=600
ENV=$(ls -t envs/env-*.json | head -n1 | xargs basename | sed 's/.json//')
test -f nginx/conf.d/$ENV.conf && echo PASS
```

### 3.2 Reload happens automatically

```bash
docker logs sandbox-nginx 2>&1 | tail -n 20 | grep -i reload
```

**Pass:** at least one reload log line corresponding to the create.

### 3.3 Routing actually works

```bash
curl -fsSL http://localhost/env/$ENV/
curl -fsSL http://localhost/env/$ENV/health
curl -fsSL http://localhost/env/$ENV/info | head -c 200; echo
```

**Pass:** all three return 200 with content from the demo app.

### 3.4 Config removed + reload on destroy

```bash
make destroy ENV=$ENV
test -f nginx/conf.d/$ENV.conf && echo FAIL || echo PASS
curl -o /dev/null -s -w '%{http_code}\n' http://localhost/env/$ENV/
```

**Pass:** file gone; curl returns `404` (or `502`/`504` briefly during
reload — must settle to non-200).

---

## 4. Log shipping

### 4.1 `app.log` populates as the app emits stdout

```bash
make create NAME=logs-test TTL=300
ENV=$(ls -t envs/env-*.json | head -n1 | xargs basename | sed 's/.json//')
for i in 1 2 3; do curl -s http://localhost/env/$ENV/info > /dev/null; done
test -s logs/$ENV/app.log && echo PASS
```

### 4.2 Queryable by env id

```bash
make logs ENV=$ENV          # tail -f; Ctrl-C to exit
curl -s http://localhost:5000/envs/$ENV/logs | head -c 400; echo
```

**Pass:** both show the request lines.

### 4.3 No zombie process after destroy

```bash
LOG_PID=$(grep -oE '"log_pid"[[:space:]]*:[[:space:]]*[0-9]+' envs/$ENV.json | grep -oE '[0-9]+')
make destroy ENV=$ENV
kill -0 $LOG_PID 2>/dev/null && echo FAIL || echo PASS
```

---

## 5. Health monitoring

### 5.1 Health log fills up every 30 s

```bash
make create NAME=hm TTL=600
ENV=$(ls -t envs/env-*.json | head -n1 | xargs basename | sed 's/.json//')
sleep 35
test -s logs/$ENV/health.log && echo PASS
tail -n3 logs/$ENV/health.log
```

**Pass:** at least one line of the form
`2026-05-10T... status=200 latency_ms=...`.

### 5.2 Status flips to `degraded` after 3 consecutive failures

```bash
make simulate ENV=$ENV MODE=crash
sleep 100        # 3 polls @ 30s = 90s, +10s buffer
make health | grep $ENV
grep -oE '"status"[[:space:]]*:[[:space:]]*"degraded"' envs/$ENV.json && echo PASS
```

### 5.3 Recovery flips it back to `running`

```bash
make simulate ENV=$ENV MODE=recover
sleep 35
grep -oE '"status"[[:space:]]*:[[:space:]]*"running"' envs/$ENV.json && echo PASS
make destroy ENV=$ENV
```

---

## 6. Outage simulation

### 6.1 `crash` kills the container

```bash
make create NAME=chaos TTL=600
ENV=$(ls -t envs/env-*.json | head -n1 | xargs basename | sed 's/.json//')
./platform/simulate_outage.sh --env $ENV --mode crash
docker inspect -f '{{.State.Status}}' $ENV    # -> exited
```

### 6.2 `pause` / `recover` round-trip

```bash
./platform/simulate_outage.sh --env $ENV --mode recover
docker inspect -f '{{.State.Status}}' $ENV    # -> running
./platform/simulate_outage.sh --env $ENV --mode pause
docker inspect -f '{{.State.Status}}' $ENV    # -> paused
./platform/simulate_outage.sh --env $ENV --mode recover
docker inspect -f '{{.State.Status}}' $ENV    # -> running
```

### 6.3 `network` disconnect

```bash
./platform/simulate_outage.sh --env $ENV --mode network
docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}} {{end}}' $ENV | tr -d ' \n'
# expect: only sandbox-net (dedicated network missing)
./platform/simulate_outage.sh --env $ENV --mode recover
```

### 6.4 Guard refuses non-env containers

```bash
./platform/simulate_outage.sh --env sandbox-nginx --mode crash; echo "exit=$?"
# expect: REFUSING ... exit=3 (and nginx still running)
docker ps --filter name=sandbox-nginx --format '{{.Names}}'
make destroy ENV=$ENV
```

---

## 7. Control API

Set:

```bash
API=http://localhost:5000
```

### 7.1 Liveness

```bash
curl -fsS $API/health
```

### 7.2 Create

```bash
ENV_ID=$(curl -fsS -XPOST $API/envs -H 'content-type: application/json' \
   -d '{"name":"api-demo","ttl":600}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["env"]["id"])')
echo $ENV_ID
```

### 7.3 List

```bash
curl -fsS $API/envs | python3 -m json.tool | head -30
```

### 7.4 Logs

```bash
curl -s "$API/envs/$ENV_ID/logs" | head -c 400; echo
```

### 7.5 Health

```bash
sleep 35
curl -s "$API/envs/$ENV_ID/health" | python3 -m json.tool
```

### 7.6 Outage

```bash
curl -fsS -XPOST "$API/envs/$ENV_ID/outage" \
    -H 'content-type: application/json' -d '{"mode":"crash"}'
sleep 100
curl -s "$API/envs/$ENV_ID/health" | python3 -m json.tool   # status: degraded
curl -fsS -XPOST "$API/envs/$ENV_ID/outage" \
    -H 'content-type: application/json' -d '{"mode":"recover"}'
```

### 7.7 Destroy

```bash
curl -fsS -XDELETE "$API/envs/$ENV_ID"
curl -s -o /dev/null -w '%{http_code}\n' "$API/envs/$ENV_ID"  # -> 404
```

### 7.8 Input validation

```bash
curl -s -o /dev/null -w '%{http_code}\n' -XPOST $API/envs \
    -H 'content-type: application/json' -d '{"name":"","ttl":-1}'   # -> 400
curl -s -o /dev/null -w '%{http_code}\n' -XPOST "$API/envs/env-bogus/outage" \
    -H 'content-type: application/json' -d '{"mode":"crash"}'      # -> 404
```

---

## 8. Makefile coverage

Every required target exists and runs:

```bash
make help               # lists targets
make up                 # idempotent (re-run is fine)
make list
make create NAME=mfile TTL=300
make health
make logs ENV=...       # Ctrl-C
make simulate ENV=... MODE=pause
make simulate ENV=... MODE=recover
make destroy ENV=...
make down
make clean
```

**Pass:** every command exits 0 (or in the case of `logs`, runs until
Ctrl-C without error).

---

## 9. Smoke test (5 minutes, full path)

This is the same flow a reviewer should follow.

```bash
cp .env.example .env
make install
make up

make create NAME=smoke TTL=300
ENV=$(ls -t envs/env-*.json | head -n1 | xargs basename | sed 's/.json//')

curl -fsSL http://localhost/env/$ENV/                    # demo body
curl -fsSL http://localhost/env/$ENV/health              # OK

sleep 35
make health                                              # status=running

make simulate ENV=$ENV MODE=crash
sleep 100
make health                                              # status=degraded

make simulate ENV=$ENV MODE=recover
sleep 35
make health                                              # status=running

make destroy ENV=$ENV
make down
```

If every line above produces the expected output, the platform is
ready to grade.
