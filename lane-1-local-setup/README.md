# Local setup: the original, local-machine-only lane

## Why this exists

This was the first lane attempted, before any cloud/Colab pivot: a fully
local stack on a WSL2/Ubuntu environment — Ollama (native, on the WSL host)
+ litellm (containerized, via `docker-compose.yml` at the repo root) +
Claude Code, talking to a local open-weight model. This setup is GPU-capable
— Ollama would use the machine's dedicated GPU automatically if it were
detectable — but that GPU was found to be undetectable by every available
path (see `../DECISIONS.md` §1.7), so this lane ran CPU-only as a
hardware-fault workaround, not a design choice.

## What's here

- `litellm/config.yaml` — the litellm proxy config, mounted into the
  `litellm` container by `../docker-compose.yml`. Routes Claude Code's
  Anthropic-format requests to `ollama_chat/qwen3:8b` on
  `host.docker.internal:11434` (Ollama on the WSL host, litellm in a
  container — different network namespaces, hence not `localhost`).
- `scripts/use-local-llm.sh` — source this (don't execute it) to point a
  terminal's Claude Code session at the local litellm proxy:
  `source lane-1-local-setup/scripts/use-local-llm.sh`. Sets
  `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL` for that
  shell only.
- `instance1_hallucination_transcript.jsonl` — the raw transcript from this
  lane's first real SWE-bench attempt, which surfaced a genuine model
  hallucination (not just slowness) — see `../DECISIONS.md` §1.6 for
  the full root-cause writeup (traced to Claude Code's built-in tool-schema
  advertisement overwhelming a small model's context, not a prompt bug).

## How to run it

```bash
docker compose up -d          # from the repo root — starts the litellm proxy
source lane-1-local-setup/scripts/use-local-llm.sh
claude -p "..." --allowedTools Edit,Read,Grep,Glob,Write
```

## Outcome

CPU-only inference on this hardware proved too slow to be practical for
full SWE-bench Verified runs (see `../DECISIONS.md` §1.6–§1.7) — this is
what motivated the pivot to a cloud VM (`../lane-2-gcp-setup/`) and,
ultimately, Colab's free GPU tier (`../lane-3-colab-gpu/`, which produced
this project's actual logged 15-instance results). This lane's value is the
empirical findings it produced along the way (the qwen2.5-coder
tool-calling failure, the context-window truncation bug, the hallucination
incident) — all documented in `../DECISIONS.md`.
