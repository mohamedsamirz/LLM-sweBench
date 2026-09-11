# Source this file (do not execute) to point Claude Code at the local
# litellm -> Ollama stack for this terminal session only:
#
#   source scripts/use-local-llm.sh
#
# These are shell-process-scoped exports; they do not persist to other
# terminals or get baked into ~/.bashrc, so normal Claude Code usage
# elsewhere is unaffected. See DECISIONS.md section 4.3 for the reasoning.

export ANTHROPIC_BASE_URL="http://localhost:4000"
export ANTHROPIC_AUTH_TOKEN="sk-litellm-static-key"
export ANTHROPIC_MODEL="local-qwen3"

echo "Claude Code is now pointed at local litellm proxy (http://localhost:4000) -> Ollama qwen3:4b"
