# DevOps Sandbox Platform — Makefile
#
# Single Linux VM workflow. Run `make up` once, then drive the platform
# either via the API (port 5000) or these targets.
#
# Variables overridable on the command line, e.g.
#   make create NAME=demo TTL=600
#   make destroy ENV=env-abc123
#   make simulate ENV=env-abc123 MODE=crash

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ROOT       := $(shell pwd)
PLATFORM   := $(ROOT)/platform
MONITOR    := $(ROOT)/monitor
ENVS_DIR   := $(ROOT)/envs
LOGS_DIR   := $(ROOT)/logs
PYTHON     ?= python3
DAEMON_PID := $(LOGS_DIR)/cleanup_daemon.pid
MON_PID    := $(LOGS_DIR)/monitor.pid
API_PID    := $(LOGS_DIR)/api.pid

# Optional overrides (defaults match docker-compose.yml + scripts):
SHARED_NET     ?= sandbox-net
NGINX_NAME     ?= sandbox-nginx
DEMO_IMAGE     ?= devops-sandbox/demo-app:latest
NGINX_HOST_PORT?= 80
API_PORT       ?= 5000

export SHARED_NET NGINX_NAME DEMO_IMAGE NGINX_HOST_PORT API_PORT

.PHONY: help up down restart create destroy logs health simulate clean \
        list api-start api-stop daemon-start daemon-stop monitor-start \
        monitor-stop demo-image dirs install

help: ## Show this help.
	@awk 'BEGIN { FS = ":.*?## " } /^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

