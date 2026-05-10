# DevOps Sandbox Platform

A self-service platform that lets users **spin up isolated, time-boxed
environments**, deploy a demo app into them, **simulate outages**,
**monitor health**, and **destroy everything** — automatically when the
TTL elapses or on demand.

> Stack: Docker, Docker Compose, Nginx, Bash, Python 3 (Flask).
> Designed to run on a single Linux VM. One `make up` boots the whole platform.

---

## Architecture

```
                ┌─────────────────────────────────────────────────────────────┐
                │                     Single Linux VM                         │
                │                                                             │
   user ──────► │  :80  ┌──────────────────┐    docker network sandbox-net    │
                │       │  sandbox-nginx   │◄─────┐                           │
                │       │  (front door)    │      │                           │
                │       └────────┬─────────┘      │                           │
                │                │ include conf.d │                           │
                │                │     /env/<id>/ │  proxy_pass               │
                │                ▼                │                           │
                │      ┌─────────────────┐ ┌──────┴────────┐                  │
                │      │ env-abc123      │ │ env-def456    │  ...             │
                │      │ demo-app        │ │ demo-app      │                  │
                │      │ label:          │ │ label:        │                  │
                │      │ sandbox.env=... │ │ sandbox.env=  │                  │
                │      └─────────────────┘ └───────────────┘                  │
                │            │                   │                            │
                │            └── env-abc123-net  └── env-def456-net           │
                │              (dedicated, isolated per-env networks)         │
                │                                                             │
                │  host processes:                                            │
                │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
   user ──:5000►   │ Flask API   │  │ Cleanup     │  │ Health      │         │
                │  │ platform/   │  │ Daemon      │  │ Monitor     │         │
                │  │ api.py      │  │ (every 60s) │  │ (every 30s) │         │
                │  └─────────────┘  └─────────────┘  └─────────────┘         │
                │         │                │                │                │
                │         ▼                ▼                ▼                │
                │     envs/*.json    logs/cleanup.log   logs/<id>/health.log │
                └─────────────────────────────────────────────────────────────┘
```

**Networking**: each env gets its own `<env_id>-net` (isolation) and is
also attached to the shared `sandbox-net` (so nginx can reach it via
container DNS). The host only ever publishes the nginx port (80) and the
API port (5000) — env containers themselves are never directly exposed.

**State**: one `envs/<env_id>.json` per active env. Writes are atomic
(temp file + `mv`) so the cleanup daemon, monitor, and API never observe
half-written state.

---

## Repo layout

```
devops-sandbox/
├── platform/
│   ├── create_env.sh         # provision an env (network + container + nginx route + log shipping + state)
│   ├── destroy_env.sh        # tear down an env (kill log pid, rm containers, rm network, rm route, archive logs)
│   ├── cleanup_daemon.sh     # background loop that destroys expired envs
│   ├── simulate_outage.sh    # chaos toggle (crash | pause | network | recover | stress)
│   ├── api.py                # Flask control API
│   ├── requirements.txt
│   └── demo-app/             # the throwaway "Hello World" app shipped in every env
│       ├── Dockerfile
│       └── app.py
├── nginx/
│   ├── nginx.conf            # main config (includes conf.d/*.conf inside the server block)
│   └── conf.d/               # one location-block .conf per active env (auto-generated)
├── monitor/
│   └── health_monitor.py     # 30s poller, marks envs degraded after 3 fails
├── envs/                     # one json file per active env (gitignored)
├── logs/                     # app, health, cleanup, monitor, api, archived/  (gitignored)
├── docker-compose.yml        # nginx
├── Makefile                  # operator entry points
├── .env.example              # copy to .env
├── README.md
└── test.md                   # how to test every requirement end-to-end
```

---

## Prerequisites

