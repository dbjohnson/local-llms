#!/usr/bin/env bash
# serve_model.sh — Unified model server launcher for local-llms.
#
# Usage:
#   ./run/serve_model.sh                  # Qwen3.6-35B-A3B (default)
#   ./run/serve_model.sh qwen3.6-27b      # Qwen3.6-27B with MTP
#   ./run/serve_model.sh deepseek-r1-32b  # DeepSeek-R1-Distill-Qwen-32B
#   ./run/serve_model.sh --help           # show usage
#
# Environment variables:
#   MODEL         HuggingFace model ID with quant tag (default depends on model choice)
#   PORT          Listen port (default: 8080)
#   CONTEXT       Context size (default: auto-adjusted)
#   MODEL_CHOICE  Model identifier (e.g. qwen3.6-27b) — overrides positional arg
#   CPU_ONLY      Set to "1" to force CPU-only mode (no GPU offloading)
#
# Context auto-adjusts: 32768 on ≤32GB, 65536 on ≥64GB.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# ── Model registry (Bash 3.2 compatible — no associative arrays) ──────────

model_default() {
  local quant="Q4_K_M"
  # On ≤32GB, the 35B-A3B Q4 weights alone (~20GB) leave almost no
  # headroom for the OS. Downgrade to Q3 to save ~4-5GB.
  if ((RAM_GB <= 32)); then
    quant="Q3_K_M"
  fi
  case "$1" in
  qwen3.6-35b-a3b) echo "unsloth/Qwen3.6-35B-A3B-GGUF:${quant}" ;;
  qwen3.6-27b) echo "unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M" ;;
  deepseek-r1-32b) echo "unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF:{quant}" ;;
  *) echo "" ;;
  esac
}

model_desc() {
  case "$1" in
  qwen3.6-35b-a3b) echo "Qwen3.6-35B-A3B (MoE)" ;;
  qwen3.6-27b) echo "Qwen3.6-27B with MTP speculative decoding" ;;
  deepseek-r1-32b) echo "DeepSeek-R1-Distill-Qwen-32B" ;;
  *) echo "" ;;
  esac
}

# ── Hardware auto-detection ────────────────────────────────────────────────

# Detect RAM in GB (works on both M1 and M4)
detect_ram_gb() {
  local mem_bytes
  mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
  echo $((mem_bytes / 1073741824))
}

# Detect if we have 64GB+ (enables --moe-load-all-experts for MoE models)
has_64gb_or_more() {
  local ram_gb
  ram_gb=$(detect_ram_gb)
  ((ram_gb >= 64))
}

# Detect if GPU offloading is possible (Metal on Apple Silicon)
can_gpu_offload() {
  [[ "${CPU_ONLY:-}" != "1" ]] && [[ -n "$(command -v llama-server 2>/dev/null)" ]]
}

# ── Resolve model choice ───────────────────────────────────────────────────

# Check for flags before consuming positional arg
FOREGROUND=false
for arg in "$@"; do
  case "$arg" in
  --help | -h)
    echo "Usage: $0 [MODEL] [OPTIONS]"
    echo ""
    echo "Launch a local LLM via llama-server."
    echo ""
    echo "Models:"
    echo "  qwen3.6-35b-a3b   Qwen3.6-35B-A3B (MoE) [default]"
    echo "  qwen3.6-27b       Qwen3.6-27B with MTP speculative decoding"
    echo "  deepseek-r1-32b   DeepSeek-R1-Distill-Qwen-32B"
    echo ""
    echo "Options:"
    echo "  --foreground   Run in the foreground (don't background)"
    echo "  --help         Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  MODEL          HuggingFace model ID (e.g. org/model:quant)"
    echo "  PORT           Listen port (default: 8080)"
    echo "  CONTEXT        Context size (default: auto)"
    echo "  MODEL_CHOICE   Model identifier (e.g. qwen3.6-27b)"
    echo "  CPU_ONLY       Set to 1 for CPU-only mode (no GPU offloading)"
    echo ""
    echo "Examples:"
    echo "  $0                                          # 35B-A3B (default)"
    echo "  $0 qwen3.6-27b                              # 27B with MTP"
    echo "  $0 deepseek-r1-32b                          # DeepSeek-R1-Distill-Qwen-32B"
    echo "  $0 --foreground                             # debug mode"
    echo "  MODEL=my-org/my-model:Q5_K_M $0             # custom model"
    echo "  PORT=9090 CONTEXT=32768 $0 qwen3.6-27b     # custom port/context"
    echo "  MODEL_CHOICE=qwen3.6-27b $0                 # env var override"
    echo "  CPU_ONLY=1 $0                               # CPU-only mode"
    exit 0
    ;;
  --foreground | -f)
    FOREGROUND=true
    ;;
  --*)
    log_error "serve_model" "Unknown option: $arg"
    echo "Use --help for usage." >&2
    exit 1
    ;;
  esac
