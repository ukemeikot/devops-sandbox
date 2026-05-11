# Test Plan — DevOps Sandbox Platform

This document is the **acceptance test plan** for the platform. Every
spec requirement maps to a numbered check below. Each check has its
own setup, command, expected result, and tear-down.

> **Where to run this**
>
> The platform runs on either Linux or Windows. So does this test plan.
> Every check below has **two parallel command blocks** — the first is
> POSIX bash, the second is Windows PowerShell. The acceptance criteria
> (`Pass:` line) is the same for both. Pick the block that matches your
> shell.
>
> Supported environments:
>
> - **Linux** (Ubuntu/Debian) — native bash.
> - **macOS** — Terminal / iTerm2.
> - **Windows + WSL2** — `wsl`, then run the **bash** blocks.
> - **Windows + Git Bash** — Git for Windows ships POSIX bash.
> - **Windows + PowerShell 5.1+** (default on Win10/11) — run the **PowerShell** blocks.
>
> **Conventions:**
>
> | bash | PowerShell |
> | ---- | ---------- |
> | `make X` | `.\make.ps1 X` |
> | `./platform/X.sh` | `.\platform\X.ps1` |
> | `curl` | `curl.exe` (Windows aliases `curl` to `Invoke-WebRequest` — use `.exe` for POSIX behavior) |
> | `python3` | `python` (or `py`) |
> | `$ENV` | `$envId` (PowerShell reserves `$env:` for environment-variable access) |
>
> Docker subcommands (`docker ps`, `docker inspect`, `docker network ls`,
> `docker logs`) are identical on both shells — only the surrounding
> shell syntax differs. All commands assume your shell is at the repo
> root and that `make up` (or `.\make.ps1 up`) has finished.

---

## 0. Setup

### 0.1 Prereqs are present

**bash:**

```bash
docker --version          # ≥ 20
docker compose version    # ≥ 2
python3 --version         # ≥ 3.10
make --version
```

**PowerShell:**

```powershell
docker --version          # ≥ 20
docker compose version    # ≥ 2
python --version          # ≥ 3.10  (or: py --version)
$PSVersionTable.PSVersion # ≥ 5.1   (Windows ships 5.1; pwsh 7+ also fine)
```

**Pass:** all four print a version. **Fail:** install whatever's missing.

### 0.2 Configure environment

**bash:**

```bash
cp .env.example .env
make install              # pip installs flask
```

**PowerShell:**

```powershell
Copy-Item .env.example .env
.\make.ps1 install        # pip installs flask
```

**Pass:** `.env` exists, `pip install` exits 0.

### 0.3 Bring up the platform

**bash:**

```bash
make up
docker ps | grep sandbox-nginx
curl -s http://localhost/health        # -> OK
```

**PowerShell:**

```powershell
.\make.ps1 up
docker ps --filter name=sandbox-nginx
curl.exe -s http://localhost/health    # -> OK
```

**Pass:** prints four lines (`nginx`, `api`, `daemon`, `monitor`) with
PIDs. `docker ps` shows `sandbox-nginx`. `/health` returns `OK`.

---

## 1. Environment lifecycle

### 1.1 Create script provisions everything

**bash:**

```bash
./platform/create_env.sh demo 600
```

**PowerShell:**

```powershell
.\platform\create_env.ps1 demo 600
```

**Pass:**

- Stdout includes `env_id`, `name`, `url`, `ttl`.
- `envs/<env_id>.json` exists and parses as JSON.
- `docker network ls | grep <env_id>-net` (bash) or
  `docker network ls --filter name=<env_id>-net` (either shell) shows
  the dedicated network.
- `docker ps --filter label=sandbox.env=<env_id>` shows the container.
- `nginx/conf.d/<env_id>.conf` exists.
- `curl http://localhost/env/<env_id>/` (or `curl.exe ...` on Windows)
  returns 200 with the demo body.

### 1.2 State file shape

**bash:**

```bash
cat envs/<env_id>.json
```

**PowerShell:**

