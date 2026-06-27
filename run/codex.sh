#!/usr/bin/env bash
# Orchestrate Codex Desktop to use llama-server on port 8080 via opencodex proxy.
#
# Starts llama-server → opencodex proxy → configures Codex → launches Codex.
#
# Usage:
#   ./run/codex.sh                     # background (default)
#   ./run/codex.sh --foreground        # block in terminal, auto-teardown on exit
#   ./run/codex.sh --help              # show usage
#
# Environment variables:
#   MODEL        HuggingFace model ID (default: Qwen3.6-35B-A3B)
#   LLAMA_SCRIPT Path to model server script (default: qwen3.6-35b-a3b.sh)
#   LLAMA_PORT   llama-server port (default: 8080)
#   PROXY_PORT   opencodex proxy port (default: 8082)

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_CONFIG="${HOME}/.codex/config.toml"
OPENCODEX_CONFIG="${HOME}/.opencodex/config.json"
LLAMA_PORT="${LLAMA_PORT:-8080}"
PROXY_PORT="${PROXY_PORT:-8082}"
MODEL="${MODEL:-unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M}"
LLAMA_SCRIPT="${LLAMA_SCRIPT:-${SCRIPT_DIR}/qwen3.6-35b-a3b.sh}"
CATALOG="${SCRIPT_DIR}/llama-server-models.json"

# ── Parse arguments ────────────────────────────────────────────────────────

FOREGROUND=false
ACTION_HELP=false
for arg in "$@"; do
    case "$arg" in
        --foreground|-f)
            FOREGROUND=true
            ;;
        --help|-h)
            ACTION_HELP=true
            ;;
        *)
            log_error "codex" "Unknown option: $arg"
            echo "Use --help for usage." >&2
            exit 1
            ;;
    esac
done

if [[ "$ACTION_HELP" == "true" ]]; then
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Orchestrate Codex Desktop with a local llama-server + opencodex proxy."
    echo ""
    echo "Options:"
    echo "  --foreground   Block in terminal; auto-teardown when Codex closes"
    echo "  --help         Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  MODEL          HuggingFace model ID (default: unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M)"
    echo "  LLAMA_SCRIPT   Model server script (default: ./run/qwen3.6-35b-a3b.sh)"
    echo "  LLAMA_PORT     llama-server port (default: 8080)"
    echo "  PROXY_PORT     opencodex proxy port (default: 8082)"
    echo ""
    echo "Examples:"
    echo "  $0                                          # use default 35B-A3B"
    echo "  MODEL=unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M \\"
    echo "  LLAMA_SCRIPT=./run/qwen3.6-27b.sh $0       # use 27B model"
    exit 0
fi

# ── Validate ───────────────────────────────────────────────────────────────

validate_port "$LLAMA_PORT" || exit 1
validate_port "$PROXY_PORT" || exit 1
validate_model "$MODEL"

# ── Check if Codex is already running ──────────────────────────────────────

if pgrep -x "Codex" >/dev/null 2>&1; then
    log_warn "codex" "Codex Desktop is already running."
    log_warn "codex" "Please close it first, then run this script again."
    exit 1
fi

log_info "codex" "Starting local LLM setup for Codex..."

# ── Step 1: Start llama-server ─────────────────────────────────────────────

start_llama_server() {
    if is_port_listening "${LLAMA_PORT}"; then
        log_info "llama" "Already running on port ${LLAMA_PORT}"
        return 0
    fi

    if [[ ! -f "${LLAMA_SCRIPT}" ]]; then
        log_error "llama" "Model script not found: ${LLAMA_SCRIPT}"
        return 1
    fi

    log_info "llama" "Starting llama-server on port ${LLAMA_PORT}..."
    log_info "llama" "Using script: ${LLAMA_SCRIPT}"

    # The model script writes its own PID to a known file.
    # We start it via nohup and wait for port readiness.
    nohup bash "${LLAMA_SCRIPT}" >/tmp/llama-server.log 2>&1 &
    local wrapper_pid=$!

    # Wait for the port to be ready
    if ! wait_for_port "${LLAMA_PORT}" "llama-server" 60; then
        log_error "llama" "Failed to start llama-server"
        kill "${wrapper_pid}" 2>/dev/null || true
        return 1
    fi

    # Save a reference PID for teardown (the wrapper process).
    # The model script also writes its own PID to /tmp/qwen3.6-*.pid.
    echo "${wrapper_pid}" > /tmp/llama-server.pid
    log_info "llama" "Started (wrapper PID: ${wrapper_pid})"
}

# ── Step 2: Start opencodex proxy ──────────────────────────────────────────

