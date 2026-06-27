#!/usr/bin/env bash
# Configure opencode to use llama-server as a local OpenAI-compatible provider.
#
# Usage:
#   ./run/opencode.sh                      # configure opencode (don't start llama)
#   ./run/opencode.sh --start              # start llama-server + configure opencode
#   ./run/opencode.sh --foreground         # run llama in foreground (for debugging)
#   ./run/opencode.sh --restore            # remove local provider from opencode config
#   ./run/opencode.sh --help               # show usage
#
# Environment variables:
#   MODEL        HuggingFace model ID (default: Qwen3.6-27B)
#   LLAMA_SCRIPT Path to model server script (default: qwen3.6-27b.sh)
#   LLAMA_PORT   llama-server port (default: 8080)

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENCODE_CONFIG="${HOME}/.config/opencode/opencode.jsonc"
LLAMA_PORT="${LLAMA_PORT:-8080}"
MODEL="${MODEL:-unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M}"
LLAMA_SCRIPT="${LLAMA_SCRIPT:-${SCRIPT_DIR}/qwen3.6-27b.sh}"

# ── Parse arguments ────────────────────────────────────────────────────────

ACTION_CONFIG=true
ACTION_START=false
ACTION_FOREGROUND=false
ACTION_RESTORE=false
ACTION_HELP=false

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
            ACTION_HELP=true
            ;;
        *)
            log_error "opencode" "Unknown option: $arg"
            echo "Use --help for usage." >&2
            exit 1
            ;;
    esac
done

if [[ "$ACTION_HELP" == "true" ]]; then
    echo "Usage: $0 [OPTIONS]"
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
    echo ""
    echo "Environment variables:"
    echo "  MODEL          HuggingFace model ID (default: unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M)"
    echo "  LLAMA_SCRIPT   Model server script (default: ./run/qwen3.6-27b.sh)"
    echo "  LLAMA_PORT     llama-server port (default: 8080)"
    exit 0
fi

# ── Validate ───────────────────────────────────────────────────────────────

validate_port "$LLAMA_PORT" || exit 1
validate_model "$MODEL"

# ── Start llama-server ─────────────────────────────────────────────────────

start_llama_server() {
    if is_port_listening "${LLAMA_PORT}"; then
        log_info "llama" "Already running on port ${LLAMA_PORT}"
        return 0
    fi

    if [[ ! -f "${LLAMA_SCRIPT}" ]]; then
        log_error "llama" "Model script not found: ${LLAMA_SCRIPT}"
        return 1
    fi

    if [[ "$ACTION_FOREGROUND" == "true" ]]; then
        log_info "llama" "Starting llama-server in foreground..."
        PORT="${LLAMA_PORT}" bash "${LLAMA_SCRIPT}" --foreground
        return 0
    fi

    log_info "llama" "Starting llama-server on port ${LLAMA_PORT}..."
    PORT="${LLAMA_PORT}" nohup bash "${LLAMA_SCRIPT}" >/tmp/llama-server-opencode.log 2>&1 &
    local llama_pid=$!

    if ! wait_for_port "${LLAMA_PORT}" "llama-server" 60; then
        log_error "llama" "Failed to start llama-server"
        kill "${llama_pid}" 2>/dev/null || true
        return 1
    fi

    echo "${llama_pid}" > /tmp/llama-server-opencode.pid
    log_info "llama" "Started (PID: ${llama_pid})"
}

# ── Configure opencode ─────────────────────────────────────────────────────

configure_opencode() {
    log_info "config" "Configuring opencode..."

    mkdir -p "$(dirname "${OPENCODE_CONFIG}")"

    if [[ ! -f "${OPENCODE_CONFIG}" ]]; then
        echo '{"$schema":"https://opencode.ai/config.json"}' > "${OPENCODE_CONFIG}"
        log_info "config" "Created ${OPENCODE_CONFIG}"
    fi

    backup_config "${OPENCODE_CONFIG}" "opencode"

    # Use jq if available, otherwise fall back to python3.
    # jq is preferred for robust JSON manipulation.
    if command -v jq >/dev/null 2>&1; then
        log_info "config" "Using jq for JSON manipulation"
        local tmp_json
        tmp_json=$(mktemp)
        jq \
            --arg port "${LLAMA_PORT}" \
            --arg model "${MODEL}" \
            '.provider["llama-local"] = {
                "api": "openai",
                "name": "Llama.cpp (local)",
                "options": {
                    "baseURL": ("http://localhost:" + $port + "/v1"),
                    "apiKey": "",
                    "timeout": null
                },
                "models": {
                    $model: {
                        "id": $model,
                        "name": "Qwen3.6-27B (local)",
                        "family": "qwen",
                        "attachment": false,
                        "reasoning": false,
                        "temperature": true,
                        "tool_call": true,
                        "interleaved": true,
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
            }' "${OPENCODE_CONFIG}" > "${tmp_json}" && \
            mv "${tmp_json}" "${OPENCODE_CONFIG}"
    else
        log_info "config" "Using python3 for JSON manipulation (jq not found)"
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
        "timeout": None
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
    fi

    log_info "opencode" "Configured with llama-local provider"
    log_info "opencode" "  Model: llama-local/${MODEL}"
    log_info "opencode" "  Base URL: http://localhost:${LLAMA_PORT}/v1"
}

# ── Restore (remove local provider) ────────────────────────────────────────

restore_opencode() {
    log_info "config" "Restoring opencode config..."

    local backup
    backup=$(latest_backup "${OPENCODE_CONFIG}")

    if [[ -n "$backup" ]]; then
        cp "$backup" "${OPENCODE_CONFIG}"
        rm -f "$backup"
        log_info "config" "Restored config from ${backup}"
    else
        if [[ -f "${OPENCODE_CONFIG}" ]]; then
            # Use jq if available, else python3
            if command -v jq >/dev/null 2>&1; then
                local tmp_json
                tmp_json=$(mktemp)
                jq 'del(.provider["llama-local"]) | (if (.provider | length) == 0 then del(.provider) else . end)' \
                    "${OPENCODE_CONFIG}" > "${tmp_json}" && \
                    mv "${tmp_json}" "${OPENCODE_CONFIG}"
            else
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
            fi
            log_info "config" "Removed llama-local provider from config"
        fi
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

print_banner "opencode + Local LLM Configuration"

if [[ "$ACTION_RESTORE" == "true" ]]; then
    restore_opencode
    echo ""
    log_info "main" "Restore complete. opencode is back to its previous state."
    exit 0
fi

if [[ "$ACTION_START" == "true" ]]; then
    start_llama_server
    echo ""
fi

configure_opencode

echo ""
log_info "main" "╔══════════════════════════════════════════════════════════════╗"
log_info "main" "║   opencode is configured!                                   ║"
log_info "main" "╚══════════════════════════════════════════════════════════════╝"
echo ""
log_info "main" "Launch opencode with the local model:"
log_info "main" "  opencode -m llama-local/${MODEL}"
echo ""
log_info "main" "Or set it as default in ${OPENCODE_CONFIG}:"
log_info "main" "  \"model\": \"llama-local/${MODEL}\""
echo ""
log_info "main" "To stop llama-server:"
log_info "main" "  ./run/teardown.sh"
echo ""