```powershell
Get-Content -Raw "envs/<env_id>.json"
# Or as parsed object:
Get-Content -Raw "envs/<env_id>.json" | ConvertFrom-Json | Format-List
```

**Pass:** contains `id`, `name`, `created_at`, `ttl`, `status="running"`,
`container`, `network`, `log_pid`, `consecutive_failures`, `url`.

### 1.3 Atomic state writes

**bash:**

```bash
ls envs/*.tmp 2>/dev/null
```

**PowerShell:**

```powershell
Get-ChildItem envs/*.tmp -ErrorAction SilentlyContinue
```

**Pass:** no leftover `.tmp` files. (Both implementations write to a
temp file outside `envs/` and `mv` / `Move-Item -Force` into place.)

### 1.4 Destroy script removes everything

**bash:**

```bash
./platform/destroy_env.sh <env_id>
docker network ls | grep <env_id>-net
docker ps -a --filter label=sandbox.env=<env_id>
ls envs/<env_id>.json 2>/dev/null
ls nginx/conf.d/<env_id>.conf 2>/dev/null
ls logs/archived/<env_id>/*/app.log
ps -ef | grep "docker logs -f <env_id>" | grep -v grep
```

**PowerShell:**

```powershell
.\platform\destroy_env.ps1 <env_id>
docker network ls --filter name=<env_id>-net
docker ps -a --filter label=sandbox.env=<env_id>
Test-Path "envs/<env_id>.json"                       # -> False
Test-Path "nginx/conf.d/<env_id>.conf"               # -> False
Get-ChildItem "logs/archived/<env_id>/*/app.log"     # -> at least one match
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -like "*docker*logs*-f*<env_id>*" }
```

**Pass:**

- `envs/<env_id>.json` is gone.
- `docker network ls` no longer shows `<env_id>-net`.
- `docker ps -a` returns no container for that label.
- `nginx/conf.d/<env_id>.conf` is gone.
- `logs/archived/<env_id>/<timestamp>/app.log` exists.
- No leftover `docker logs -f <env_id>` process anywhere.

---

## 2. Auto-cleanup daemon

### 2.1 Daemon is running

**bash:**

```bash
cat logs/cleanup_daemon.pid
ps -p $(cat logs/cleanup_daemon.pid) -o cmd=
```

**PowerShell:**

```powershell
Get-Content logs/cleanup_daemon.pid
$daemonPid = [int](Get-Content logs/cleanup_daemon.pid)
(Get-CimInstance Win32_Process -Filter "ProcessId=$daemonPid").CommandLine
```

**Pass:** PID exists; command line names `cleanup_daemon.sh` (bash host)
or `cleanup_daemon.ps1` (PowerShell host).

### 2.2 Daemon destroys expired envs within ~60 s of expiry

**bash:**

```bash
make create NAME=ttltest TTL=30
ENV=$(ls -t envs/env-*.json | head -n1 | xargs -n1 basename | sed 's/.json//')
sleep 100
ls envs/$ENV.json 2>/dev/null && echo FAIL || echo PASS
grep "$ENV" logs/cleanup.log
```

**PowerShell:**

```powershell
.\make.ps1 create -Name ttltest -Ttl 30
$envId = (Get-ChildItem envs/env-*.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1).BaseName
Start-Sleep -Seconds 100
if (Test-Path "envs/$envId.json") { 'FAIL' } else { 'PASS' }
Select-String -Path logs/cleanup.log -Pattern $envId
```

**Pass:** the state file is gone; `cleanup.log` shows
`[daemon] expiring <env_id>` and `[daemon] destroyed <env_id>`, both
timestamped.

---

## 3. Nginx dynamic routing

### 3.1 Per-env config dropped on create

**bash:**

```bash
make create NAME=routing TTL=600
ENV=$(ls -t envs/env-*.json | head -n1 | xargs basename | sed 's/.json//')
test -f nginx/conf.d/$ENV.conf && echo PASS
```

**PowerShell:**

