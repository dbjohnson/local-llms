#!/usr/bin/env bash
# Orchestrate Codex Desktop to use either:
#   1. OpenRouter (default) — via opencodex proxy
#   2. Local llama-server + opencodex proxy (--local flag)
#
# Usage:
#   ./run/codex.sh                     # OpenRouter via proxy (default)
#   ./run/codex.sh --local             # local model + proxy
#   ./run/codex.sh --local --foreground  # local model, block in terminal
#   ./run/codex.sh --help              # show usage
#
# Environment variables (OpenRouter mode):
#   OPENROUTER_API_KEY   Required — your OpenRouter API key
#   OPENROUTER_MODEL     Model slug (default: qwen/qwen3.6-35b-a3b)
#   PROXY_PORT           opencodex proxy port (default: 8082)
#
# Environment variables (Local mode):
#   MODEL          HuggingFace model ID (default: Qwen3.6-35B-A3B)
#   LLAMA_SCRIPT   Path to model server script (default: serve_model.sh)
#   LLAMA_PORT     llama-server port (default: 8080)
#   PROXY_PORT     opencodex proxy port (default: 8082)
#   MODEL_CHOICE   Model identifier (e.g. qwen3.6-27b)

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_CONFIG="${HOME}/.codex/config.toml"
OPENCODEX_CONFIG="${HOME}/.opencodex/config.json"
LLAMA_PORT="${LLAMA_PORT:-8080}"
PROXY_PORT="${PROXY_PORT:-8082}"
MODEL="${MODEL:-unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M}"
LLAMA_SCRIPT="${LLAMA_SCRIPT:-${SCRIPT_DIR}/serve_model.sh}"
CATALOG="${SCRIPT_DIR}/llama-server-models.json"
OPENROUTER_MODEL="${OPENROUTER_MODEL:-qwen/qwen3.6-35b-a3b}"

# ── Parse arguments ────────────────────────────────────────────────────────

MODE="openrouter"  # default
FOREGROUND=false
ACTION_HELP=false
for arg in "$@"; do
    case "$arg" in
        --local|-l)
            MODE="local"
            ;;
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
    echo "Orchestrate Codex Desktop with OpenRouter (default) or local models."
    echo ""
    echo "Modes:"
    echo "  (default)      Use OpenRouter API via opencodex proxy (requires OPENROUTER_API_KEY)"
    echo "  --local        Use local llama-server + opencodex proxy"
    echo ""
    echo "Options:"
    echo "  --local        Enable local model mode"
    echo "  --foreground   Block in terminal; auto-teardown when Codex closes"
    echo "  --help         Show this help message"
    echo ""
    echo "Environment variables (OpenRouter mode):"
    echo "  OPENROUTER_API_KEY   Required — your OpenRouter API key"
    echo "  OPENROUTER_MODEL     Model slug (default: qwen/qwen3.6-35b-a3b)"
    echo "  PROXY_PORT           opencodex proxy port (default: 8082)"
    echo ""
    echo "Environment variables (Local mode):"
    echo "  MODEL          HuggingFace model ID (default: unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M)"
    echo "  LLAMA_SCRIPT   Model server script (default: ./run/serve_model.sh)"
    echo "  LLAMA_PORT     llama-server port (default: 8080)"
    echo "  PROXY_PORT     opencodex proxy port (default: 8082)"
    echo "  MODEL_CHOICE   Model identifier (default: qwen3.6-35b-a3b)"
    echo ""
    echo "Examples:"
    echo "  $0                                          # OpenRouter (default)"
    echo "  OPENROUTER_MODEL=openai/gpt-4o $0           # OpenRouter with GPT-4o"
    echo "  $0 --local                                  # local 35B-A3B"
    echo "  MODEL_CHOICE=qwen3.6-27b $0 --local         # local 27B model"
    echo "  MODEL=my-org/my-model:Q4_K_M $0 --local     # custom model"
    exit 0
fi

# ── Validate ───────────────────────────────────────────────────────────────

if [[ "$MODE" == "openrouter" ]]; then
    if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
        log_error "codex" "OPENROUTER_API_KEY is not set"
        log_error "codex" "Export your OpenRouter API key first:"
        log_error "codex" "  export OPENROUTER_API_KEY=\"sk-or-...\""
        exit 1
    fi
    log_info "codex" "Mode: OpenRouter"
    log_info "codex" "Model: ${OPENROUTER_MODEL}"
else
    validate_port "$LLAMA_PORT" || exit 1
    validate_port "$PROXY_PORT" || exit 1
    validate_model "$MODEL"
    log_info "codex" "Mode: Local"
    log_info "codex" "Model: ${MODEL}"
fi

# ── Check if Codex is already running ──────────────────────────────────────

if pgrep -x "Codex" >/dev/null 2>&1; then
    log_warn "codex" "Codex Desktop is already running."
    log_warn "codex" "Please close it first, then run this script again."
    exit 1
fi

log_info "codex" "Starting Codex setup..."

# ── Local mode: Start llama-server ─────────────────────────────────────────

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

    local cmd="nohup bash ${LLAMA_SCRIPT}"
    if [[ -n "${MODEL_CHOICE:-}" ]]; then
        cmd="${cmd} ${MODEL_CHOICE}"
    fi
    cmd="${cmd} >/tmp/llama-server.log 2>&1 &"

    eval "${cmd}"
    local wrapper_pid=$!

    if ! wait_for_port "${LLAMA_PORT}" "llama-server" 60; then
        log_error "llama" "Failed to start llama-server"
        kill "${wrapper_pid}" 2>/dev/null || true
        return 1
    fi

    echo "${wrapper_pid}" > /tmp/llama-server.pid
    log_info "llama" "Started (wrapper PID: ${wrapper_pid})"
}

