#!/bin/bash
# GCP VM startup-script (metadata key: startup-script). Runs automatically as root
# on first boot. Provisions the exact same stack validated locally in WSL —
# see DECISIONS.md §4.7. Idempotent enough to re-run safely if it fails partway.
set -e

# --- Docker ---
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

# --- Ollama (its own install script installs the NVIDIA driver + CUDA runtime
# for the detected GPU; already verified to have this logic for Debian/Ubuntu) ---
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

# --- Pull the model. qwen3:8b (not :4b) since a real GPU removes the CPU-speed
# constraint that forced the smaller model locally (DECISIONS.md §4.7) ---
sudo -u "$(logname)" ollama pull qwen3:8b || ollama pull qwen3:8b

echo "startup-script complete. Next: copy docker-compose.yml + litellm/config.yaml to this VM and run 'docker compose up -d'."