```powershell
.\make.ps1 create -Name routing -Ttl 600
$envId = (Get-ChildItem envs/env-*.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1).BaseName
if (Test-Path "nginx/conf.d/$envId.conf") { 'PASS' }
```

### 3.2 Reload happens automatically

**bash:**

```bash
docker logs sandbox-nginx 2>&1 | tail -n 20 | grep -i reload
```

**PowerShell:**

```powershell
docker logs sandbox-nginx 2>&1 | Select-Object -Last 20 |
    Select-String -Pattern 'reload' -SimpleMatch
```

**Pass:** at least one reload log line corresponding to the create.

### 3.3 Routing actually works

**bash:**

```bash
curl -fsSL http://localhost/env/$ENV/
curl -fsSL http://localhost/env/$ENV/health
curl -fsSL http://localhost/env/$ENV/info | head -c 200; echo
```

**PowerShell:**

```powershell
curl.exe -fsSL "http://localhost/env/$envId/"
curl.exe -fsSL "http://localhost/env/$envId/health"
$info = curl.exe -fsSL "http://localhost/env/$envId/info" | Out-String
$info.Substring(0, [Math]::Min(200, $info.Length))
```

**Pass:** all three return 200 with content from the demo app.

### 3.4 Config removed + reload on destroy

**bash:**

```bash
make destroy ENV=$ENV
test -f nginx/conf.d/$ENV.conf && echo FAIL || echo PASS
curl -o /dev/null -s -w '%{http_code}\n' http://localhost/env/$ENV/
```

**PowerShell:**

