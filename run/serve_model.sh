#!/usr/bin/env bash
# serve_model.sh — Unified model server launcher for local-llms.
#
# Usage:
#   ./run/serve_model.sh                  # Qwen3.6-35B-A3B (default)
#   ./run/serve_model.sh qwen3.6-27b      # Qwen3.6-27B with MTP
#   ./run/serve_model.sh --help           # show usage
#
# Environment variables:
#   MODEL         HuggingFace model ID with quant tag (default depends on model choice)
#   PORT          Listen port (default: 8080)
#   CONTEXT       Context size (default: 65536)
#   MODEL_CHOICE  Model identifier (e.g. qwen3.6-27b) — overrides positional arg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# ── Model registry (Bash 3.2 compatible — no associative arrays) ──────────

model_default() {
    case "$1" in
        qwen3.6-35b-a3b) echo "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M" ;;
        qwen3.6-27b)     echo "unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M" ;;
        *)               echo "" ;;
    esac
}

model_pid() {
    case "$1" in
        qwen3.6-35b-a3b) echo "/tmp/qwen3.6-35b-a3b.pid" ;;
        qwen3.6-27b)     echo "/tmp/qwen3.6-27b.pid" ;;
        *)               echo "" ;;
    esac
}

model_log() {
    case "$1" in
        qwen3.6-35b-a3b) echo "/tmp/qwen3.6-35b-a3b.log" ;;
        qwen3.6-27b)     echo "/tmp/qwen3.6-27b.log" ;;
        *)               echo "" ;;
    esac
}

model_desc() {
    case "$1" in
        qwen3.6-35b-a3b) echo "Qwen3.6-35B-A3B (MoE)" ;;
        qwen3.6-27b)     echo "Qwen3.6-27B with MTP speculative decoding" ;;
        *)               echo "" ;;
    esac
}

# ── Resolve model choice ───────────────────────────────────────────────────

# Priority: positional arg > MODEL_CHOICE env var > default (qwen3.6-35b-a3b)
_MODEL_CHOICE="${1:-}"
shift 2>/dev/null || true

if [[ -n "$_MODEL_CHOICE" ]]; then
    MODEL_CHOICE="$_MODEL_CHOICE"
else
    MODEL_CHOICE="${MODEL_CHOICE:-qwen3.6-35b-a3b}"
fi

if [[ -z "$(model_default "$MODEL_CHOICE")" ]]; then
    log_error "serve_model" "Unknown model: ${MODEL_CHOICE}"
    echo "Available models: qwen3.6-35b-a3b qwen3.6-27b" >&2
    echo "Use --help for usage." >&2
    exit 1
fi

MODEL="${MODEL:-$(model_default "$MODEL_CHOICE")}"
PORT="${PORT:-8080}"
CONTEXT_SIZE="${CONTEXT:-65536}"
PID_FILE="$(model_pid "$MODEL_CHOICE")"
LOG_FILE="$(model_log "$MODEL_CHOICE")"
DESC="$(model_desc "$MODEL_CHOICE")"

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
            log_error "serve_model" "Unknown option: $arg"
            echo "Use --help for usage." >&2
            exit 1
            ;;
    esac
done

if [[ "$ACTION_HELP" == "true" ]]; then
    echo "Usage: $0 [MODEL] [OPTIONS]"
    echo ""
    echo "Launch a local LLM via llama-server."
    echo ""
    echo "Models:"
    echo "  qwen3.6-35b-a3b   Qwen3.6-35B-A3B (MoE) [default]"
    echo "  qwen3.6-27b       Qwen3.6-27B with MTP speculative decoding"
    echo ""
    echo "Options:"
    echo "  --foreground   Run in the foreground (don't background)"
    echo "  --help         Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  MODEL          HuggingFace model ID (e.g. org/model:quant)"
    echo "  PORT           Listen port (default: 8080)"
    echo "  CONTEXT        Context size (default: 65536)"
    echo "  MODEL_CHOICE   Model identifier (e.g. qwen3.6-27b)"
    echo ""
    echo "Examples:"
    echo "  $0                                          # 35B-A3B (default)"
    echo "  $0 qwen3.6-27b                              # 27B with MTP"
    echo "  $0 --foreground                             # debug mode"
    echo "  MODEL=my-org/my-model:Q5_K_M $0             # custom model"
    echo "  PORT=9090 CONTEXT=32768 $0 qwen3.6-27b     # custom port/context"
    echo "  MODEL_CHOICE=qwen3.6-27b $0                 # env var override"
    exit 0
fi

# ── Validate ───────────────────────────────────────────────────────────────

validate_port "$PORT" || exit 1
validate_model "$MODEL"

# ── Check llama-server binary ──────────────────────────────────────────────

if ! command -v llama-server >/dev/null 2>&1; then
    log_error "serve_model" "llama-server not found."
    log_error "serve_model" "Run setup/llama-cpp.sh or ./setup.sh first."
    exit 1
fi

# ── MTP check (only needed for 27b) ────────────────────────────────────────

if [[ "$MODEL_CHOICE" == "qwen3.6-27b" ]]; then
    if ! llama-server --help 2>&1 | grep -- '--spec-type' >/dev/null; then
        log_error "serve_model" "Your llama-server binary does not support --spec-type."
        log_error "serve_model" "MTP speculative decoding requires a recent build of llama.cpp (>= b9196)."
        log_error "serve_model" "Run the setup script to build from source: ./setup/llama-cpp.sh"
        exit 1
    fi
fi

# ── Main ───────────────────────────────────────────────────────────────────

log_info "serve_model" "Starting ${DESC}..."
log_info "serve_model" "Model: ${MODEL}"
log_info "serve_model" "Port: ${PORT}"
log_info "serve_model" "Context: ${CONTEXT_SIZE}"

rotate_log "${LOG_FILE}" 10240

CMD=(llama-server \
    -hf "${MODEL}" \
    -c "${CONTEXT_SIZE}" \
    --port "${PORT}")

if [[ "$MODEL_CHOICE" == "qwen3.6-27b" ]]; then
    CMD+=(--spec-type draft-mtp --spec-draft-n-max 2)
fi

if [[ "$FOREGROUND" == "true" ]]; then
    log_info "serve_model" "Running in foreground..."
    exec "${CMD[@]}"
else
    log_info "serve_model" "Running in background."
    log_info "serve_model" "Log: ${LOG_FILE}"
    log_info "serve_model" "Stop: ./run/teardown.sh"
    nohup "${CMD[@]}" >"${LOG_FILE}" 2>&1 &
    local_pid=$!
    echo "${local_pid}" > "${PID_FILE}"
    log_info "serve_model" "Started (PID ${local_pid}) → ${PID_FILE}"
fi
