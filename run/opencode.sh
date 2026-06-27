#!/usr/bin/env bash

# Configure opencode to use llama-server as a local OpenAI-compatible provider.
#
# Usage:
#   ./run/opencode.sh                      # configure opencode (don't start llama)
#   ./run/opencode.sh --start              # start llama-server + configure opencode
#   ./run/opencode.sh --foreground         # run llama in foreground (for debugging)
#   ./run/opencode.sh --restore            # remove local provider from opencode config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENCODE_CONFIG="${HOME}/.config/opencode/opencode.jsonc"
LLAMA_PORT="${LLAMA_PORT:-8080}"
MODEL="${MODEL:-unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M}"
LLAMA_SCRIPT="${LLAMA_SCRIPT:-${SCRIPT_DIR}/qwen3.6-27b.sh}"

# ── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[opencode]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[opencode]${NC} $1"; }
log_error() { echo -e "${RED}[opencode]${NC} $1"; }
log_step()  { echo -e "${CYAN}[opencode]${NC} $1"; }

# ── Parse arguments ─────────────────────────────────────────────────────────

ACTION_CONFIG=true
ACTION_START=false
ACTION_FOREGROUND=false
ACTION_RESTORE=false

for arg in "$@"; do
  case "$arg" in
    --start)
      ACTION_START=true
      ;;
    --foreground|-f)
      ACTION_START=true
      ACTION_FOREGROUND=true
      ;;
    --restore)
      ACTION_CONFIG=false
      ACTION_RESTORE=true
      ;;
    --help|-h)
      echo "Usage: ./run/opencode.sh [OPTIONS]"
      echo ""
      echo "Configure opencode to use a local llama-server provider."
      echo ""
      echo "Options:"
      echo "  --start          Start llama-server on port ${LLAMA_PORT} + configure opencode"
      echo "  --foreground     Start llama-server in foreground (don't background)"
      echo "  --restore        Remove local provider from opencode config"
      echo "  --help           Show this help message"
      echo ""
      echo "Default (no flags): configure opencode only (llama must be running separately)."
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

is_port_listening() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        nc -z localhost "${port}" >/dev/null 2>&1
    fi
}

wait_for_port() {
    local port="$1"
    local name="$2"
    local max_attempts="${3:-60}"

    log_info "Waiting for ${name} on port ${port}..."
    for i in $(seq 1 "${max_attempts}"); do
        if is_port_listening "${port}"; then
            log_info "${name} is ready on port ${port}"
            return 0
        fi
        sleep 1
    done

    log_error "${name} failed to start on port ${port}"
    return 1
}

# ── Start llama-server ──────────────────────────────────────────────────────

start_llama_server() {
    if is_port_listening "${LLAMA_PORT}"; then
        log_info "llama-server already running on port ${LLAMA_PORT}"
        return 0
    fi

    local llama_script="${LLAMA_SCRIPT}"

    if [[ ! -f "${llama_script}" ]]; then
        log_error "llama-server script not found: ${llama_script}"
        return 1
    fi

    if [[ "$ACTION_FOREGROUND" == "true" ]]; then
        log_info "Starting llama-server in foreground..."
        PORT="${LLAMA_PORT}" bash "${llama_script}" --foreground
        return 0
    fi

    log_info "Starting llama-server on port ${LLAMA_PORT}..."
    PORT="${LLAMA_PORT}" nohup bash "${llama_script}" >/tmp/llama-server-opencode.log 2>&1 &
    local llama_pid=$!

    if ! wait_for_port "${LLAMA_PORT}" "llama-server"; then
        log_error "Failed to start llama-server"
        kill "${llama_pid}" 2>/dev/null || true
        return 1
    fi

    echo "${llama_pid}" > /tmp/llama-server-opencode.pid
    log_info "llama-server started (PID: ${llama_pid})"
}

# ── Configure opencode ──────────────────────────────────────────────────────

configure_opencode() {
    log_step "Configuring opencode..."

    mkdir -p "$(dirname "${OPENCODE_CONFIG}")"

    if [[ ! -f "${OPENCODE_CONFIG}" ]]; then
        echo '{"$schema":"https://opencode.ai/config.json"}' > "${OPENCODE_CONFIG}"
        log_info "Created ${OPENCODE_CONFIG}"
    fi

    cp "${OPENCODE_CONFIG}" "${OPENCODE_CONFIG}.backup.$(date +%s)"
    log_info "Backed up existing config"

    python3 - "${OPENCODE_CONFIG}" "${LLAMA_PORT}" "${MODEL}" << 'PYEOF'
import json, sys

config_path = sys.argv[1]
llama_port = sys.argv[2]
model = sys.argv[3]

with open(config_path, 'r') as f:
    config = json.load(f)

if "provider" not in config:
    config["provider"] = {}

config["provider"]["llama-local"] = {
    "api": "openai",
    "name": "Llama.cpp (local)",
    "options": {
        "baseURL": f"http://localhost:{llama_port}/v1",
        "apiKey": "",
        "timeout": False
    },
    "models": {
        model: {
            "id": model,
            "name": "Qwen3.6-27B (local)",
            "family": "qwen",
            "attachment": False,
            "reasoning": False,
            "temperature": True,
            "tool_call": True,
            "interleaved": True,
            "limit": {
                "context": 131072,
                "output": 32768
            },
            "modalities": {
                "input": ["text"],
                "output": ["text"]
            }
        }
    }
}

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
PYEOF

    log_info "opencode configured with llama-local provider"
    log_info "  Model: llama-local/${MODEL}"
    log_info "  Base URL: http://localhost:${LLAMA_PORT}/v1"
}

# ── Restore (remove local provider) ────────────────────────────────────────

restore_opencode() {
    log_step "Restoring opencode config..."

    local latest_backup
    latest_backup=$(ls -t "${OPENCODE_CONFIG}".backup.* 2>/dev/null | head -1 || echo "")

    if [[ -n "$latest_backup" ]]; then
        cp "$latest_backup" "${OPENCODE_CONFIG}"
        rm -f "$latest_backup"
        log_info "Restored config from backup"
    else
        if [[ -f "${OPENCODE_CONFIG}" ]]; then
            python3 - "${OPENCODE_CONFIG}" << 'PYEOF'
import json, sys

config_path = sys.argv[1]
with open(config_path, 'r') as f:
    config = json.load(f)

provider = config.get("provider", {})
if "llama-local" in provider:
    del provider["llama-local"]
    if not provider:
        del config["provider"]

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
PYEOF
            log_info "Removed llama-local provider from config"
        fi
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   opencode + Local LLM Configuration                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$ACTION_RESTORE" == "true" ]]; then
    restore_opencode
    echo ""
    log_info "Restore complete. opencode is back to its previous state."
    exit 0
fi

if [[ "$ACTION_START" == "true" ]]; then
    start_llama_server
    echo ""
fi

configure_opencode

echo ""
log_info "╔══════════════════════════════════════════════════════════════╗"
log_info "║   opencode is configured!                                   ║"
log_info "╚══════════════════════════════════════════════════════════════╝"
echo ""
log_info "Launch opencode with the local model:"
log_info "  opencode -m llama-local/${MODEL}"
echo ""
log_info "Or set it as default in ${OPENCODE_CONFIG}:"
log_info "  \"model\": \"llama-local/${MODEL}\""
echo ""
log_info "To stop llama-server:"
log_info "  ./run/teardown.sh"
echo ""