```powershell
.\make.ps1 destroy -Env $envId
if (Test-Path "nginx/conf.d/$envId.conf") { 'FAIL' } else { 'PASS' }
curl.exe -o nul -s -w "%{http_code}`n" "http://localhost/env/$envId/"
```

**Pass:** file gone; curl returns `404` (or `502`/`504` briefly during
reload — must settle to non-200).

---

## 4. Log shipping

### 4.1 `app.log` populates as the app emits stdout

**bash:**

```bash
make create NAME=logs-test TTL=300
ENV=$(ls -t envs/env-*.json | head -n1 | xargs basename | sed 's/.json//')
for i in 1 2 3; do curl -s http://localhost/env/$ENV/info > /dev/null; done
test -s logs/$ENV/app.log && echo PASS
```

**PowerShell:**

```powershell
.\make.ps1 create -Name logs-test -Ttl 300
$envId = (Get-ChildItem envs/env-*.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1).BaseName
1..3 | ForEach-Object { curl.exe -s "http://localhost/env/$envId/info" > $null }
$item = Get-Item "logs/$envId/app.log" -ErrorAction SilentlyContinue
if ($item -and $item.Length -gt 0) { 'PASS' } else { 'FAIL' }
```

### 4.2 Queryable by env id

**bash:**

```bash
make logs ENV=$ENV          # tail -f; Ctrl-C to exit
curl -s http://localhost:5000/envs/$ENV/logs | head -c 400; echo
```

**PowerShell:**

```powershell
.\make.ps1 logs -Env $envId    # streams; Ctrl-C to exit
$body = curl.exe -s "http://localhost:5000/envs/$envId/logs" | Out-String
$body.Substring(0, [Math]::Min(400, $body.Length))
```

**Pass:** both show the request lines.

### 4.3 No zombie process after destroy

**bash:**

```bash
LOG_PID=$(grep -oE '"log_pid"[[:space:]]*:[[:space:]]*[0-9]+' envs/$ENV.json | grep -oE '[0-9]+')
make destroy ENV=$ENV
kill -0 $LOG_PID 2>/dev/null && echo FAIL || echo PASS
```

**PowerShell:**

```powershell
$logPid = (Get-Content -Raw "envs/$envId.json" | ConvertFrom-Json).log_pid
.\make.ps1 destroy -Env $envId
if (Get-Process -Id $logPid -ErrorAction SilentlyContinue) { 'FAIL' } else { 'PASS' }
```

---

## 5. Health monitoring

### 5.1 Health log fills up every 30 s

**bash:**

```bash
make create NAME=hm TTL=600
ENV=$(ls -t envs/env-*.json | head -n1 | xargs basename | sed 's/.json//')
sleep 35
test -s logs/$ENV/health.log && echo PASS
tail -n3 logs/$ENV/health.log
```

**PowerShell:**

```powershell
.\make.ps1 create -Name hm -Ttl 600
$envId = (Get-ChildItem envs/env-*.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1).BaseName
Start-Sleep -Seconds 35
$item = Get-Item "logs/$envId/health.log" -ErrorAction SilentlyContinue
if ($item -and $item.Length -gt 0) { 'PASS' }
Get-Content -Tail 3 "logs/$envId/health.log"
```

**Pass:** at least one line of the form
`2026-05-10T... status=200 latency_ms=...`.

### 5.2 Status flips to `degraded` after 3 consecutive failures

**bash:**

```bash
make simulate ENV=$ENV MODE=crash
sleep 100        # 3 polls @ 30s = 90s, +10s buffer
make health | grep $ENV
grep -oE '"status"[[:space:]]*:[[:space:]]*"degraded"' envs/$ENV.json && echo PASS
```

**PowerShell:**

```powershell
.\make.ps1 simulate -Env $envId -Mode crash
Start-Sleep -Seconds 100
.\make.ps1 health | Select-String $envId
$state = Get-Content -Raw "envs/$envId.json" | ConvertFrom-Json
if ($state.status -eq 'degraded') { 'PASS' } else { 'FAIL' }
```

### 5.3 Recovery flips it back to `running`

**bash:**

```bash
make simulate ENV=$ENV MODE=recover
sleep 35
grep -oE '"status"[[:space:]]*:[[:space:]]*"running"' envs/$ENV.json && echo PASS
make destroy ENV=$ENV
```

**PowerShell:**

```powershell
.\make.ps1 simulate -Env $envId -Mode recover
Start-Sleep -Seconds 35
$state = Get-Content -Raw "envs/$envId.json" | ConvertFrom-Json
if ($state.status -eq 'running') { 'PASS' } else { 'FAIL' }
.\make.ps1 destroy -Env $envId
```

---

## 6. Outage simulation

### 6.1 `crash` kills the container

**bash:**

```bash
make create NAME=chaos TTL=600
ENV=$(ls -t envs/env-*.json | head -n1 | xargs basename | sed 's/.json//')
./platform/simulate_outage.sh --env $ENV --mode crash
docker inspect -f '{{.State.Status}}' $ENV    # -> exited
```

**PowerShell:**

```powershell
.\make.ps1 create -Name chaos -Ttl 600
$envId = (Get-ChildItem envs/env-*.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1).BaseName
.\platform\simulate_outage.ps1 -Env $envId -Mode crash
docker inspect -f '{{.State.Status}}' $envId   # -> exited
```

### 6.2 `pause` / `recover` round-trip

**bash:**

```bash
./platform/simulate_outage.sh --env $ENV --mode recover
docker inspect -f '{{.State.Status}}' $ENV    # -> running
./platform/simulate_outage.sh --env $ENV --mode pause
docker inspect -f '{{.State.Status}}' $ENV    # -> paused
./platform/simulate_outage.sh --env $ENV --mode recover
docker inspect -f '{{.State.Status}}' $ENV    # -> running
```

**PowerShell:**

```powershell
.\platform\simulate_outage.ps1 -Env $envId -Mode recover
docker inspect -f '{{.State.Status}}' $envId   # -> running
.\platform\simulate_outage.ps1 -Env $envId -Mode pause
docker inspect -f '{{.State.Status}}' $envId   # -> paused
.\platform\simulate_outage.ps1 -Env $envId -Mode recover
docker inspect -f '{{.State.Status}}' $envId   # -> running
```

### 6.3 `network` disconnect

**bash:**

```bash
./platform/simulate_outage.sh --env $ENV --mode network
docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}} {{end}}' $ENV | tr -d ' \n'
# expect: only sandbox-net (dedicated network missing)
./platform/simulate_outage.sh --env $ENV --mode recover
```

**PowerShell:**

```powershell
.\platform\simulate_outage.ps1 -Env $envId -Mode network
$nets = docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}} {{end}}' $envId
$nets -replace '\s',''
# expect: only sandbox-net (dedicated network missing)
.\platform\simulate_outage.ps1 -Env $envId -Mode recover
```

### 6.4 Guard refuses non-env containers

**bash:**

```bash
./platform/simulate_outage.sh --env sandbox-nginx --mode crash; echo "exit=$?"
# expect: REFUSING ... exit=3 (and nginx still running)
docker ps --filter name=sandbox-nginx --format '{{.Names}}'
make destroy ENV=$ENV
```

**PowerShell:**

```powershell
.\platform\simulate_outage.ps1 -Env sandbox-nginx -Mode crash; "exit=$LASTEXITCODE"
# expect: REFUSING ... exit=3 (and nginx still running)
docker ps --filter name=sandbox-nginx --format '{{.Names}}'
.\make.ps1 destroy -Env $envId
```

---

## 7. Control API

Set the base URL:

**bash:**

```bash
API=http://localhost:5000
```

**PowerShell:**

```powershell
$api = 'http://localhost:5000'
```

### 7.1 Liveness

**bash:**

```bash
curl -fsS $API/health
```

**PowerShell:**

```powershell
curl.exe -fsS "$api/health"
```

### 7.2 Create

**bash:**

```bash
ENV_ID=$(curl -fsS -XPOST $API/envs -H 'content-type: application/json' \
   -d '{"name":"api-demo","ttl":600}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["env"]["id"])')
