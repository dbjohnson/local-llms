#!/usr/bin/env bash

# Tear-down script: stop all local LLM services and restore original configs.
#
# Usage:
#   ./run/teardown.sh              # stop services + restore Codex + opencode configs
#   ./run/teardown.sh --no-config  # stop services only, leave configs as-is
#   ./run/teardown.sh --config     # restore configs only (don't stop services)
#   ./run/teardown.sh --status     # show what's currently running

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Constants ────────────────────────────────────────────────────────────────

CODEX_CONFIG="${HOME}/.codex/config.toml"
OPENCODE_CONFIG="${HOME}/.config/opencode/opencode.jsonc"

# Known ports and their services (parallel arrays for bash 3 compatibility)
SERVICES_PORTS="8080 8082"
SERVICES_NAMES="llama-server 'opencodex proxy'"

# Known PID files
PID_FILES=(
  "/tmp/qwen3.6-27b.pid"
  "/tmp/qwen3.6-35b-a3b.pid"
  "/tmp/llama-server.pid"
  "/tmp/llama-server-opencode.pid"
  "/tmp/opencodex.pid"
)

# ── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[teardown]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[teardown]${NC} $1"; }
log_error() { echo -e "${RED}[teardown]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[teardown]${NC} $1"; }

# ── Helpers ──────────────────────────────────────────────────────────────────

find_pid_by_port() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -t -i ":${port}" -sTCP:LISTEN 2>/dev/null || true
  elif command -v fuser >/dev/null 2>&1; then
    fuser "${port}/tcp" 2>/dev/null || true
  fi
}

get_service_name() {
  local port="$1"
  case "$port" in
    8080) echo "llama-server" ;;
    8082) echo "opencodex proxy" ;;
    *)    echo "unknown" ;;
  esac
}

kill_process() {
  local pid="$1"
  local name="$2"

  if ! kill -0 "$pid" 2>/dev/null; then
    log_info "${name} (PID ${pid}) is not running, skipping."
    return 0
  fi

  log_info "Stopping ${name} (PID ${pid})..."
  kill "$pid" 2>/dev/null || true

  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 5 )); do
    sleep 1
    (( waited++ ))
  done

  if kill -0 "$pid" 2>/dev/null; then
    log_warn "${name} did not stop gracefully, sending SIGKILL..."
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    log_info "${name} stopped."
  else
    log_error "Failed to stop ${name} (PID ${pid})."
  fi
}

# Restore a config file from its latest backup
restore_config_file() {
  local config_path="$1"
  local label="$2"

  if [[ ! -f "$config_path" ]]; then
    log_info "${label} config not found at ${config_path}, skipping."
    return 0
  fi

  local latest_backup
  latest_backup=$(ls -t "${config_path}".backup.* 2>/dev/null | head -1 || echo "")

  if [[ -z "$latest_backup" ]]; then
    log_warn "No ${label} config backup found."
    return 0
  fi

  cp "$latest_backup" "$config_path"
  log_info "Restored ${label} config from ${latest_backup}"
  rm -f "$latest_backup"
}

# ── Status ──────────────────────────────────────────────────────────────────

show_status() {
  log_step "=== Running services ==="
  local found=false

  # Check by port
  local port
  for port in $SERVICES_PORTS; do
    local pids
    pids=$(find_pid_by_port "$port")
    if [[ -n "$pids" ]]; then
      found=true
      local name
      name=$(get_service_name "$port")
      for pid in $pids; do
        echo -e "  ${GREEN}●${NC} ${name} on port ${port} (PID ${pid})"
      done
    fi
  done

  # Check by PID files
  for pid_file in "${PID_FILES[@]}"; do
    if [[ -f "$pid_file" ]]; then
      local pid
      pid=$(cat "$pid_file" 2>/dev/null || echo "")
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        local already_found=false
        for p in $(find_pid_by_port 8080) $(find_pid_by_port 8082); do
          [[ "$p" == "$pid" ]] && already_found=true
        done
        if [[ "$already_found" == "false" ]]; then
          found=true
          echo -e "  ${GREEN}●${NC} process from ${pid_file} (PID ${pid})"
        fi
      fi
    fi
  done

  # Check for Codex Desktop
  if pgrep -x "Codex" >/dev/null 2>&1; then
    found=true
    local codex_pids
    codex_pids=$(pgrep -x "Codex" | tr '\n' ', ' | sed 's/,$//')
    echo -e "  ${GREEN}●${NC} Codex Desktop (PID(s): ${codex_pids})"
  fi

  if [[ "$found" == "false" ]]; then
    log_info "No local LLM services detected."
  fi

  # Check config backup status
  log_step "=== Config backups ==="
  for config_path in "${CODEX_CONFIG}" "${OPENCODE_CONFIG}"; do
    local label
    label=$(basename "$(dirname "$config_path")")
    local latest_backup
    latest_backup=$(ls -t "${config_path}".backup.* 2>/dev/null | head -1 || echo "")
    if [[ -n "$latest_backup" ]]; then
      echo -e "  ${CYAN}●${NC} ${label}: ${latest_backup}"
    else
      echo -e "  ${YELLOW}●${NC} ${label}: no backups"
    fi
  done
}

