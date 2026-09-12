# Architecture & Design Decisions

This log records the architecture decisions behind this project and the reasoning for each one —
not the step-by-step debugging that led to them.

## 1. Architecture Decisions

### 1.1 Agent harness: Claude Code + protocol proxy (over SWE-agent)

Claude Code has no native local-model mode — it only speaks Anthropic's Messages API, so a
translation proxy is mandatory to use it with any local model. This was a deliberate choice over
SWE-agent (which natively speaks OpenAI-compatible APIs and has SWE-bench scoring built in,
needing no proxy): it produces a more interesting artifact — a real commercial coding agent,
rewired to run entirely on local, open-weight hardware — and demonstrates protocol-level
interoperability rather than relying on a framework that already speaks the model's native API.

Key risk this creates: Claude Code's tool-use (`tool_use`/`tool_result` blocks) only works if the
local model was itself trained on a structured tool-calling output format — an empirical question
this project had to answer, not an assumption it could make (see §1.4).

### 1.2 LLM runtime: Ollama, installed natively (not containerized)

Considered containerizing Ollama for reproducibility, and rejected it: Ollama's binary is
simultaneously client and server, so containerizing only the server while keeping a native CLI
client requires an awkward split for no real benefit in a single-machine deployment — a documented
native install script is equally reproducible. Running natively also means GPU acceleration,
wherever this stack is deployed, works with zero config changes: Ollama auto-detects available
hardware behind the same HTTP API boundary regardless of what's underneath it. This is also why
the same `docker-compose.yml` + `litellm/config.yaml` could move unchanged from a laptop, to a GCP
VM, to being reproduced natively inside Colab (§1.6).

Model choice evolved as constraints changed: `qwen2.5-coder:7b` (rejected, §1.4) → `qwen3:8b`
(working, but slow on CPU) → `qwen3:4b` (CPU-compute compromise) → back to `qwen3:8b` once GPU
compute was available (Colab), since coding quality matters more than CPU-only speed once that
constraint is gone.

### 1.3 Protocol proxy: litellm (not claude-code-router)

Considered `@musistudio/claude-code-router` first, but its actual shape is a full desktop-app
product (Electron/web-UI, SQLite-backed runtime config, OAuth account import) whose own docs say
config should happen through its GUI — this conflicts with the reproducibility goal of a
git-trackable, plain-file config.

**Chose `litellm`** instead, specifically its `/v1/messages` endpoint (a genuine
Anthropic-Messages-format-translating endpoint, distinct from its separate "Anthropic passthrough"
feature, which forwards straight to Anthropic's real cloud API and was ruled out). litellm is a
single process configured via a plain `config.yaml`, fully git-committable. It ended up
containerized (`docker-compose.yml`) rather than run in a native venv, once the native path hit a
real Python-venv friction point on the deployment target — the `host.docker.internal` networking
concern this raised turned out to be a single config line (`extra_hosts`), not real complexity.

**Security note worth keeping**: litellm had a real, confirmed supply-chain compromise (PyPI
versions 1.82.7–1.82.8, a credential-stealing payload, part of the "TeamPCP" campaign). **Decision:
pin an exact, verified-clean version** (`litellm[proxy]==1.100.1`) rather than install unpinned —
a deliberate, citable security practice.

Also added a wildcard catch-all model entry (`model_name: "*"`) in every `litellm/config.yaml`
variant, routing any unrecognized incoming model name to the same local model — Claude Code has
separate opus/sonnet/haiku model-tier defaults that can reference a hardcoded name not explicitly
overridden, and hardcoding those exact strings was rejected since they change across Claude Code
versions.

### 1.4 Model swap: qwen2.5-coder → qwen3 family (tool-calling compatibility)

This is the empirical answer to the risk flagged in §1.1. `qwen2.5-coder:7b` passed a plain-text
round-trip but **failed** to produce a structured `tool_use` block when given a tool definition —
its function call came back as plain JSON text indistinguishable from prose, meaning no tool would
ever actually execute. Root-caused (bypassing litellm to isolate the layer, inspecting the model's
own chat template, and cross-checking against multiple public GitHub issues reporting the same
qwen2.5-coder-specific template/parser mismatch across Ollama and even a different inference
engine) to the model itself never emitting the wrapper tags its own template calls for — not a
prompting or proxy issue.

**Decision: swap to `qwen3:8b`**, chosen over two other candidates (`llama3-groq-tool-use:8b`,
`llama3.1:8b`) because it was the only one both confirmed to correctly populate Ollama's
`tool_calls` array *and* competitive on coding benchmarks — the strongest coding ability of the
three, which matters directly for a coding-agent task. Confirmed fixed via the same test: a proper
`tool_use` content block and `stop_reason: "tool_use"`.

### 1.5 Orchestration: Docker Compose for litellm, no Kubernetes

Kubernetes was considered and rejected: it solves problems this project doesn't have (multi-node
scheduling, HA, autoscaling), and even a lightweight cluster's control-plane overhead is a bad
trade for a single-node, single-user deployment — it would be a legibility red flag to a reviewer,
not a sign of sophistication. Ollama runs as a native service; litellm is the one component
containerized via Compose. The SWE-bench harness's own per-instance evaluation containers (§1.8)
are orchestrated by the harness's own tooling, not by any Compose file of ours.

