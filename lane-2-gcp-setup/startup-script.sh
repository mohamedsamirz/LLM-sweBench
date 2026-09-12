#!/bin/bash
# GCP VM startup-script (metadata key: startup-script). Runs automatically as root
# on first boot. Provisions the exact same stack validated locally in WSL —
# see DECISIONS.md §4.7. Idempotent enough to re-run safely if it fails partway.
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

# --- Pull the model. qwen3:4b for now: this VM is temporarily CPU-only
# (GCP GPU quota request pending approval, see DECISIONS.md §4.7) and must
# match litellm/config.yaml's current model. Once GPU quota is granted and
# enable_gpu is flipped to true, re-pull qwen3:8b and update config.yaml to
# match — a real GPU removes the CPU-speed constraint that forces the
# smaller model here. ---
ollama pull qwen3:4b

echo "startup-script complete. Next: copy docker-compose.yml + litellm/config.yaml to this VM and run 'docker compose up -d'."