echo $ENV_ID
```

**PowerShell:**

```powershell
$resp = curl.exe -fsS -XPOST "$api/envs" `
    -H 'content-type: application/json' `
    -d '{"name":"api-demo","ttl":600}' | ConvertFrom-Json
$apiEnvId = $resp.env.id
$apiEnvId
```

### 7.3 List

**bash:**

```bash
curl -fsS $API/envs | python3 -m json.tool | head -30
```

**PowerShell:**

```powershell
curl.exe -fsS "$api/envs" | ConvertFrom-Json |
    ConvertTo-Json -Depth 5 |
    Out-String -Stream | Select-Object -First 30
```

### 7.4 Logs

**bash:**

```bash
curl -s "$API/envs/$ENV_ID/logs" | head -c 400; echo
```

**PowerShell:**

```powershell
$raw = curl.exe -s "$api/envs/$apiEnvId/logs" | Out-String
$raw.Substring(0, [Math]::Min(400, $raw.Length))
```

### 7.5 Health

**bash:**

```bash
sleep 35
curl -s "$API/envs/$ENV_ID/health" | python3 -m json.tool
```

**PowerShell:**

```powershell
Start-Sleep -Seconds 35
curl.exe -s "$api/envs/$apiEnvId/health" | ConvertFrom-Json |
    ConvertTo-Json -Depth 5
```

### 7.6 Outage

**bash:**

```bash
curl -fsS -XPOST "$API/envs/$ENV_ID/outage" \
    -H 'content-type: application/json' -d '{"mode":"crash"}'
sleep 100
curl -s "$API/envs/$ENV_ID/health" | python3 -m json.tool   # status: degraded
curl -fsS -XPOST "$API/envs/$ENV_ID/outage" \
    -H 'content-type: application/json' -d '{"mode":"recover"}'
```

**PowerShell:**

```powershell
curl.exe -fsS -XPOST "$api/envs/$apiEnvId/outage" `
    -H 'content-type: application/json' -d '{"mode":"crash"}'
Start-Sleep -Seconds 100
curl.exe -s "$api/envs/$apiEnvId/health" | ConvertFrom-Json |
    ConvertTo-Json -Depth 5     # status: degraded
curl.exe -fsS -XPOST "$api/envs/$apiEnvId/outage" `
    -H 'content-type: application/json' -d '{"mode":"recover"}'
