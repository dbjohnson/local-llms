#!/usr/bin/env bash
# Run Qwen3.6-27B with MTP speculative decoding.
# Optimized for Apple Silicon (MacBook Pro M4).
#
# Usage:
#   ./run/qwen3.6-27b.sh                 # background (default)
#   ./run/qwen3.6-27b.sh --foreground    # run in place for debugging
#   ./run/qwen3.6-27b.sh --help          # show usage
#
# Environment variables:
#   MODEL       HuggingFace model ID with quant tag (default: Q4_K_M)
#   PORT        Listen port (default: 8080)
#   CONTEXT     Context size (default: 65536)

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MODEL="${MODEL:-unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M}"
PORT="${PORT:-8080}"
CONTEXT_SIZE="${CONTEXT:-65536}"
PID_FILE="/tmp/qwen3.6-27b.pid"
LOG_FILE="/tmp/qwen3.6-27b.log"

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
            log_error "qwen3.6-27b" "Unknown option: $arg"
            echo "Use --help for usage." >&2
            exit 1
            ;;
    esac
done

if [[ "$ACTION_HELP" == "true" ]]; then
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Run Qwen3.6-27B with MTP speculative decoding via llama-server."
    echo ""
    echo "Options:"
    echo "  --foreground   Run in the foreground (don't background)"
    echo "  --help         Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  MODEL          HuggingFace model ID:Q4_K_M (default: unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M)"
    echo "  PORT           Listen port (default: 8080)"
    echo "  CONTEXT        Context size (default: 65536)"
    echo ""
    echo "Examples:"
    echo "  $0                                          # background"
    echo "  $0 --foreground                             # debug"
    echo "  PORT=9090 CONTEXT=32768 $0                 # custom port/context"
    exit 0
fi

# ── Validate ───────────────────────────────────────────────────────────────

validate_port "$PORT" || exit 1
validate_model "$MODEL"

# ── Check llama-server binary ──────────────────────────────────────────────

if ! command -v llama-server >/dev/null 2>&1; then
    log_error "qwen3.6-27b" "llama-server not found."
    log_error "qwen3.6-27b" "Run setup/llama-cpp.sh or ./setup.sh first."
    exit 1
fi

# Note: llama-server --help triggers Metal init which is slow.
# Using grep without -q to avoid SIGPIPE under set -o pipefail.
if ! llama-server --help 2>&1 | grep -- '--spec-type' >/dev/null; then
    log_error "qwen3.6-27b" "Your llama-server binary does not support --spec-type."
    log_error "qwen3.6-27b" "MTP speculative decoding requires a recent build of llama.cpp (>= b9196)."
    log_error "qwen3.6-27b" "Run the setup script to build from source: ./setup/llama-cpp.sh"
    exit 1
fi

# ── Main ───────────────────────────────────────────────────────────────────

log_info "qwen3.6-27b" "Starting Qwen3.6-27B with MTP speculative decoding..."
log_info "qwen3.6-27b" "Model: ${MODEL}"
log_info "qwen3.6-27b" "Port: ${PORT}"
log_info "qwen3.6-27b" "Context: ${CONTEXT_SIZE}"

rotate_log "${LOG_FILE}" 10240

CMD=(llama-server \
    -hf "${MODEL}" \
    --spec-type draft-mtp \
    --spec-draft-n-max 2 \
    -c "${CONTEXT_SIZE}" \
    --port "${PORT}")

if [[ "$FOREGROUND" == "true" ]]; then
    log_info "qwen3.6-27b" "Running in foreground..."
    exec "${CMD[@]}"
else
    log_info "qwen3.6-27b" "Running in background."
    log_info "qwen3.6-27b" "Log: ${LOG_FILE}"
    log_info "qwen3.6-27b" "Stop: ./run/teardown.sh"
    nohup "${CMD[@]}" >"${LOG_FILE}" 2>&1 &
    local_pid=$!
    echo "${local_pid}" > "${PID_FILE}"
    log_info "qwen3.6-27b" "Started (PID ${local_pid}) → ${PID_FILE}"
fi