# ── Stop Services ───────────────────────────────────────────────────────────

stop_services() {
  log_step "=== Stopping services ==="

  # Stop by port (primary detection)
  local port
  for port in $SERVICES_PORTS; do
    local pids
    pids=$(find_pid_by_port "$port")
    if [[ -n "$pids" ]]; then
      local name
      name=$(get_service_name "$port")
      for pid in $pids; do
        kill_process "$pid" "$name"
      done
    else
      local name
      name=$(get_service_name "$port")
      log_info "No ${name} found on port ${port}."
    fi
  done

  # Stop by PID files (catch anything missed)
  for pid_file in "${PID_FILES[@]}"; do
    if [[ -f "$pid_file" ]]; then
      local pid
      pid=$(cat "$pid_file" 2>/dev/null || echo "")
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        local name
        name=$(basename "$pid_file" .pid)
        kill_process "$pid" "$name"
      fi
      # Always clean up stale PID files
      rm -f "$pid_file"
    fi
  done

  log_info "Service teardown complete."
}

# ── Restore Configs ─────────────────────────────────────────────────────────

restore_configs() {
  log_step "=== Restoring configs ==="

  restore_config_file "${CODEX_CONFIG}" "Codex"

  # Clear stale model cache
  if [[ -f "${HOME}/.codex/models_cache.json" ]]; then
    rm -f "${HOME}/.codex/models_cache.json"
    log_info "Cleared stale Codex model cache."
  fi

  restore_config_file "${OPENCODE_CONFIG}" "opencode"

  log_info "Config restoration complete."
}

# ── Parse Arguments ─────────────────────────────────────────────────────────

ACTION_STATUS=false
ACTION_STOP=true
ACTION_CONFIG=true

for arg in "$@"; do
  case "$arg" in
    --status)
      ACTION_STATUS=true
      ACTION_STOP=false
      ACTION_CONFIG=false
      ;;
    --no-config)
      ACTION_CONFIG=false
      ;;
    --config)
      ACTION_STOP=false
      ACTION_CONFIG=true
      ;;
    --help|-h)
      echo "Usage: ./run/teardown.sh [OPTIONS]"
      echo ""
      echo "Stop local LLM services and restore original configurations."
      echo ""
      echo "Options:"
      echo "  --status     Show running services and config backup status"
      echo "  --no-config  Stop services but leave configs as-is"
      echo "  --config     Restore configs only (don't stop services)"
      echo "  --help       Show this help message"
      echo ""
      echo "Default (no flags): stop services AND restore configs."
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Use --help for usage." >&2
      exit 1
      ;;
  esac
done

# ── Main ────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Local LLM Tear-Down                                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$ACTION_STATUS" == "true" ]] || [[ "$ACTION_STOP" == "true" ]]; then
  show_status
fi

if [[ "$ACTION_STOP" == "true" ]]; then
  echo ""
  stop_services
fi

if [[ "$ACTION_CONFIG" == "true" ]]; then
  echo ""
  restore_configs
fi

if [[ "$ACTION_STATUS" == "true" ]]; then
  log_info "Status check complete."
else
  echo ""
  log_info "╔══════════════════════════════════════════════════════════════╗"
  log_info "║   Tear-down complete. Run ./run/codex.sh to start again.    ║"
  log_info "╚══════════════════════════════════════════════════════════════╝"
  echo ""
fi
