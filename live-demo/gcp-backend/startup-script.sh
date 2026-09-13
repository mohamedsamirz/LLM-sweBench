#!/bin/bash
# GCP VM startup-script (metadata key: startup-script). Runs automatically as
# root on first boot. Same base stack as lane-2-gcp-setup/startup-script.sh —
# see there for why each piece was chosen. Idempotent enough to re-run safely.
set -e

# GCP's startup-script execution environment has no controlling login session:
# $HOME is unset and `logname` errors ("no login name"). Both the Ollama CLI
# (panics without $HOME) and any `sudo -u "$(logname)"` pattern rely on one
# being present, so set it explicitly up front.
export HOME=/root

# --- Docker ---
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

# --- Ollama (its own install script installs the NVIDIA driver + CUDA runtime
# for the detected GPU) ---
if ! command -v ollama &> /dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
systemctl enable --now ollama

# --- Node.js (for Claude Code CLI) ---
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

# --- Claude Code CLI ---
if ! command -v claude &> /dev/null; then
  npm install -g @anthropic-ai/claude-code
fi

# --- Model: qwen3:8b, this VM has a real GPU (V100/P100) so there's no
# CPU-speed reason to compromise down to qwen3:4b the way lane-2's CPU-only
# VM had to. ---
ollama pull qwen3:8b

# --- Control layer (start/stop/status/run endpoints, idle watchdog, Caddy
# reverse proxy for TLS) is not installed here yet — that's the next piece to
# build once the frontend/backend API contract is finalized. This script
# currently only gets the base model-serving stack running. ---

echo "startup-script complete. Base stack (Docker, Ollama+qwen3:8b, Claude Code) ready."