# ── Start opencodex proxy (shared) ─────────────────────────────────────────
# provider_name, provider_base_url, default_model, api_key are passed via env

start_opencodex_proxy() {
    local provider_name="${1:-llama-local}"
    local provider_base_url="${2:-http://localhost:${LLAMA_PORT}/v1}"
    local default_model="${3:-${MODEL}}"
    local api_key="${4:-}"
    local adapter="${5:-openai-chat}"

    if is_port_listening "${PROXY_PORT}"; then
        log_info "proxy" "Already running on port ${PROXY_PORT}"
        return 0
    fi

    log_info "proxy" "Starting opencodex proxy on port ${PROXY_PORT}..."

    mkdir -p "$(dirname "${OPENCODEX_CONFIG}")"
    cat > "${OPENCODEX_CONFIG}" <<OCXCFG_EOF
{
  "port": ${PROXY_PORT},
  "defaultProvider": "${provider_name}",
  "providers": {
    "${provider_name}": {
      "adapter": "${adapter}",
      "baseUrl": "${provider_base_url}",
      "authMode": "key",
      "apiKey": "${api_key}",
      "defaultModel": "${default_model}",
      "modelContextWindows": {
        "${default_model}": 65536
      }
    }
  }
}
OCXCFG_EOF

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
}

# ── Configure Codex for OpenRouter (via proxy) ─────────────────────────────

configure_codex_openrouter() {
    log_info "config" "Configuring Codex to use OpenRouter via proxy..."

    backup_config "${CODEX_CONFIG}" "config"

    cat > "${CODEX_CONFIG}" <<CODEXCFG_EOF
model = "openrouter/${OPENROUTER_MODEL}"
model_provider = "opencodex"

notify = ["${HOME}/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"]

[model_providers.opencodex]
name = "OpenCodex Proxy"
base_url = "http://localhost:${PROXY_PORT}/v1"
wire_api = "responses"
requires_openai_auth = true

[features]
js_repl = false
CODEXCFG_EOF

    log_info "config" "Syncing OpenRouter models via opencodex..."
    if ! ocx sync 2>&1; then
        log_warn "config" "ocx sync failed, models may not appear in Codex UI"
    fi

    if [[ -f "${HOME}/.codex/models_cache.json" ]]; then
        rm -f "${HOME}/.codex/models_cache.json"
        log_info "config" "Cleared stale model cache"
    fi

    log_info "config" "Codex configured for OpenRouter via proxy"
}

# ── Local mode: Configure Codex ────────────────────────────────────────────

configure_codex_local() {
    log_info "config" "Configuring Codex to use local model..."

    log_info "config" "Writing model catalog..."
    generate_catalog "${CATALOG}" "llama-local" "${MODEL}" 131072

    backup_config "${CODEX_CONFIG}" "config"

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

    if [[ -f "${HOME}/.codex/models_cache.json" ]]; then
        rm -f "${HOME}/.codex/models_cache.json"
        log_info "config" "Cleared stale model cache"
    fi

    log_info "config" "Codex configured successfully"
}

# ── Cleanup (foreground mode only) ─────────────────────────────────────────

cleanup() {
    log_info "cleanup" "Cleaning up..."

    if [[ -f /tmp/opencodex.pid ]]; then
        local proxy_pid
        proxy_pid=$(cat /tmp/opencodex.pid)
        if kill -0 "${proxy_pid}" 2>/dev/null; then
            kill_process "${proxy_pid}" "opencodex proxy"
        fi
        rm -f /tmp/opencodex.pid
    fi

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

if [[ "$MODE" == "openrouter" ]]; then
    # OpenRouter mode — start proxy pointing at OpenRouter API
    if ! start_opencodex_proxy \
        "openrouter" \
        "https://openrouter.ai/api/v1" \
        "${OPENROUTER_MODEL}" \
        "${OPENROUTER_API_KEY}"; then
        log_error "main" "Failed to start opencodex proxy"
        exit 1
    fi

    log_info "main" "Waiting for opencodex to finish setup..."
    sleep 3

    configure_codex_openrouter

    log_info "main" "Launching Codex Desktop..."
    log_info "main" "Provider: OpenRouter (via proxy)"
    log_info "main" "Model: ${OPENROUTER_MODEL}"
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
else
    # Local mode — start llama-server + proxy
    if ! start_llama_server; then
        log_error "main" "Failed to start llama-server"
        exit 1
    fi

    if ! start_opencodex_proxy \
        "llama-local" \
        "http://localhost:${LLAMA_PORT}/v1" \
        "${MODEL}" \
        "" \
        "openai-chat"; then
        log_error "main" "Failed to start opencodex proxy"
        exit 1
    fi

    log_info "main" "Waiting for opencodex to finish setup..."
    sleep 5

    configure_codex_local

    if ! grep -q '"models":' "${CATALOG}" 2>/dev/null || grep -q '"models":\s*\[\s*\]' "${CATALOG}" 2>/dev/null; then
        log_warn "main" "Catalog was overwritten by ocx sync, rewriting..."
        configure_codex_local
    fi

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
        log_info "main" "  To start fresh: ./run/teardown.sh && ./run/codex.sh --local"
    fi
fi

exit 0
