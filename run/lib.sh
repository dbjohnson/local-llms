#!/usr/bin/env bash
# lib.sh — Shared library for all local-llms run scripts.
#
# Source at the top of your script:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Logging API (all use tag-based format: log_<level> "tag" "message"):
#   log_info  "setup"  "Everything is ready ✓"
#   log_warn  "setup"  "PATH missing /opt/homebrew/bin"
#   log_error "setup"  "bun installation failed"
#   log_step  "setup"  "=== Step 1: llama.cpp ==="
#
# Provides: colors, logging, port helpers, model helpers,
#           disk checks, log rotation, catalog generation,
#           brew detection, process helpers, config helpers,
#           banner, bash version check.

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

# All logging functions use tag-based format.
log_info()  { echo -e "${GREEN}[$1]${NC} $2"; }
log_warn()  { echo -e "${YELLOW}[$1]${NC} $2"; }
log_error() { echo -e "${RED}[$1]${NC} $2" >&2; }
log_step()  { echo -e "${BLUE}[$1]${NC} $2"; }

# ── Bash version check ──────────────────────────────────────────────────────

# Ensures bash >= 4.3 (needed for associative arrays, etc.).
# Call this early in scripts that use bash-specific features.
check_bash_version() {
    local major="${BASH_VERSINFO[0]:-3}"
    local minor="${BASH_VERSINFO[1]:-2}"
    if (( major < 4 || (major == 4 && minor < 3) )); then
        log_error "bash" "Requires bash >= 4.3, found $BASH_VERSION."
        log_error "bash" "Install via: brew install bash"
        log_error "bash" "Then run this script with: /opt/homebrew/bin/bash <script>"
        exit 1
    fi
}

# ── Banner ──────────────────────────────────────────────────────────────────

print_banner() {
    local title="${1:-Local LLM}"
    local width=60
    local border
    border=$(printf '%*s' "$width" '' | tr ' ' '═')
    local padded
    padded=$(printf "%-${width}s" "  $title  " | tr ' ' '═')
    echo ""
    echo "╔${border}╗"
    echo "║${padded}║"
    echo "╚${border}╝"
    echo ""
}

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

    auto_compact=$(( context_window * 90 / 100 ))

    mkdir -p "$(dirname "$catalog_path")"

    cat > "${catalog_path}" <<CATALOG_EOF
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
CATALOG_EOF
}

# ── Log rotation ────────────────────────────────────────────────────────────

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
    local prefix
    prefix="$(brew --prefix 2>/dev/null)" || true
    echo "${prefix:-/opt/homebrew}"
}

# ── Process helpers ────────────────────────────────────────────────────────

# Find PID listening on a port. Returns empty string if none.
find_pid_by_port() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -t -i ":${port}" -sTCP:LISTEN 2>/dev/null || true
    elif command -v fuser >/dev/null 2>&1; then
        fuser "${port}/tcp" 2>/dev/null || true
    fi
}

# Kill a process gracefully (SIGTERM → SIGKILL after 5s).
kill_process() {
    local pid="$1"
    local name="$2"

    if ! kill -0 "$pid" 2>/dev/null; then
        log_info "$name" "Process (PID ${pid}) is not running, skipping."
        return 0
    fi

    log_info "$name" "Stopping ${name} (PID ${pid})..."
    kill "$pid" 2>/dev/null || true

    local attempt=0
    while kill -0 "$pid" 2>/dev/null && (( attempt < 5 )); do
        sleep 1
        (( attempt++ ))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "$name" "Did not stop gracefully, sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        log_info "$name" "Stopped."
    else
        log_error "$name" "Failed to stop (PID ${pid})."
    fi
}

# ── Config helpers ──────────────────────────────────────────────────────────

# Return the latest backup for a config file, or empty string.
latest_backup() {
    local config_path="$1"
    ls -t "${config_path}".backup.* 2>/dev/null | head -1 || true
}

# Restore a config file from its latest backup.
restore_config_file() {
    local config_path="$1"
    local label="$2"

    if [[ ! -f "$config_path" ]]; then
        log_info "$label" "Config not found at ${config_path}, skipping."
        return 0
    fi

    local backup
    backup=$(latest_backup "$config_path")

    if [[ -z "$backup" ]]; then
        log_warn "$label" "No backup found."
        return 0
    fi

    cp "$backup" "$config_path"
    log_info "$label" "Restored from ${backup}"
    rm -f "$backup"
}

# Create a timestamped backup of a config file. Uses nanoseconds to avoid collisions.
backup_config() {
    local config_path="$1"
    local label="$2"

    if [[ ! -f "$config_path" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$config_path")"
    cp "$config_path" "${config_path}.backup.$(date +%s%N)"
    log_info "$label" "Backed up config"
}
