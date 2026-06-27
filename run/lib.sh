#!/usr/bin/env bash
# lib.sh — Shared library for all local-llms run scripts
# Source this file at the top of your script:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#
# Provides:
#   - TTY-aware colors (graceful in pipes/redirects)
#   - Logging functions (log_info, log_warn, log_error, log_step)
#   - Validation helpers (validate_port, validate_model, check_disk_space)
#   - Catalog generation (generate_catalog)
#   - Log rotation (rotate_log)
#   - Port helpers (is_port_listening, wait_for_port)
#   - Brew prefix detection (get_brew_prefix)

# ── TTY detection ──────────────────────────────────────────────────────────

if [ -t 1 ]; then
    USE_COLORS=true
else
    USE_COLORS=false
fi

# ── Colors ──────────────────────────────────────────────────────────────────

if [[ "$USE_COLORS" == "true" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
fi

# ── Logging ─────────────────────────────────────────────────────────────────

log_info()  { echo -e "${GREEN}[$1]${NC} $2"; }
log_warn()  { echo -e "${YELLOW}[$1]${NC} $2"; }
log_error() { echo -e "${RED}[$1]${NC} $2" >&2; }
log_step()  { echo -e "${BLUE}[$1]${NC} $2"; }

# ── Validation ──────────────────────────────────────────────────────────────

# Validate a port number (1-65535)
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "validate" "Invalid port number: ${port} (must be 1-65535)"
        return 1
    fi
    return 0
}

# Basic validation of a HuggingFace model ID format
validate_model() {
    local model="$1"
    if [[ ! "$model" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*:[a-zA-Z0-9._-]+$ ]]; then
        log_error "validate" "Unusual model ID format: ${model}"
        log_warn "validate" "Expected format: <org>/<model-name>:<quant-tag>"
        # Warn but don't fail — some valid IDs may not match this regex
    fi
}

# Check available disk space (in MB). Returns 0 if sufficient, 1 if not.
# Usage: check_disk_space /path/to/dir required_mb [warn_msg]
check_disk_space() {
    local dir="$1"
    local required_mb="$2"
    local label="${3:-directory}"

    if [[ ! -d "$dir" ]]; then
        log_error "disk" "${label} does not exist: ${dir}"
        return 1
    fi

    local available_mb
    available_mb=$(df -m "$dir" | awk 'NR==2 {print $4}')

    if (( available_mb < required_mb )); then
        log_error "disk" "Insufficient disk space on ${label}: ${available_mb}MB available, ${required_mb}MB required"
        return 1
    fi

    log_info "disk" "${available_mb}MB available on ${label} ✓"
    return 0
}

# ── Catalog generation ──────────────────────────────────────────────────────

# Generates the Codex Desktop model catalog JSON.
# Usage: generate_catalog <output_path> <model_id> [context_window]
generate_catalog() {
    local catalog_path="$1"
    local model="$2"
    local context_window="${3:-131072}"
    local auto_compact

    # Calculate auto_compact as ~90% of context window
    auto_compact=$(( context_window * 90 / 100 ))

    mkdir -p "$(dirname "$catalog_path")"

    cat > "${catalog_path}" <<EOF
{
  "fetched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "client_version": "26.623.31921",
  "models": [
    {
      "slug": "llama-local/${model}",
      "display_name": "llama-local/${model}",
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
      "context_window": ${context_window},
      "max_context_window": ${context_window},
      "auto_compact_token_limit": ${auto_compact},
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
}

# ── Log rotation ────────────────────────────────────────────────────────────

# Rotate a log file if it exceeds max_size_kb (default 10MB).
# Usage: rotate_log <log_path> [max_size_kb]
rotate_log() {
    local log_file="$1"
    local max_size_kb="${2:-10240}"

    if [[ ! -f "$log_file" ]]; then
        return 0
    fi

    local size_kb
    size_kb=$(du -k "$log_file" | awk '{print $1}')

    if (( size_kb > max_size_kb )); then
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        mv "${log_file}" "${log_file}.${timestamp}.bak"
        log_info "log" "Rotated ${log_file} (${size_kb}KB → ${log_file}.${timestamp}.bak)"
    fi
}

# ── Port helpers ────────────────────────────────────────────────────────────

is_port_listening() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1
        return $?
    elif command -v nc >/dev/null 2>&1; then
        nc -z localhost "${port}" >/dev/null 2>&1
        return $?
    else
        curl -sf "http://localhost:${port}/health" >/dev/null 2>&1 || \
        curl -sf "http://localhost:${port}/healthz" >/dev/null 2>&1
        return $?
    fi
}

wait_for_port() {
    local port="$1"
    local name="$2"
    local max_attempts="${3:-30}"

    log_info "${name}" "Waiting for ${name} on port ${port}..."
    for i in $(seq 1 "${max_attempts}"); do
        if is_port_listening "${port}"; then
            log_info "${name}" "${name} is ready on port ${port}"
            return 0
        fi
        sleep 1
    done

    log_error "${name}" "${name} failed to start on port ${port}"
    return 1
}

# ── Brew prefix detection ──────────────────────────────────────────────────

get_brew_prefix() {
    # Returns /opt/homebrew on Apple Silicon, /usr/local on Intel, or empty
    local prefix
    prefix="$(brew --prefix 2>/dev/null)" || true
    echo "${prefix:-/opt/homebrew}"
}