done

# Detect RAM early so defaults can be hardware-aware
RAM_GB=$(detect_ram_gb)

# Priority: positional arg > MODEL_CHOICE env var > default (qwen3.6-35b-a3b)
# Skip over flags to find the model name
_MODEL_CHOICE=""
for arg in "$@"; do
  case "$arg" in
  --* | -*) ;; # skip flags
  *)
    if [[ -z "$_MODEL_CHOICE" ]]; then
      _MODEL_CHOICE="$arg"
    fi
    ;;
  esac
done

if [[ -n "$_MODEL_CHOICE" ]]; then
  MODEL_CHOICE="$_MODEL_CHOICE"
else
  # Auto-downgrade default model on memory-constrained systems.
  # 35B-A3B Q4 weights alone are ~20GB; on 32GB that leaves almost no
  # headroom for the OS. Default to 27B instead.
  if [[ -z "${MODEL_CHOICE:-}" ]]; then
    MODEL_CHOICE="qwen3.6-35b-a3b"
  fi
fi

if [[ -z "$(model_default "$MODEL_CHOICE")" ]]; then
  log_error "serve_model" "Unknown model: ${MODEL_CHOICE}"
  echo "Available models: qwen3.6-35b-a3b qwen3.6-27b deepseek-r1-32b" >&2
  echo "Use --help for usage." >&2
  exit 1
fi

MODEL="${MODEL:-$(model_default "$MODEL_CHOICE")}"
PORT="${PORT:-8080}"
CONTEXT_SIZE="${CONTEXT:-65536}"
PID_FILE="/tmp/llama-server.pid"
LOG_FILE="/tmp/llama-server.log"
DESC="$(model_desc "$MODEL_CHOICE")"

# ── Validate ───────────────────────────────────────────────────────────────

validate_port "$PORT" || exit 1
validate_model "$MODEL"

# ── Check llama-server binary ──────────────────────────────────────────────

if ! can_gpu_offload; then
  if [[ "${CPU_ONLY:-}" == "1" ]]; then
    log_warn "serve_model" "CPU-only mode requested. Running without GPU offloading."
  else
    log_error "serve_model" "llama-server not found."
    log_error "serve_model" "Run setup/llama-cpp.sh or ./setup.sh first."
    exit 1
  fi
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

# ── Determine hardware-aware configuration ─────────────────────────────────

GPU_OFFLOAD="true"
MTP_DRAFT_N_MAX=2

if can_gpu_offload; then
  GPU_OFFLOAD="true"
else
  GPU_OFFLOAD="false"
fi

# Adaptive context size based on available RAM
# KV cache is O(context × model_dim). On 32GB, 32K context consumes
# ~4-6GB alone and leaves little room for system processes. Cap to 16K.
if ((RAM_GB >= 64)); then
  CONTEXT_SIZE=65536
elif ((RAM_GB >= 48)); then
  CONTEXT_SIZE=32768
else
  CONTEXT_SIZE=16384
fi

