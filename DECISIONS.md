# Project Decisions Log — Local-LLM SWE-bench Agent Exercise

This log records every architectural decision made while setting up this exercise, and the
reasoning behind each one. It exists so that (a) implementation work can proceed without
re-deriving context, and (b) it doubles as material for the report's design/architecture
section — every entry here is something defensible to a reviewer, not just "what we did."

## 1. Exercise requirements (source: Exercises.pdf, item 2)

- Deploy a **local** LLM (no closed-source/cloud models — no GPT, no Claude API).
- Install Claude Code (or an open-source alternative) and make it work with that local LLM.
- Use the resulting agent to solve **≥10 SWE-bench Verified** issues (not all need to resolve).
- Deliverables: code + a 1–2 page report (architecture/design + run analysis).

## 2. Hardware environment (audited, not assumed)

- Machine: **ASUS ROG Strix G513QM**
- CPU: AMD Ryzen 9 5900HX — 8 cores / 16 threads
- RAM: 15.4GB physical total
- GPU: RTX 3060 Laptop (6GB GDDR6) — **present but not currently usable** (see §3)
- Disk: 951GB free — not a constraint anywhere in this project
- OS: Windows 11 (build 26200), WSL2 (version 2.7.13.0), Ubuntu distro
- Docker Desktop installed on Windows host, WSL integration enabled and verified working
  (daemon reachable, image pull/run confirmed via `hello-world`)

**WSL memory**: default cap was 7.5GB (50% split); raised via `C:\Users\MOHAMED\.wslconfig`:
```ini
[wsl2]
memory=13GB

[experimental]
autoMemoryReclaim=gradual
```
(`autoMemoryReclaim` must live under `[experimental]`, not `[wsl2]` — putting it in `[wsl2]`
produces an "unknown key" warning at WSL startup.) Confirmed post-reboot: ~12GB total, ~10GB
free inside WSL.

## 3. GPU status — unresolved, proceeding CPU-only