```

### 7.7 Destroy

**bash:**

```bash
curl -fsS -XDELETE "$API/envs/$ENV_ID"
curl -s -o /dev/null -w '%{http_code}\n' "$API/envs/$ENV_ID"  # -> 404
```

**PowerShell:**

```powershell
curl.exe -fsS -XDELETE "$api/envs/$apiEnvId"
curl.exe -s -o nul -w "%{http_code}`n" "$api/envs/$apiEnvId"    # -> 404
```

### 7.8 Input validation

**bash:**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -XPOST $API/envs \
    -H 'content-type: application/json' -d '{"name":"","ttl":-1}'   # -> 400
curl -s -o /dev/null -w '%{http_code}\n' -XPOST "$API/envs/env-bogus/outage" \
    -H 'content-type: application/json' -d '{"mode":"crash"}'      # -> 404
```

**PowerShell:**

```powershell
curl.exe -s -o nul -w "%{http_code}`n" -XPOST "$api/envs" `
    -H 'content-type: application/json' -d '{"name":"","ttl":-1}'    # -> 400
curl.exe -s -o nul -w "%{http_code}`n" -XPOST "$api/envs/env-bogus/outage" `
    -H 'content-type: application/json' -d '{"mode":"crash"}'        # -> 404
```

---

## 8. Operator entry-point coverage

Every required verb exists and runs.

**bash (Makefile):**

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

**PowerShell (make.ps1):**

```powershell
.\make.ps1 help                          # lists verbs
.\make.ps1 up                            # idempotent (re-run is fine)
.\make.ps1 list
.\make.ps1 create -Name mfile -Ttl 300
.\make.ps1 health
.\make.ps1 logs -Env env-xxxxxx          # Ctrl-C
.\make.ps1 simulate -Env env-xxxxxx -Mode pause
.\make.ps1 simulate -Env env-xxxxxx -Mode recover
.\make.ps1 destroy -Env env-xxxxxx
.\make.ps1 down
.\make.ps1 clean
```

**Pass:** every command exits 0 (or in the case of `logs`, runs until
Ctrl-C without error).

---

## 9. Smoke test (5 minutes, full path)

This is the same flow a reviewer should follow end-to-end. The two
blocks are equivalent — pick the one that matches your shell.

### bash

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

### PowerShell

```powershell
Copy-Item .env.example .env
.\make.ps1 install
.\make.ps1 up

.\make.ps1 create -Name smoke -Ttl 300
$envId = (Get-ChildItem envs/env-*.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1).BaseName

curl.exe -fsSL "http://localhost/env/$envId/"            # demo body
curl.exe -fsSL "http://localhost/env/$envId/health"      # OK

Start-Sleep -Seconds 35
.\make.ps1 health                                        # status=running

.\make.ps1 simulate -Env $envId -Mode crash
Start-Sleep -Seconds 100
.\make.ps1 health                                        # status=degraded

.\make.ps1 simulate -Env $envId -Mode recover
Start-Sleep -Seconds 35
.\make.ps1 health                                        # status=running

.\make.ps1 destroy -Env $envId
.\make.ps1 down
```

If every line above produces the expected output, the platform is
ready to grade — on either OS.

---

## 10. Cross-shell interoperability (optional)

Because both implementations produce identical on-disk state, an env
created from one shell can be destroyed from the other. Worth checking
once to prove the contract.

**Create on bash → destroy on PowerShell:**

```bash
# in bash:
make create NAME=interop TTL=600
ls -t envs/env-*.json | head -n1
```

```powershell
# in PowerShell on the same machine:
$envId = (Get-ChildItem envs/env-*.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1).BaseName
.\make.ps1 destroy -Env $envId
Test-Path "envs/$envId.json"     # -> False
```

**Pass:** the state file is gone, the container is removed, nginx is
reloaded — exactly as if both halves of the lifecycle had run in the
same shell.