start_opencodex_proxy() {
    if is_port_listening "${PROXY_PORT}"; then
        log_info "proxy" "Already running on port ${PROXY_PORT}"
        return 0
    fi

    log_info "proxy" "Starting opencodex proxy on port ${PROXY_PORT}..."

    # Ensure opencodex config exists
    mkdir -p "$(dirname "${OPENCODEX_CONFIG}")"
    cat > "${OPENCODEX_CONFIG}" <<OCXCFG_EOF
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
OCXCFG_EOF

    # Ensure bun is in PATH
    if [[ -d "${HOME}/.bun/bin" ]]; then
        export PATH="${HOME}/.bun/bin:${PATH}"
    fi

    if ! command -v ocx >/dev/null 2>&1; then
        log_error "proxy" "ocx command not found. Please install opencodex:"
        log_error "proxy" "  npm install -g @bitkyc08/opencodex"
        return 1
    fi

    nohup ocx start --port "${PROXY_PORT}" >/tmp/opencodex.log 2>&1 &
    local proxy_pid=$!

    if ! wait_for_port "${PROXY_PORT}" "opencodex proxy" 30; then
        log_error "proxy" "Failed to start opencodex proxy"
        kill "${proxy_pid}" 2>/dev/null || true
        return 1
    fi

    echo "${proxy_pid}" > /tmp/opencodex.pid
    log_info "proxy" "Started (PID: ${proxy_pid})"

    # ocx start auto-syncs models which may overwrite the catalog.
    # We rewrite it below after the sync completes.
}

# ── Step 3: Configure Codex ────────────────────────────────────────────────

configure_codex() {
    log_info "config" "Configuring Codex to use local model..."

    # Always write model catalog
    log_info "config" "Writing model catalog..."
    generate_catalog "${CATALOG}" "${MODEL}" 131072

    # Backup existing config (uses nanosecond timestamp to avoid collisions)
    backup_config "${CODEX_CONFIG}" "config"

    # Write new config
    cat > "${CODEX_CONFIG}" <<CODEXCFG_EOF
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
CODEXCFG_EOF

    # Clear stale model cache
    if [[ -f "${HOME}/.codex/models_cache.json" ]]; then
        rm -f "${HOME}/.codex/models_cache.json"
        log_info "config" "Cleared stale model cache"
    fi

    log_info "config" "Codex configured successfully"
}

# ── Cleanup (foreground mode only) ─────────────────────────────────────────

cleanup() {
    log_info "cleanup" "Cleaning up..."

    # Kill opencodex proxy
    if [[ -f /tmp/opencodex.pid ]]; then
        local proxy_pid
        proxy_pid=$(cat /tmp/opencodex.pid)
        if kill -0 "${proxy_pid}" 2>/dev/null; then
            kill_process "${proxy_pid}" "opencodex proxy"
        fi
        rm -f /tmp/opencodex.pid
    fi

    # Kill llama-server
    if [[ -f /tmp/llama-server.pid ]]; then
        local llama_pid
        llama_pid=$(cat /tmp/llama-server.pid)
        if kill -0 "${llama_pid}" 2>/dev/null; then
            kill_process "${llama_pid}" "llama-server"
        fi
        rm -f /tmp/llama-server.pid
    fi

    log_info "cleanup" "Done"
}

# ── Main execution ─────────────────────────────────────────────────────────

# Step 1: Start llama-server
if ! start_llama_server; then
    log_error "main" "Failed to start llama-server"
    exit 1
fi

# Step 2: Start opencodex proxy
if ! start_opencodex_proxy; then
    log_error "main" "Failed to start opencodex proxy"
    exit 1
fi

# Wait for ocx to finish auto-sync (which may overwrite the catalog)
log_info "main" "Waiting for opencodex to finish setup..."
sleep 5

# Step 3: Configure Codex (rewrites catalog after ocx sync)
configure_codex

# Step 4: Verify catalog is not empty (ocx sync may have overwritten it)
if ! grep -q '"models":' "${CATALOG}" 2>/dev/null || grep -q '"models":\s*\[\s*\]' "${CATALOG}" 2>/dev/null; then
    log_warn "main" "Catalog was overwritten by ocx sync, rewriting..."
    configure_codex
fi

# Step 5: Launch Codex Desktop
log_info "main" "Launching Codex Desktop..."
log_info "main" "Model: ${MODEL}"
log_info "main" "Proxy: http://localhost:${PROXY_PORT}/v1"

open -a "Codex" || true

if [[ "$FOREGROUND" == "true" ]]; then
    trap cleanup EXIT INT TERM

    log_info "main" "Running in foreground — waiting for Codex Desktop to close..."
    log_info "main" "Press Ctrl+C to stop services now."

    while pgrep -x "Codex" >/dev/null 2>&1; do
        sleep 2
    done

    log_info "main" "Codex Desktop has closed. Cleaning up services..."
    cleanup
else
    log_info "main" "Running in background. Services will keep running."
    log_info "main" "  To stop: ./run/teardown.sh"
    log_info "main" "  To start fresh: ./run/teardown.sh && ./run/codex.sh"
fi

exit 0