### 1.6 Context window and tool-schema restriction fixes

Two non-obvious fixes were required to get a real Claude Code run (not just an isolated protocol
test) working correctly, both worth keeping as they'd otherwise silently corrupt results:

- **`num_ctx` must be set explicitly per model in `litellm_params`.** Ollama silently defaults to
  4096 tokens regardless of a model's actual supported window, which is easily smaller than Claude
  Code's own system prompt + tool schemas — this caused an early run to respond to a truncated
  fragment of the actual instruction. Value used depends on available memory: a smaller ceiling on
  memory-constrained hosts; `32768` once running somewhere with enough free RAM (a GCP VM, Colab).
- **Claude Code's `--tools` flag, not just `--allowedTools`, is required to restrict which tool
  schemas get *advertised* to the model.** `--allowedTools` only gates which tools can execute
  without a permission prompt — the full built-in tool roster (dozens of schemas, mostly
  multi-agent orchestration and task scheduling, entirely irrelevant to a file-editing task) is
  still sent to the model every turn regardless. A weak-to-mid-size model drowning in irrelevant
  tool schemas latched onto one and hallucinated a matching but completely unrelated scenario
  instead of the real task — reproducible across both `qwen3:4b` and `qwen3:8b`, ruling out model
  size as the cause. Adding `--tools "Read,Edit,Write,Grep,Glob"` alongside `--allowedTools`
  immediately fixed it.

### 1.7 Cloud pivot: local CPU-only → cloud GPU (GCP, then Colab)

CPU-only inference on a local machine was not practically viable for a full SWE-bench run: even a
trivial single-file-write task did not reliably complete within a patient multi-minute timeout,
and this compounds badly once real multi-turn agentic loops (reading files, editing, re-checking)
are involved. Compounding this, the development machine's own dedicated GPU turned out to be
unusable due to a hardware fault (confirmed independently at the driver, OS, and firmware level) —
out of scope to repair here. Continuing to fight CPU-only inference on that machine was judged not
worth the time.

**Decision: move the stack to cloud GPU compute** — a deployment change, not an architecture
rewrite, since Ollama/litellm/Claude Code were already built to be hardware-agnostic behind a
stable HTTP API boundary (§1.2). GCP was the first cloud provider chosen; **Terraform** was chosen
over a plain `gcloud` script for the IaC/reproducibility practice it demonstrates, even though this
project's scope (one VM) doesn't strictly need Terraform's usual value-adds — a deliberate
stylistic choice, not a technical necessity.