# MTP model: use more aggressive draft length on 64GB+ (more headroom for draft model)
if [[ "$MODEL_CHOICE" == "qwen3.6-27b" ]]; then
  if has_64gb_or_more && [[ "$GPU_OFFLOAD" == "true" ]]; then
    MTP_DRAFT_N_MAX=4
  fi
fi

# ── Main ───────────────────────────────────────────────────────────────────

log_info "serve_model" "Starting ${DESC}..."
log_info "serve_model" "Model: ${MODEL}"
log_info "serve_model" "Port: ${PORT}"
log_info "serve_model" "Context: ${CONTEXT_SIZE}"
log_info "serve_model" "Hardware: ${RAM_GB}GB RAM, GPU offload=${GPU_OFFLOAD}"

if [[ "$MTP_DRAFT_N_MAX" -gt 2 ]]; then
  log_info "serve_model" "MTP: using aggressive draft (n=${MTP_DRAFT_N_MAX} for 64GB+)"
fi

if [[ "$CONTEXT_SIZE" -lt 65536 ]]; then
  log_info "serve_model" "Context capped to ${CONTEXT_SIZE} for ${RAM_GB}GB RAM"
fi

rotate_log "${LOG_FILE}" 10240

CMD=(llama-server
  -hf "${MODEL}"
  -c "${CONTEXT_SIZE}"
  --port "${PORT}")

# GPU offloading: 'all' = offload as many layers as memory allows
# (replaces the old -ngl 999 hack)
if [[ "$GPU_OFFLOAD" == "true" ]]; then
  CMD+=(--gpu-layers all)
fi

# Threading: -t 0 auto-detects (uses all physical cores — P-cores + E-cores)
# E-cores help with batch processing and prompt encoding throughput.
CMD+=(-t 0)

# MoE expert weights: keep in RAM to free GPU memory for KV cache.
# On M1 Max 32GB this is essential (~17GB saved); on M4 Max 64GB
# it still frees substantial GPU memory for context handling.
if [[ "$GPU_OFFLOAD" == "true" ]]; then
  # The 35B-A3B has 35B total params but only 3B active per token.
  # Without --cpu-moe, all expert weights sit idle in GPU memory.
  if [[ "$MODEL_CHOICE" == "qwen3.6-35b-a3b" ]]; then
    CMD+=(--cpu-moe)
  fi

  # Lock model in RAM: prevent macOS from swapping/compressing.
  # Only enable on 64GB+; on 32GB let the OS compress/page unused
  # weights instead of pinning the entire model resident.
  if ((RAM_GB >= 64)); then
    CMD+=(--mlock)
  fi
fi

# High process priority: prevents macOS from deprioritizing this server
# during background tasks (Xcode indexing, Spotlight, etc.).
# Reduces token delivery latency spikes.
CMD+=(--prio 2)

# Poll tuning: balance between CPU usage and token latency.
# 75 = more responsive (64GB has headroom), 50 = less CPU pressure (32GB).
if ((RAM_GB >= 64)); then
  CMD+=(--poll 75)
else
  CMD+=(--poll 50)
fi

# MTP speculative decoding
if [[ "$MODEL_CHOICE" == "qwen3.6-27b" ]]; then
  CMD+=(--spec-type draft-mtp
    --spec-draft-n-max "${MTP_DRAFT_N_MAX}"
    --spec-penalty 0.5)
fi

# Reduce logging overhead during inference
CMD+=(--log-disable)

if [[ "$FOREGROUND" == "true" ]]; then
  log_info "serve_model" "Running in foreground..."
  exec "${CMD[@]}"
else
  log_info "serve_model" "Running in background."
  log_info "serve_model" "Log: ${LOG_FILE}"
  log_info "serve_model" "Stop: ./run/teardown.sh"
  nohup "${CMD[@]}" >"${LOG_FILE}" 2>&1 &
  local_pid=$!
  echo "${local_pid}" >"${PID_FILE}"
  log_info "serve_model" "Started (PID ${local_pid}) → ${PID_FILE}"
fi