dirs:
	@mkdir -p "$(ENVS_DIR)" "$(LOGS_DIR)" "$(LOGS_DIR)/archived" "$(LOGS_DIR)/nginx" \
	          "$(ROOT)/nginx/conf.d"
	@chmod +x "$(PLATFORM)"/*.sh 2>/dev/null || true

install: dirs ## Install Python deps for the API + monitor (host-side).
	@$(PYTHON) -m pip install -q -r "$(PLATFORM)/requirements.txt"

demo-image: ## Build the bundled demo app image.
	@docker build -t "$(DEMO_IMAGE)" "$(PLATFORM)/demo-app"

up: dirs demo-image ## Start nginx, the cleanup daemon, the health monitor, and the API.
	@docker compose up -d nginx
	@$(MAKE) daemon-start monitor-start api-start
	@echo
	@echo "  [up] platform ready:"
	@echo "       nginx     -> http://localhost:$(NGINX_HOST_PORT)/"
	@echo "       api       -> http://localhost:$(API_PORT)/envs"
	@echo "       daemon    -> pid $$(cat $(DAEMON_PID) 2>/dev/null || echo ?)"
	@echo "       monitor   -> pid $$(cat $(MON_PID) 2>/dev/null || echo ?)"

down: ## Destroy all envs, then stop nginx + background processes.
	@$(MAKE) --no-print-directory _destroy_all || true
	@$(MAKE) --no-print-directory api-stop daemon-stop monitor-stop || true
	@docker compose down --remove-orphans || true
	@echo "[down] platform stopped"

restart: down up ## Stop everything, then bring it back up.

# ---- env lifecycle ----------------------------------------------------------

NAME ?=
TTL  ?= 1800

create: dirs ## Create a new env. Override: make create NAME=foo TTL=600
	@if [ -z "$(NAME)" ]; then \
	    read -rp "name: " name; \
	    read -rp "ttl seconds [1800]: " ttl; \
	    ttl=$${ttl:-1800}; \
	    "$(PLATFORM)/create_env.sh" "$$name" "$$ttl"; \
	else \
	    "$(PLATFORM)/create_env.sh" "$(NAME)" "$(TTL)"; \
	fi

destroy: ## Destroy a specific env. Required: ENV=env-...
	@if [ -z "$(ENV)" ]; then echo "Usage: make destroy ENV=env-..."; exit 2; fi
	@"$(PLATFORM)/destroy_env.sh" "$(ENV)"

list: ## List all active envs (with TTL remaining).
	@if ! ls "$(ENVS_DIR)"/env-*.json >/dev/null 2>&1; then echo "(no active envs)"; exit 0; fi
	@now=$$(date +%s); \
	 for f in "$(ENVS_DIR)"/env-*.json; do \
	    id=$$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$$f" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/'); \
	    name=$$(grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' "$$f" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/'); \
	    created=$$(grep -oE '"created_at"[[:space:]]*:[[:space:]]*[0-9]+' "$$f" | grep -oE '[0-9]+'); \
	    ttl=$$(grep -oE '"ttl"[[:space:]]*:[[:space:]]*[0-9]+' "$$f" | head -n1 | grep -oE '[0-9]+'); \
	    status=$$(grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]+"' "$$f" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/'); \
	    rem=$$(( created + ttl - now )); [ $$rem -lt 0 ] && rem=0; \
	    printf '%-18s %-12s ttl_remaining=%-5ss status=%s\n' "$$id" "$$name" "$$rem" "$$status"; \
	 done

logs: ## Tail an env's app log. Required: ENV=env-...
	@if [ -z "$(ENV)" ]; then echo "Usage: make logs ENV=env-..."; exit 2; fi
	@if [ ! -f "$(LOGS_DIR)/$(ENV)/app.log" ]; then echo "no logs for $(ENV)"; exit 1; fi
	@tail -n 100 -f "$(LOGS_DIR)/$(ENV)/app.log"

health: ## Show the latest health status for every env.
	@if ! ls "$(ENVS_DIR)"/env-*.json >/dev/null 2>&1; then echo "(no active envs)"; exit 0; fi
	@for f in "$(ENVS_DIR)"/env-*.json; do \
	    id=$$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$$f" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/'); \
	    status=$$(grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]+"' "$$f" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/'); \
	    fails=$$(grep -oE '"consecutive_failures"[[:space:]]*:[[:space:]]*[0-9]+' "$$f" | grep -oE '[0-9]+$$'); \
	    last=""; \
	    if [ -f "$(LOGS_DIR)/$$id/health.log" ]; then last=$$(tail -n1 "$(LOGS_DIR)/$$id/health.log"); fi; \
	    printf '%-18s status=%-9s failures=%-2s last="%s"\n' "$$id" "$$status" "$$fails" "$$last"; \
	 done

simulate: ## Trigger an outage. Required: ENV=env-... MODE=crash|pause|network|recover|stress
	@if [ -z "$(ENV)" ] || [ -z "$(MODE)" ]; then \
	    echo "Usage: make simulate ENV=env-... MODE=crash|pause|network|recover|stress"; exit 2; \
	fi
	@"$(PLATFORM)/simulate_outage.sh" --env "$(ENV)" --mode "$(MODE)"

clean: ## Destroy all envs and wipe state, logs, archives, generated nginx confs.
	@$(MAKE) --no-print-directory _destroy_all || true
	@rm -rf "$(LOGS_DIR)"/* "$(ENVS_DIR)"/*.json "$(ROOT)/nginx/conf.d"/*.conf
	@echo "[clean] state, logs, archives, generated nginx configs wiped"

_destroy_all:
	@if ls "$(ENVS_DIR)"/env-*.json >/dev/null 2>&1; then \
	    for f in "$(ENVS_DIR)"/env-*.json; do \
	        id=$$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$$f" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/'); \
	        echo "[clean] destroying $$id"; \
	        "$(PLATFORM)/destroy_env.sh" "$$id" || true; \
	    done; \
	fi

# ---- background services ---------------------------------------------------

api-start: dirs ## Start the Flask control API in the background.
	@if [ -f "$(API_PID)" ] && kill -0 $$(cat "$(API_PID)") 2>/dev/null; then \
	    echo "[api] already running (pid $$(cat $(API_PID)))"; \
	else \
	    nohup $(PYTHON) "$(PLATFORM)/api.py" >> "$(LOGS_DIR)/api.log" 2>&1 & \
	    echo $$! > "$(API_PID)"; \
	    echo "[api] started (pid $$(cat $(API_PID))) on :$(API_PORT)"; \
	fi

api-stop: ## Stop the control API.
	@if [ -f "$(API_PID)" ]; then \
	    pid=$$(cat "$(API_PID)"); \
	    kill $$pid 2>/dev/null || true; \
	    rm -f "$(API_PID)"; echo "[api] stopped (pid $$pid)"; \
	fi

daemon-start: dirs ## Start the cleanup daemon (nohup).
	@if [ -f "$(DAEMON_PID)" ] && kill -0 $$(cat "$(DAEMON_PID)") 2>/dev/null; then \
	    echo "[daemon] already running (pid $$(cat $(DAEMON_PID)))"; \
	else \
	    nohup "$(PLATFORM)/cleanup_daemon.sh" >> "$(LOGS_DIR)/cleanup.log" 2>&1 & \
	    echo $$! > "$(DAEMON_PID)"; \
	    echo "[daemon] started (pid $$(cat $(DAEMON_PID)))"; \
	fi

daemon-stop: ## Stop the cleanup daemon.
	@if [ -f "$(DAEMON_PID)" ]; then \
	    pid=$$(cat "$(DAEMON_PID)"); \
	    kill $$pid 2>/dev/null || true; \
	    rm -f "$(DAEMON_PID)"; echo "[daemon] stopped (pid $$pid)"; \
	fi

monitor-start: dirs ## Start the health monitor (nohup).
	@if [ -f "$(MON_PID)" ] && kill -0 $$(cat "$(MON_PID)") 2>/dev/null; then \
	    echo "[monitor] already running (pid $$(cat $(MON_PID)))"; \
	else \
	    nohup $(PYTHON) "$(MONITOR)/health_monitor.py" >> "$(LOGS_DIR)/monitor.log" 2>&1 & \
	    echo $$! > "$(MON_PID)"; \
	    echo "[monitor] started (pid $$(cat $(MON_PID)))"; \
	fi

monitor-stop: ## Stop the health monitor.
	@if [ -f "$(MON_PID)" ]; then \
	    pid=$$(cat "$(MON_PID)"); \
	    kill $$pid 2>/dev/null || true; \
	    rm -f "$(MON_PID)"; echo "[monitor] stopped (pid $$pid)"; \
	fi