**GCP's GPU quota turned out to be structurally blocked on this account** — confirmed through two
independent self-service paths (the Cloud Quotas API and the classic console quota-request form),
both hard-capped at 0 with no path to a self-service increase. **Decision: deploy the GCP VM
CPU-only** rather than keep fighting this, and pursue a genuine GPU lane elsewhere in parallel —
first Lightning AI was considered, then **Google Colab's free-tier T4 GPU** was chosen as the
actual working GPU lane, since it requires no quota negotiation at all. This is a deliberate hedge,
not a redundant effort: whichever lane produced a complete, logged result set first (or the better
result) is the one used — in practice, Colab is what did.

Everything built for the CPU lanes stayed reusable for Colab: same Ollama + litellm + Claude Code
stack, same prompt, same generation script — the only adaptation is that Colab has no Docker at
all, so both litellm and Ollama run as native processes there (not via `docker-compose.yml`), and
evaluation (which needs Docker) happens on a separate, Docker-capable machine. This patch-file-only
handoff between generation and evaluation is a deliberate architectural boundary, not a limitation
of one lane — see `lane-3-colab-gpu/README.md` for the concrete flow.

### 1.8 SWE-bench evaluation harness

The harness (`swebench` package) is separate from the entire agent/model stack above — it's the
grading system, agnostic to how a patch was produced. Per instance it takes a git-diff patch,
spins up a Docker container pinned to that repo/commit/environment, applies the patch, runs
`FAIL_TO_PASS` + `PASS_TO_PASS`, and scores resolved/unresolved. **Our agent stack and the harness
only interact through the patch file** — a deliberate, clean boundary.

Dataset used is `SWE-bench/SWE-bench_Verified`, not `princeton-nlp/SWE-bench_Verified` — the
latter is missing the `image` field the installed harness version requires to build/pull each
instance's Docker image.

**Decision: run evaluation with `max_workers=1`** rather than the harness's own default guidance
(calibrated for running the full 500-instance set in parallel on much larger hardware) — this
trades wall-clock time for a large safety margin appropriate to running ~15 instances, and also
avoids splitting download bandwidth across simultaneous multi-GB image pulls.

**Instance selection**: the 10 smallest gold-patch instances (by character length) from SWE-bench
Verified's 500, used as a deliberate proxy for issue scope/tractability given constrained compute
— not a random or difficulty-blind sample. A second round of 5 more (same methodology, next-smallest,
excluding the first 10) was added on the Colab GPU lane with a longer timeout, for 15 total
attempted instances. Full manifest with final per-instance outcomes:
`lane-3-colab-gpu/swebench_selected_instances_colab.json`.

**Timeout policy**: a fixed per-instance wall-clock timeout (raised once, from 900s to 1000s,
after early timeouts on the first batch), with the model's servers always restarted before the
next run — killing the client does not cancel an in-flight generation server-side. A timeout is
treated as a valid, reportable "unresolved/empty" outcome, consistent with SWE-bench Verified's own
expectation that not every instance resolves — not a failure to be hidden.

## 2. Final Architecture: Three Parallel Lanes

This project ended up running three separate lanes of the same underlying stack rather than one
linear path, as each earlier lane hit a hard limit:

1. **`lane-1-local-setup/`** — local machine, WSL2, CPU-only (local GPU hardware fault, §1.7).
   Surfaced the core empirical findings above (tool-calling model swap, context-window
   truncation, the tool-schema hallucination root cause) but was never practical for a full run.
2. **`lane-2-gcp-setup/`** — GCP VM via Terraform, CPU-only (§1.7's GPU quota block).
3. **`lane-3-colab-gpu/`** — Google Colab, real T4 GPU. This is the lane that produced the
   project's actual logged, evaluated results (15 instances attempted, 5 resolved, 4 unresolved,
   6 empty patches — see `lane-3-colab-gpu/README.md`).

See the top-level `README.md` for how these three lanes and the evaluation step fit together.
