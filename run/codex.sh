#!/usr/bin/env bash

# Orchestrate the Codex Desktop app to use llama-server on port 8080
# via opencodex proxy (https://github.com/lidge-jun/opencodex)
# This script starts llama-server, starts opencodex proxy, configures Codex, then launches Codex Desktop.
#
# Default: backgrounds itself after launching Codex. Use --foreground to block
# in the terminal (and auto-teardown when Codex closes).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_CONFIG="${HOME}/.codex/config.toml"
OPENCODEX_CONFIG="${HOME}/.opencodex/config.json"
LLAMA_PORT=8080
PROXY_PORT=8082
MODEL="${MODEL:-unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M}"
LLAMA_SCRIPT="${LLAMA_SCRIPT:-${SCRIPT_DIR}/qwen3.6-35b-a3b.sh}"
CATALOG="${SCRIPT_DIR}/llama-server-models.json"

# Parse flags
FOREGROUND=false
for arg in "$@"; do
  [[ "$arg" == "--foreground" || "$arg" == "-f" ]] && FOREGROUND=true
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[codex]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[codex]${NC} $1"
}

log_error() {
    echo -e "${RED}[codex]${NC} $1"
}

# Check if a process is listening on a port
is_port_listening() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        nc -z localhost "${port}" >/dev/null 2>&1
    else
        # Fallback: try curl
        curl -sf "http://localhost:${port}/health" >/dev/null 2>&1 || \
        curl -sf "http://localhost:${port}/healthz" >/dev/null 2>&1
    fi
}