The RTX 3060 is physically present (confirmed via Windows PnP device enumeration and the
laptop's known spec) but was undetectable by the NVIDIA installer ("No NVIDIA GPU is detected").
Root cause identified: ASUS Armoury Crate's GPU power mode. `Standard` mode was enabled, but the
live GPU telemetry showed **"Extreme Power Saving"** across frequency/voltage/temperature —
consistent with either the laptop running on battery (dGPU heavily throttled/idled when
unplugged is normal on this class of laptop) or a separate Windows Power Mode setting.
Not yet confirmed fixed as of this writing. **Decision: proceed CPU-only for now**; nothing
done so far is GPU-dependent or hard to reverse, so this can be revisited later without
rework — switching to GPU later is a config change (see §4.2), not a code change.

Driver used when eventually retried: GeForce Game Ready 616.64 WHQL (verified genuine via
NVIDIA's own site, released 2026-09-03).

## 4. Architecture decisions

### 4.1 Agent harness: **Claude Code + protocol proxy** (chosen over SWE-agent, or both)

Claude Code has no native local-model mode — it only speaks Anthropic's Messages API. A
translation proxy is mandatory, not optional, to use it with any local model. This was a
deliberate choice over SWE-agent (which natively speaks OpenAI-compatible APIs and has
SWE-bench scoring built in, needing no proxy) because it's the more literal reading of the
exercise and produces a more interesting artifact: a real commercial coding agent, rewired to
run entirely on local hardware.

Key risk flagged for the report: **tool-calling format compatibility is not guaranteed.**
Claude Code's tool-use (`tool_use`/`tool_result` blocks) only works if the local model was
itself trained on a structured tool-calling output format. This is an empirical question this
project answers, not an assumption it makes.

### 4.2 LLM runtime: **Ollama, installed natively on the WSL host** (not containerized)

Originally planned to containerize Ollama (`ollama/ollama` image, 3.7GB) for reproducibility.
Reversed after working through the actual consequences:
- Ollama's binary is simultaneously the client and the server (`ollama serve` vs. every other
  subcommand). Containerizing only the server while keeping a native CLI client requires an
  awkward split (native CLI configured via `OLLAMA_HOST` to reach a containerized server, or
  `docker exec` for every command) that adds real friction for no real benefit here.
- This is a single-machine, single-user research exercise, not something that needs to be
  redeployed elsewhere — the strongest argument for containerizing was reproducibility, and a
  documented native install script is equally reproducible.
- Running natively also means: if the GPU issue in §3 is ever resolved, GPU acceleration works
  automatically with zero config changes to this project — Ollama auto-detects available
  hardware at the same abstraction boundary (its HTTP API) regardless of what's underneath it.

Install: `curl -fsSL https://ollama.com/install.sh | sh` (~1.4GB download, bundles CPU+CUDA
backend libraries either way — there is no slim client-only release artifact; verified via
GitHub releases API, so no point trying to avoid the bundle size).

Model choice: **Qwen2.5-Coder-7B-Instruct**, Q4_K_M quantization, pulled via `ollama pull
qwen2.5-coder:7b`. Rationale: strongest CPU-realistic coding model at a size that fits
comfortably in available RAM, with native tool-calling support in its chat template — directly
relevant to the risk flagged in §4.1.

### 4.3 Protocol proxy: **litellm** (pivoted away from `claude-code-router`)

**Original plan** was `@musistudio/claude-code-router` (npm, CLI `ccr`). Verified as a
legitimate package (npm registry maintainer matches GitHub maintainer exactly), but investigating
its actual Dockerfile and docs revealed it's a full desktop-app-shaped product: Electron/web-UI,
SQLite-backed runtime config, OAuth account import, credential pools, usage-billing tracking.
Its own docs state configuration is meant to happen through its GUI and persists in SQLite —
"do not edit `config.sqlite` directly." This conflicts directly with the reproducibility goal
(a git-trackable, plain-file config for the report/repo).

**Switched to `litellm`**, specifically its `/v1/messages` endpoint — a genuine
Anthropic-Messages-format-translating endpoint (distinct from litellm's *other* "Anthropic
passthrough" feature, which was checked and ruled out: that one forwards raw requests straight
to Anthropic's real cloud API, unmodified — not what we need). litellm is a single lightweight
Python process configured via a plain `config.yaml`, fully git-committable.

Also reversed the plan to containerize litellm, for the same reasoning as §4.2: it's a simple
process, running it natively avoids `host.docker.internal` networking complexity to reach a
native Ollama, and Docker isn't earning its keep here either.

**Security check performed before installing**: litellm had a real, confirmed supply-chain
compromise — PyPI versions **1.82.7 and 1.82.8** (March 2026) contained a credential-stealing
payload (part of the "TeamPCP" campaign that also hit Trivy), auto-executing via a malicious
`.pth` file on any Python startup, harvesting AWS/GCP/SSH/Slack/Discord credentials. Caught and
quarantined within ~40 minutes; `v1.83.0+` is clean (rebuilt via hardened CI/CD). **Decision:
pin an exact version rather than install unpinned** — using `litellm[proxy]==1.100.1` (current
latest, verified via `pip index versions`, well past the compromised range). This is a
deliberate, citable security practice, not just an implementation detail.

Correct environment variables (verified against litellm+Claude Code integration docs, and note
this corrects an earlier wrong guess of `ANTHROPIC_API_KEY`):
```bash
export ANTHROPIC_BASE_URL="http://localhost:4000"   # litellm proxy address, NOT Ollama directly
export ANTHROPIC_AUTH_TOKEN="sk-litellm-static-key"  # placeholder; litellm doesn't validate it meaningfully
```
`ANTHROPIC_BASE_URL` must point at **litellm**, never directly at Ollama — Ollama only speaks
OpenAI-compatible JSON, Claude Code only speaks Anthropic-Messages JSON; litellm is the only
thing that understands both. These `export` lines are shell-process-scoped only — they do not
leak into other terminals or into this Claude Code session itself, so normal Anthropic usage
elsewhere is unaffected. Plan: keep them in a project-root script (e.g.
`scripts/use-local-llm.sh`) that's explicitly `source`d, rather than baked into `~/.bashrc`, so
the local-routing config is always opt-in per terminal.

Install: `python3 -m venv .venv && source .venv/bin/activate && pip install 'litellm[proxy]==1.100.1'`

### 4.4 Orchestration: **Docker Compose reserved solely for the SWE-bench evaluation harness** — no Kubernetes

Kubernetes was considered and explicitly rejected: it solves problems this project doesn't have
(multi-node scheduling, HA, rolling deploys, autoscaling), and even a lightweight cluster's
control-plane overhead (several hundred MB–1GB RAM) is a bad trade on a machine where every
gigabyte has been fought for. This is a single-node, single-user setup — Kubernetes here would
be a legibility red flag to a reviewer, not a sign of sophistication.

Given §4.2 and §4.3 both moved to native processes, **Docker's only remaining job in this
project is the SWE-bench harness's own per-instance evaluation containers** (see §5) — which
is orchestration the harness's own tooling already does directly against the Docker daemon.
No custom Compose/Dockerfile needed for that part; it's not our code to orchestrate.

## 5. SWE-bench harness (for implementation reference)

Separate from the entire agent/model stack above — it's the grading system, agnostic to how a
patch was produced. Package: `swebench` (pip, from `princeton-nlp/SWE-bench`). Per instance it:
takes a git-diff patch, spins up a Docker container pinned to that repo/commit/environment
(built or pulled from their registry), applies the patch, runs `FAIL_TO_PASS` + `PASS_TO_PASS`
test lists, and scores resolved/unresolved by comparing to expected results. Our agent stack and
the harness only interact through the patch file — a clean, deliberate boundary worth stating
in the report.

Resource guidance for the harness (official recommendation: 16GB RAM, 8 cores, 120GB storage,
`max_workers = min(0.75*cpu_count, 24)`) is calibrated for running the full 500-instance set in
parallel. **Decision: run evaluation serially (`max_workers=1`, or cautiously 2)** — we're
running 10 instances, not 500, so this trades wall-clock time for a large safety margin on a
resource-constrained laptop, which is the right call at this scale and worth stating as a
deliberate throughput/safety trade-off, not a limitation.

## 6. Current environment state (as of last check)

| Component | Status |
|---|---|
| `pip` | ✅ installed (24.0) |
| Docker | ✅ working end-to-end (daemon reachable, pull+run verified) |
| Node/npm | ✅ present (v22.23.2 / 10.9.8) — not currently needed after the litellm pivot |
| Claude Code | ✅ already installed (v2.1.267) |
| WSL memory config | ✅ applied (13GB cap, gradual auto-reclaim) |
| Native Ollama | ⏳ leftover partial install cleaned up; full native install not yet (re)run |
| litellm | ⏳ not yet installed |
| GPU | ⏸️ unresolved (§3), proceeding CPU-only |
| passwordless sudo | ⏳ not yet configured (optional convenience) |

## 7. Next steps

1. `curl -fsSL https://ollama.com/install.sh | sh` — native Ollama install
2. `ollama pull qwen2.5-coder:7b`
3. `python3 -m venv .venv && source .venv/bin/activate && pip install 'litellm[proxy]==1.100.1'`
4. Write `litellm/config.yaml` (or project-root `config.yaml`) routing a model alias to
   `ollama/qwen2.5-coder:7b` at `http://localhost:11434`
5. Write `scripts/use-local-llm.sh` (the `export ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`
   lines from §4.3), committed to the repo
6. Start litellm proxy, smoke-test with a bare `curl` against `/v1/messages` before involving
   Claude Code at all
7. Run `claude` in a terminal with the env script sourced, confirm a trivial task round-trips
   correctly (including at least one tool call, to validate the §4.1 risk empirically)
8. Only then: install `swebench`, select ≥10 Verified instances, and begin actual runs