| Tool             | Why                                                        |
| ---------------- | ---------------------------------------------------------- |
| Docker ≥ 20      | Runs nginx + every env container.                          |
| Docker Compose ≥ 2 (`docker compose ...`) | Brings up nginx.                              |
| Bash ≥ 4         | Lifecycle scripts use `mapfile`, `nullglob`, `[[ ]]`.      |
| Python ≥ 3.10    | Runs the API, the monitor, and the demo app.               |
| make             | Operator UX.                                               |
| `curl`, `wget`   | Smoke tests + health checks.                               |
| Linux host       | Spec requires single Linux VM. WSL2 also works for dev.    |

---

## Quick start (zero → running env in 5 commands)

```bash
# 1. Configure environment.
cp .env.example .env

# 2. Install Python deps for the API + monitor.
make install

# 3. Bring up nginx, the daemon, the monitor, and the API.
make up

# 4. Create your first env (defaults: ttl 1800s).
make create NAME=hello TTL=600

# 5. Hit it.
curl http://localhost/env/<env_id_printed_above>/
```

Tear it all down with `make down`. Wipe local state, logs, archives,
and generated nginx confs with `make clean`.

---

## End-to-end demo walkthrough

```bash
# create
$ make create NAME=demo TTL=300
[create] env_id : env-abc123
[create] name   : demo
[create] url    : http://localhost/env/env-abc123/
[create] ttl    : 300s (expires 2026-05-10T11:35:00Z)

# deploy is implicit — the demo app is the running container

# verify it serves through nginx
$ curl http://localhost/env/env-abc123/
Hello from sandbox env 'demo' (id=env-abc123)
hostname: env-abc123
path:     /
time:     2026-05-10T11:30:01.234567+00:00

# health
$ make health
env-abc123        status=running   failures=0  last="2026-05-10T11:30:30Z status=200 latency_ms=8.42"

# simulate outage — kill the container
$ make simulate ENV=env-abc123 MODE=crash
[outage] 2026-05-10T11:30:45Z env-abc123: docker kill env-abc123

# observe it go degraded after ~90s (3 missed 30s polls)
$ tail -f logs/env-abc123/health.log
2026-05-10T11:31:00Z status=502 latency_ms=2.10
2026-05-10T11:31:30Z status=502 latency_ms=2.31
2026-05-10T11:32:00Z status=502 latency_ms=1.95
$ make health
env-abc123        status=degraded  failures=3  last="2026-05-10T11:32:00Z status=502 latency_ms=1.95"

# recover
$ make simulate ENV=env-abc123 MODE=recover
[outage] 2026-05-10T11:32:15Z env-abc123: docker start env-abc123

# auto-destroy (wait until TTL elapses, or destroy now)
$ make destroy ENV=env-abc123
[destroy] env env-abc123 destroyed
```

---

## Operator reference

### Make targets

| Target              | Effect                                                                  |
| ------------------- | ----------------------------------------------------------------------- |
| `make up`           | Start nginx + cleanup daemon + monitor + API.                           |
| `make down`         | Destroy every env, then stop everything.                                |
| `make restart`      | `down` followed by `up`.                                                |
| `make create`       | Prompts for name + TTL (or pass `NAME=`/`TTL=`).                        |
| `make destroy ENV=…`| Destroy a specific env by id.                                           |
| `make list`         | Active envs with TTL remaining and status.                              |
| `make logs ENV=…`   | Tail the env's `app.log`.                                               |
| `make health`       | Latest health line per env (status, consecutive_failures).              |
| `make simulate ENV=… MODE=…` | Trigger `crash` / `pause` / `network` / `recover` / `stress`.  |
| `make clean`        | Destroy all envs, wipe state/logs/archives/generated nginx confs.       |

### Control API

| Method & path              | Body                       | Response                                |
| -------------------------- | -------------------------- | --------------------------------------- |
| `POST /envs`               | `{"name":"demo","ttl":600}`| `201` env state JSON                    |
| `GET  /envs`               |                            | `200` array of envs + `ttl_remaining`   |
| `GET  /envs/<id>`          |                            | `200` env state JSON                    |
| `DELETE /envs/<id>`        |                            | `200` destruction log                   |
| `GET  /envs/<id>/logs`     |                            | `200` last 100 app log lines            |
| `GET  /envs/<id>/health`   |                            | `200` last 10 health samples + status   |
| `POST /envs/<id>/outage`   | `{"mode":"crash"}`         | `200` simulation log                    |
| `GET  /health`             |                            | `200` API liveness                      |

