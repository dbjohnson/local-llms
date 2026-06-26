#!/usr/bin/env bash

# Tear-down script: stop all local LLM services and restore original Codex config.
#
# Usage:
#   ./run/teardown.sh              # stop services + restore config
#   ./run/teardown.sh --no-config  # stop services only, leave config as-is
#   ./run/teardown.sh --config     # restore config only (don't kill anything)
#   ./run/teardown.sh --status     # show what's currently running

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Constants ────────────────────────────────────────────────────────────────

CODEX_CONFIG="${HOME}/.codex/config.toml"

# Known ports and their services
declare -A SERVICE_PORTS
SERVICE_PORTS=(
  ["8080"]="llama-server"
  ["8082"]="opencodex proxy"
)

# Known PID files
PID_FILES=("/tmp/qwen3.6-27b.pid" "/tmp/llama-server.pid" "/tmp/opencodex.pid")

# ── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[teardown]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[teardown]${NC} $1"; }
log_error() { echo -e "${RED}[teardown]${NC} $1"; }
log_step()  { echo -e "${CYAN}[teardown]${NC} $1"; }

# ── Helpers ──────────────────────────────────────────────────────────────────

# Find the PID listening on a given port
find_pid_by_port() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -t -i ":${port}" -sTCP:LISTEN 2>/dev/null || true
  elif command -v fuser >/dev/null 2>&1; then
    fuser "${port}/tcp" 2>/dev/null || true
  fi
}

# Kill a PID gracefully (SIGTERM), then force (SIGKILL) if needed
kill_process() {
  local pid="$1"
  local name="$2"

  if ! kill -0 "$pid" 2>/dev/null; then
    log_info "${name} (PID ${pid}) is not running, skipping."
    return 0
  fi

  log_info "Stopping ${name} (PID ${pid})..."
  kill "$pid" 2>/dev/null || true

  # Wait up to 5 seconds for graceful shutdown
  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 5 )); do
    sleep 1
    (( waited++ ))
  done

  # Force kill if still alive
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

# ── Status ──────────────────────────────────────────────────────────────────

show_status() {
  log_step "=== Running services ==="
  local found=false

  # Check by port
  for port in "${!SERVICE_PORTS[@]}"; do
    local pids
    pids=$(find_pid_by_port "$port")
    if [[ -n "$pids" ]]; then
      found=true
      for pid in $pids; do
        local name="${SERVICE_PORTS[$port]}"
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
        # Only report if not already found by port
        local already_found=false
        for pids in $(find_pid_by_port 8080) $(find_pid_by_port 8082); do
          [[ "$pids" == "$pid" ]] && already_found=true
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
  local latest_backup
  latest_backup=$(ls -t "${CODEX_CONFIG}".backup.* 2>/dev/null | head -1 || echo "")
  if [[ -n "$latest_backup" ]]; then
    echo -e "  ${CYAN}●${NC} Latest backup: ${latest_backup}"
  else
    echo -e "  ${YELLOW}●${NC} No config backups found (nothing to restore)"
  fi
}

# ── Stop Services ───────────────────────────────────────────────────────────

stop_services() {
  log_step "=== Stopping services ==="

  # Stop by port (primary detection)
  for port in "${!SERVICE_PORTS[@]}"; do
    local pids
    pids=$(find_pid_by_port "$port")
    if [[ -n "$pids" ]]; then
      local name="${SERVICE_PORTS[$port]}"
      for pid in $pids; do
        kill_process "$pid" "$name"
      done
    else
      log_info "No ${name} found on port ${port}."
    fi
  done

  # Stop by PID files (catch anything missed)
  for pid_file in "${PID_FILES[@]}"; do
    if [[ -f "$pid_file" ]]; then
      local pid
      pid=$(cat "$pid_file" 2>/dev/null || echo "")
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        # Derive a name from the file
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

# ── Restore Config ──────────────────────────────────────────────────────────

restore_config() {
  log_step "=== Restoring Codex config ==="

  # Find the latest backup
  local latest_backup
  latest_backup=$(ls -t "${CODEX_CONFIG}".backup.* 2>/dev/null | head -1 || echo "")

  if [[ -z "$latest_backup" ]]; then
    log_warn "No config backup found at ${CODEX_CONFIG}.backup.*"
    log_warn "Removing current config so Codex falls back to defaults."
    if [[ -f "${CODEX_CONFIG}" ]]; then
      rm -f "${CODEX_CONFIG}"
      log_info "Removed ${CODEX_CONFIG}"
    fi
  else
    cp "$latest_backup" "${CODEX_CONFIG}"
    log_info "Restored config from ${latest_backup}"
    rm -f "$latest_backup"
    log_info "Removed backup (backup was consumed)."
  fi

  # Clear stale model cache
  if [[ -f "${HOME}/.codex/models_cache.json" ]]; then
    rm -f "${HOME}/.codex/models_cache.json"
    log_info "Cleared stale model cache."
  fi

  log_info "Config restoration complete."
}

# ── Parse Arguments ─────────────────────────────────────────────────────────

ACTION_STOP=true
ACTION_CONFIG=true

for arg in "$@"; do
  case "$arg" in
    --status)
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
      echo "Stop local LLM services and restore original Codex configuration."
      echo ""
      echo "Options:"
      echo "  --status     Show running services and config backup status"
      echo "  --no-config  Stop services but leave Codex config as-is"
      echo "  --config     Restore config only (don't stop services)"
      echo "  --help       Show this help message"
      echo ""
      echo "Default (no flags): stop services AND restore config."
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

if [[ "$ACTION_STOP" == "true" ]]; then
  show_status
  echo ""
  stop_services
fi

if [[ "$ACTION_CONFIG" == "true" ]]; then
  echo ""
  restore_config
fi

echo ""
log_info "╔══════════════════════════════════════════════════════════════╗"
log_info "║   Tear-down complete. Run ./run/codex.sh to start again.    ║"
log_info "╚══════════════════════════════════════════════════════════════╝"
echo ""
