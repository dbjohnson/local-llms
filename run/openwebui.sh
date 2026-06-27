#!/bin/bash

# Run Open WebUI native (Python) with llama.cpp
#
# Usage:
#   ./run/openwebui.sh                     # background (default)
#   ./run/openwebui.sh --foreground        # run in place for debugging
#   ./run/openwebui.sh --stop              # stop the running server
#   ./run/openwebui.sh --help              # show usage
#
# Environment variables:
#   LLAMA_PORT   llama.cpp URL (default: http://localhost:8080)
#   PORT         Open WebUI listen port (default: 8081)
#   PROJECT_DIR  Project directory name (default: open-webui-native)
#   PYTHON_VER   Python version (default: 3.11)
#
# PID file: /tmp/open-webui.pid

set -e

PORT="${PORT:-8081}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_URL="http://localhost:${LLAMA_PORT}"
PROJECT_DIR="${PROJECT_DIR:-open-webui-native}"
PYTHON_VERSION="${PYTHON_VER:-3.11}"
PID_FILE="/tmp/open-webui.pid"
VENV_DIR="${PROJECT_DIR}/venv"

# ── Parse arguments ─────────────────────────────────────────────────────────
ACTION_START=true
ACTION_STOP=false
FOREGROUND=false

for arg in "$@"; do
  case "$arg" in
    --stop)
      ACTION_START=false
      ACTION_STOP=true
      ;;
    --foreground|-f)
      FOREGROUND=true
      ;;
    --help|-h)
      echo "Usage: ./run/openwebui.sh [OPTIONS]"
      echo ""
      echo "Run Open WebUI native (Python) connected to a llama.cpp server."
      echo ""
      echo "Options:"
      echo "  --stop         Stop the running Open WebUI server"
      echo "  --foreground   Run in the foreground (for debugging)"
      echo "  --help         Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  LLAMA_PORT     llama.cpp server port (default: 8080)"
      echo "  PORT           Open WebUI listen port (default: 8081)"
      echo "  PROJECT_DIR    Project directory (default: open-webui-native)"
      echo "  PYTHON_VER     Python version (default: 3.11)"
      echo ""
      echo "Examples:"
      echo "  ./run/openwebui.sh"
      echo "  ./run/openwebui.sh --foreground"
      echo "  LLAMA_PORT=1234 ./run/openwebui.sh"
      echo ""
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

echo "=========================================="
echo "  Open WebUI + llama.cpp Setup Script"
echo "=========================================="

# ── Stop ────────────────────────────────────────────────────────────────────

if [[ "$ACTION_STOP" == "true" ]]; then
  echo ""
  echo "Stopping Open WebUI..."
  if [[ -f "$PID_FILE" ]]; then
    _pid=$(cat "$PID_FILE")
    if kill -0 "$_pid" 2>/dev/null; then
      echo "Killing PID $_pid..."
      kill "$_pid" 2>/dev/null || true
      sleep 1
      if ! kill -0 "$_pid" 2>/dev/null; then
        echo "Open WebUI stopped."
      else
        echo "Failed to stop. Sending SIGKILL..."
        kill -9 "$_pid" 2>/dev/null || true
        echo "Open WebUI killed."
      fi
    else
      echo "Process (PID $_pid) is not running."
    fi
  else
    echo "No PID file found at $PID_FILE."
  fi
  rm -f "$PID_FILE"
  exit 0
fi

# ── Install Homebrew & Python ──────────────────────────────────────────────

echo ""
echo "Checking Homebrew and Python..."

if ! command -v brew &>/dev/null; then
  echo "Homebrew not found. Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

if ! python3.11 --version &>/dev/null; then
  echo "Installing Python ${PYTHON_VERSION}..."
  brew install python@${PYTHON_VERSION}
else
  echo "Python ${PYTHON_VERSION} is installed."
fi

# ── Setup Virtual Environment ──────────────────────────────────────────────

echo "Setting up Virtual Environment..."
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

if [ ! -d "$VENV_DIR" ]; then
  python3.11 -m venv "$VENV_DIR"
  echo "Virtual environment created."
else
  echo "Virtual environment already exists."
fi

source "$VENV_DIR/bin/activate"

# ── Install Dependencies ──────────────────────────────────────────────────

echo "Installing Open WebUI..."
pip install --upgrade pip
pip install open-webui

# ── Start Open WebUI ──────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "  Starting Open WebUI..."
echo "=========================================="
echo "Connecting to llama.cpp at: $LLAMA_URL"
echo "Open WebUI will be available at: http://localhost:${PORT}"
echo "Default Login: admin / changeme"
echo ""
echo "Ensure your llama.cpp server is running on port $LLAMA_PORT before chatting."
echo ""

if [[ "${FOREGROUND:-false}" == "true" ]]; then
  echo "Running in foreground (Ctrl+C to stop)..."
  open-webui serve --port "$PORT" 2>&1
else
  echo "Running in background..."
  nohup open-webui serve --port "$PORT" >/tmp/open-webui.log 2>&1 &
  echo $! > "$PID_FILE"
  echo "Started Open WebUI (PID $!)"
  echo "PID file: $PID_FILE"
  echo ""
  echo "To stop: ./run/openwebui.sh --stop"
  echo "To view logs: tail -f /tmp/open-webui.log"
fi