# Wait for a port to be ready
wait_for_port() {
    local port="$1"
    local name="$2"
    local max_attempts="${3:-30}"
    
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

# Start llama-server if not running
start_llama_server() {
    if is_port_listening "${LLAMA_PORT}"; then
        log_info "llama-server already running on port ${LLAMA_PORT}"
        return 0
    fi
    
    log_info "Starting llama-server on port ${LLAMA_PORT}..."
    local llama_script="${LLAMA_SCRIPT}"

    if [[ ! -f "${llama_script}" ]]; then
        log_error "llama-server script not found: ${llama_script}"
        return 1
    fi

    # Run the model script (it backgrounds itself by default)
    nohup bash "${llama_script}" >/tmp/llama-server.log 2>&1 &
    local llama_pid=$!
    
    if ! wait_for_port "${LLAMA_PORT}" "llama-server" 60; then
        log_error "Failed to start llama-server"
        kill "${llama_pid}" 2>/dev/null || true
        return 1
    fi
    
    # Save PID for teardown
    echo "${llama_pid}" > /tmp/llama-server.pid
    log_info "llama-server started (PID: ${llama_pid})"
}

# Start opencodex proxy if not running
start_opencodex_proxy() {
    if is_port_listening "${PROXY_PORT}"; then
        log_info "opencodex proxy already running on port ${PROXY_PORT}"
        return 0
    fi
    
    log_info "Starting opencodex proxy on port ${PROXY_PORT}..."
    
    # Ensure opencodex config exists
    mkdir -p "$(dirname "${OPENCODEX_CONFIG}")"
    cat > "${OPENCODEX_CONFIG}" <<EOF
{
  "port": ${PROXY_PORT},
  "defaultProvider": "llama-local",
  "providers": {
    "llama-local": {
      "adapter": "openai-chat",
      "baseUrl": "http://localhost:${LLAMA_PORT}/v1",
      "authMode": "key",
      "apiKey": "",
      "defaultModel": "${MODEL}",
      "modelContextWindows": {
        "${MODEL}": 65536
      }
    }
  }
}
EOF
    
    # Ensure bun is in PATH
    if [[ -d "${HOME}/.bun/bin" ]]; then
        export PATH="${HOME}/.bun/bin:${PATH}"
    fi
    
    if ! command -v ocx >/dev/null 2>&1; then
        log_error "ocx command not found. Please install opencodex: npm install -g @bitkyc08/opencodex"
        return 1
    fi
    
    nohup ocx start --port "${PROXY_PORT}" >/tmp/opencodex.log 2>&1 &
    local proxy_pid=$!
    
    if ! wait_for_port "${PROXY_PORT}" "opencodex proxy" 30; then
        log_error "Failed to start opencodex proxy"
        kill "${proxy_pid}" 2>/dev/null || true
        return 1
    fi
    
    # Save PID for teardown
    echo "${proxy_pid}" > /tmp/opencodex.pid
    log_info "opencodex proxy started (PID: ${proxy_pid})"
    
    # ocx start auto-syncs models which may overwrite the catalog
    # We will rewrite the catalog in configure_codex() after this
}

# Configure Codex to use the proxy
configure_codex() {
    log_info "Configuring Codex to use local model..."
    
    # Always write model catalog to ensure it's not empty
    log_info "Writing model catalog..."
    cat > "${CATALOG}" <<EOF
{
  "fetched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "client_version": "26.623.31921",
  "models": [
    {
      "slug": "llama-local/${MODEL}",
      "display_name": "llama-local/${MODEL}",
      "description": "Routed via opencodex → llama-local (llamacpp).",
      "shell_type": "shell_command",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 5,
      "base_instructions": "You are a helpful coding assistant.",
      "web_search_tool_type": "text_and_image",
      "supports_search_tool": true,
      "supported_reasoning_levels": [
        {"effort": "low", "description": "Fast responses"},
        {"effort": "medium", "description": "Balanced"},
        {"effort": "high", "description": "Deep reasoning"},
        {"effort": "xhigh", "description": "Maximum reasoning"}
      ],
      "default_reasoning_level": "medium",
      "context_window": 131072,
      "max_context_window": 131072,
      "auto_compact_token_limit": 117964,
      "supports_reasoning_summaries": true,
      "default_reasoning_summary": "none",
      "support_verbosity": true,
      "default_verbosity": "low",
      "apply_patch_tool_type": "freeform",
      "truncation_policy": {
        "mode": "tokens",
        "limit": 10000
      },
      "supports_parallel_tool_calls": true,
      "supports_image_detail_original": false,
      "experimental_supported_tools": [],
      "input_modalities": ["text"],
      "effective_context_window_percent": 95,
      "comp_hash": "opencodex"
    }
  ]
}
EOF
    
    # Backup existing config
    if [[ -f "${CODEX_CONFIG}" ]]; then
        cp "${CODEX_CONFIG}" "${CODEX_CONFIG}.backup.$(date +%s)"
    fi
    
    # Write new config
    cat > "${CODEX_CONFIG}" <<EOF
model = "llama-local/${MODEL}"
model_provider = "opencodex"
model_catalog_json = "${CATALOG}"

notify = ["${HOME}/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"]

[model_providers.opencodex]
name = "OpenCodex Proxy"
base_url = "http://localhost:${PROXY_PORT}/v1"
wire_api = "responses"
requires_openai_auth = true

[features]
js_repl = false
EOF
    
    # Clear stale model cache
    if [[ -f "${HOME}/.codex/models_cache.json" ]]; then
        rm -f "${HOME}/.codex/models_cache.json"
        log_info "Cleared stale model cache"
    fi
    
    log_info "Codex configured successfully"
}

# Cleanup function (only used in foreground mode)
cleanup() {
    log_info "Cleaning up..."
    
    # Kill opencodex proxy
    if [[ -f /tmp/opencodex.pid ]]; then
        local proxy_pid
        proxy_pid=$(cat /tmp/opencodex.pid)
        if kill -0 "${proxy_pid}" 2>/dev/null; then
            log_info "Stopping opencodex proxy (PID: ${proxy_pid})..."
            kill "${proxy_pid}" 2>/dev/null || true
            rm -f /tmp/opencodex.pid
        fi
    fi
    
    # Kill llama-server
    if [[ -f /tmp/llama-server.pid ]]; then
        local llama_pid
        llama_pid=$(cat /tmp/llama-server.pid)
        if kill -0 "${llama_pid}" 2>/dev/null; then
            log_info "Stopping llama-server (PID: ${llama_pid})..."
            kill "${llama_pid}" 2>/dev/null || true
            rm -f /tmp/llama-server.pid
        fi
    fi
    
    log_info "Cleanup complete"
}

# ── Main execution ──────────────────────────────────────────────────────────

# Check if Codex is already running
if pgrep -x "Codex" >/dev/null 2>&1; then
    log_warn "Codex Desktop is already running."
    log_warn "Please close it first, then run this script again."
    exit 1
fi

log_info "Starting local LLM setup for Codex..."

# Step 1: Start llama-server
if ! start_llama_server; then
    log_error "Failed to start llama-server"
    exit 1
fi

# Step 2: Start opencodex proxy
if ! start_opencodex_proxy; then
    log_error "Failed to start opencodex proxy"
    exit 1
fi

# Wait for ocx to finish auto-sync (which may overwrite the catalog)
log_info "Waiting for opencodex to finish setup..."
sleep 5

# Step 3: Configure Codex
configure_codex

# Step 4: Verify catalog is not empty (ocx sync may have overwritten it)
if ! grep -q '"models":\s*\[' "${CATALOG}" 2>/dev/null || grep -q '"models":\s*\[\s*\]' "${CATALOG}" 2>/dev/null; then
    log_warn "Catalog was overwritten by ocx sync, rewriting..."
    configure_codex
fi

# Step 5: Launch Codex Desktop
log_info "Launching Codex Desktop..."
log_info "Model: ${MODEL}"
log_info "Proxy: http://localhost:${PROXY_PORT}/v1"

open -a "Codex" || true

if [[ "$FOREGROUND" == "true" ]]; then
    # Foreground mode: trap cleanup and block until Codex closes
    trap cleanup EXIT INT TERM
    
    log_info "Running in foreground — waiting for Codex Desktop to close..."
    log_info "Press Ctrl+C to stop services now."
    
    while pgrep -x "Codex" >/dev/null 2>&1; do
        sleep 2
    done
    
    log_info "Codex Desktop has closed. Cleaning up services..."
else
    # Background mode (default): detach and leave services running
    log_info "Running in background. Services will keep running."
    log_info "  To stop: ./run/teardown.sh"
    log_info "  To start fresh: ./run/teardown.sh && ./run/codex.sh"
fi

exit 0