The API itself listens on `:5000` by default (`API_PORT` in `.env`).

---

## Log shipping (Approach A)

`create_env.sh` starts `docker logs -f $CONTAINER >> logs/$ENV_ID/app.log`
in the background, captures the PID, and stores it in the state file.
`destroy_env.sh` reads that PID and `kill`s the follower **before**
removing the container so we never strand a zombie tail. The follower
log directory itself is moved to `logs/archived/$ENV_ID/<timestamp>/`
on teardown so we keep a forensic trail.

Query an env's logs by id:

```bash
make logs ENV=env-abc123                 # local tail
curl http://localhost:5000/envs/env-abc123/logs   # last 100 lines via API
```

---

## Health monitoring

`monitor/health_monitor.py` runs as a host process (`make monitor-start`).
Every `HEALTH_INTERVAL` seconds (default 30) it iterates over `envs/*.json`,
hits `http://localhost/env/<id>/health` through nginx, and appends:

```
2026-05-10T11:30:30Z status=200 latency_ms=8.42
```

…to `logs/<id>/health.log`. After `HEALTH_FAILURE_THRESHOLD`
consecutive failures (default 3 → ~90 s) it flips the env's
`status` to `degraded` and prints a warning. State writes are
atomic (`os.replace`), so the API and cleanup daemon always see
a coherent file.

Prometheus + Grafana integration is intentionally **not** wired up
in this build (spec marks it as optional / extra credit). The health
log format is line-oriented and trivial to scrape if you add a
`textfile` exporter later.

---

## Outage simulation guard

`simulate_outage.sh` refuses to act unless **all** of these are true:

1. The provided env id starts with `env-`.
2. There is a state file at `envs/<id>.json`.
3. The resolved container's docker label `sandbox.env` matches the id.
4. The container name does not match a protected platform name
   (`sandbox-nginx`, `sandbox-api`, `sandbox-cleanup`, `sandbox-monitor`).

This makes it impossible to take down nginx, the API, the daemon, or
the monitor with a typo on `--env`.

---

## Known limitations

- **Linux-only.** Bash scripts use `mapfile`, `nullglob`, GNU `date -d`.
  WSL2 on Windows works for development; native Windows does not.
- **Path-based routing only.** Each env is reachable at `/env/<id>/`,
  not `<id>.example.com`. This avoids per-env DNS/TLS plumbing on a
  single VM but means the demo app must be path-agnostic
  (the bundled Flask app is).
- **stress-ng fallback is approximate.** The Alpine base image doesn't
  ship `stress-ng`; the script falls back to an `awk` busy-loop which
  pegs one core but is less precise than real stress-ng.
- **No persistent storage.** Envs are pure-compute by design; if you
  add a database container, give it its own volume and label it
  `sandbox.env=<id>` so destroy_env picks it up.
- **No authentication on the control API.** Acceptable for a single-VM
  internal platform; add an auth proxy or shared-secret header before
  exposing it.
- **Prometheus + Grafana not wired.** Optional per the spec. The
  health log format is grep-able; bolt on an exporter when needed.
- **Single-host only.** No swarm/k8s; the spec asks for a single VM.

---

## Common mistakes — and how this repo avoids them

| Mistake                                         | This repo                                                          |
| ----------------------------------------------- | ------------------------------------------------------------------ |
| Hard-coded names / ports                        | Every name comes from `$ENV_ID`; ports configurable via `.env`.    |
| Forgetting to reload nginx                      | Both `create_env.sh` and `destroy_env.sh` `nginx -s reload`.       |
| Zombie log followers                            | PID stored in state file, killed in `destroy_env.sh`.              |
| Half-written state files                        | All state writes go to a temp file then `mv` (`os.replace` in Py). |
| Chaos hits the wrong container                  | Multi-step guard in `simulate_outage.sh`, label-based.             |
