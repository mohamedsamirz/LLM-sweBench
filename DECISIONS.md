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

Exact wording of the relevant constraint (quoted directly): *"Deploy a local copy of an LLM that
runs on your machine. Do not use any closed-source LLMs such as GPT or Claude, or any LLMs running
in the cloud."*

**Clarification obtained from the instructor (Prof. Jiang), 2026-09-10**: given the RTX 3060
hardware fault (§3) made CPU-only inference impractically slow (§4.6, §4.7), the instructor was
asked directly whether running the same self-hosted, open-source stack (Ollama + litellm — no
closed-source or hosted-API models) on a cloud virtual machine would satisfy the requirement,
since the literal wording ("runs on your machine," "no LLMs running in the cloud") read as
plausibly prohibiting this even with self-managed open-weight models. **Confirmed acceptable.**
This unblocks §4.7's cloud-VM path without ambiguity — it's no longer a judgment call, it's
instructor-approved. The agent harness question (Claude Code being closed-source software,
separate from the model it talks to) was considered and not raised — the assignment text itself
names Claude Code as the primary suggested harness ("Install Claude Code (or an open-source
alternative)"), which only makes sense if the "no closed-source" constraint targets the model
backend, not the orchestrating tool.

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

## 3. GPU status — investigated thoroughly, concluded likely hardware fault, proceeding CPU-only (final)

The RTX 3060 is listed on the laptop's known spec sheet, but every independent detection path
Windows and the firmware offer agrees it is not present as a usable device:

1. NVIDIA's own driver installer: "No NVIDIA GPU is detected on your system."
2. Windows Device Manager (`Get-PnpDevice -Class Display`): only lists the AMD Radeon iGPU. The
   RTX 3060's HDMI-audio companion function *does* show (`NVIDIA Virtual Audio Device`, status OK)
   — meaning the physical card still has some presence on the bus/power rail — but its display/3D
   controller function is entirely absent, not even as a disabled or unknown device.
3. WMI (`Get-CimInstance Win32_VideoController`): same result, independently confirmed — only the
   AMD iGPU.
4. Windows Settings → System → Display → Graphics → per-app GPU preference: even "High
   Performance" only offers "AMD Radeon(TM) Graphics" — Windows' own GPU picker has zero knowledge
   of a second GPU at all.
5. BIOS/UEFI itself (checked directly, independent of any OS or driver): reports the graphics
   device as AMD Radeon, with **no signal from the RTX 3060** — this is the most conclusive
   finding, since BIOS enumerates hardware before any OS or driver loads.
6. Confirmed the laptop was on AC power at the time of testing (`PowerOnline: True`), ruling out
   the earlier battery-throttling hypothesis from Armoury Crate's telemetry panel.
7. Checked for a known issue: this exact model (ASUS ROG Strix G513QM, Ryzen 9 5900HX + RTX 3060)
   has a documented community-reported bug of the dGPU intermittently not being detected, with
   ASUS's own suggested remedy being a BIOS-defaults reset (lower-risk than a firmware reflash).
   Noted for the record, but not pursued further given the accumulated evidence below.

**Conclusion**: with BIOS itself reporting no signal from the card — a lower-level, driver- and
OS-independent check than anything triable from software — this is most consistent with a
hardware-level fault (the GPU die or its MUX-switch hardware), not a configuration issue. This is
beyond what remote/software troubleshooting can fix; further diagnosis would require physical
hardware service, which is out of scope for this exercise.

**Decision (final): proceed CPU-only.** This was revisited seriously — not just deferred again —
once §4.6 established that CPU inference speed is a real practical bottleneck, specifically to
rule out "the GPU is a quick fix we're leaving on the table." It is not; the mitigation path is a
lighter model instead (§4.7). Nothing built so far is GPU-dependent or hard to reverse, so if the
hardware is ever repaired, switching to GPU acceleration remains a config change only (§4.2),
not a code change.

Driver that would have been used had detection succeeded: GeForce Game Ready 616.64 WHQL
(verified genuine via NVIDIA's own site, released 2026-09-03).

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

Model choice (original): **Qwen2.5-Coder-7B-Instruct**, Q4_K_M quantization, pulled via `ollama
pull qwen2.5-coder:7b`. Rationale: strongest CPU-realistic coding model at a size that fits
comfortably in available RAM, with native tool-calling support advertised in its chat template —
directly relevant to the risk flagged in §4.1. **Superseded — see §4.5**: this model was
empirically found not to actually produce working tool calls through Ollama (a confirmed,
widely-reported bug), and the project switched to **qwen3:8b**.

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

**Revised again, mid-implementation**: litellm was first run natively (venv + pip, matching
Ollama's reasoning in §4.2), then switched to a container after all
(`ghcr.io/berriai/litellm:main-stable`, via `docker-compose.yml`) once the native path hit a real
friction point — `python3 -m venv` failed with `ensurepip is not available`, requiring
`sudo apt install python3.12-venv`, another manual sudo step in a session that can't run sudo
itself. The `host.docker.internal:11434` networking concern raised against containerizing
turned out to be a single config line, not real complexity (Docker Desktop resolves that hostname
to the WSL host automatically; `docker-compose.yml` adds `extra_hosts: host.docker.internal:
host-gateway` for portability to plain Linux Docker too) — so once that was corrected, native lost
its main advantage. Image size is real (1.65GB vs. 650MB for the native venv, extra Python/OS base
layers) but disk isn't a constraint on this machine (§2). Native `.venv` was deleted; `docker
compose up -d` is now the actual deployment path.

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

Also added a wildcard catch-all entry in `litellm/config.yaml` (`model_name: "*"`) routing any
unrecognized incoming model name to the same local model. Reason: Claude Code has separate
opus/sonnet/haiku model tiers (`ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL`)
and may reference a hardcoded default name for a tier not explicitly overridden (e.g. a
lightweight background call). Hardcoding today's exact default model-name strings as aliases was
considered and rejected — those strings change across Claude Code versions (verified: litellm's
own current example config already uses different names than older ones like
`claude-3-5-sonnet-20241022`) — so a wildcard is the robust fix instead of a guessed literal list.

Deploy: `docker compose up -d` (see `docker-compose.yml` at the project root)

### 4.4 Orchestration: **Docker Compose for litellm; no Kubernetes**

Kubernetes was considered and explicitly rejected: it solves problems this project doesn't have
(multi-node scheduling, HA, rolling deploys, autoscaling), and even a lightweight cluster's
control-plane overhead (several hundred MB–1GB RAM) is a bad trade on a machine where every
gigabyte has been fought for. This is a single-node, single-user setup — Kubernetes here would
be a legibility red flag to a reviewer, not a sign of sophistication.

Ollama (§4.2) remains a native systemd service — no change there. litellm (§4.3) ended up
containerized via `docker-compose.yml` after all, for the reasons detailed in §4.3. Separately,
**the SWE-bench harness's own per-instance evaluation containers** (see §5) are orchestrated
directly by the harness's own tooling against the Docker daemon — no custom Compose/Dockerfile
of ours needed for that part; it's not our code to orchestrate.

### 4.5 Empirical finding: qwen2.5-coder:7b fails Anthropic-style tool calling (model swap required)

This directly tests the risk flagged in §4.1. Full stack was smoke-tested end-to-end first with a
plain-text request — **passed**: `curl` → litellm `/v1/messages` → Ollama `qwen2.5-coder:7b` →
correct Anthropic-shaped response (`content` text block, `stop_reason: end_turn`).

A follow-up test with a `tools` definition attached **failed**: instead of a structured
`tool_use` content block (`type: "tool_use"`, `stop_reason: "tool_use"`), the model's function
call came back as a plain JSON string inside an ordinary text block — indistinguishable from
prose to Claude Code's agent loop, which means no tool would ever actually execute.

Diagnosis performed, in order:
1. Repeated the same request directly against Ollama's native `/api/chat` (bypassing litellm
   entirely) — same failure, 3/3 identical trials. Ruled out litellm's translation layer as the
   cause; this is a model/Ollama-runtime problem.
2. `ollama show qwen2.5-coder:7b` confirms the model **is** tagged with `tools` capability, and
   `ollama show --template` shows its chat template explicitly instructs the model to wrap calls
   in `<tool_call>...</tool_call>` tags (which is what Ollama's parser scans for to populate the
   structured `tool_calls` field) — the model simply never emits those wrapper tags.
3. Tried an explicit few-shot example demonstrating the exact tag format in-context — still
   failed identically. Ruled out prompting as a fix; this is not a nudge-able instruction-following
   gap.
4. Web research confirmed this is a **known, widely-reported bug**, not specific to this setup:
   multiple GitHub issues (`ollama/ollama` #10899 "qwen2.5-coder and llama3.1 return empty content
   with tools", `ollama/ollama` #12174 "tool_calls missing from qwen2.5-coder", `vllm-project/vllm`
   #29192) document the same qwen2.5-coder-specific template/parser mismatch across multiple
   Ollama versions and even a different inference engine (vLLM) — confirming it's the model
   family's tool-call formatting, not our stack.

**Decision: swap the model to `qwen3:8b`.** Chosen over two other researched alternatives
(`llama3-groq-tool-use:8b`, purpose-built for function-calling with an 89.06% Berkeley
Function-Calling Leaderboard score; `llama3.1:8b`, a general-purpose baseline) because `qwen3:8b`
was the only one of the three both (a) explicitly reported as correctly populating Ollama's
`tool_calls` array, and (b) benchmarked as competitive with 7B–14B-class models on
HumanEval/LiveCodeBench — the strongest coding ability of the three candidates, which matters
directly given the exercise is a coding-agent task. `llama3-groq-tool-use:8b` is a DPO fine-tune of
plain Llama-3-8B with no coding-specific tuning, making it the weaker coding choice despite its
tool-calling specialization.

This finding is being kept in the log deliberately: it's a legitimate, citable empirical result
about local-model/agent-harness compatibility, not just implementation noise — exactly the kind
of thing the exercise's "run analysis" section should report honestly.

**Fix confirmed.** Same test re-run against `qwen3:8b` through the full stack (`curl` →
litellm `/v1/messages` → Ollama) returned a correctly-shaped response: a proper `tool_use`
content block (`"type": "tool_use"`, `"name": "get_weather"`, `"input": {"location": "Cairo"}`)
and `"stop_reason": "tool_use"` — exactly what Claude Code's agent loop expects. It also emitted
a `"thinking"` block ahead of the tool call, showing explicit reasoning before acting.

### 4.6 Empirical finding: real Claude Code round-trip — context window, memory, and CPU-speed limits

The isolated curl tests in §4.5 confirm the *protocol* works, but running the actual Claude Code
CLI against the stack (not just raw `curl`) surfaced three further, more serious problems.

**Context window truncation.** First real Claude Code test (`claude -p "Create a file called
hello.txt containing: hello world" --allowedTools Write`) did not create the file. Instead of
attempting the task, the model returned a generic, off-topic response ("It seems you've set up a
system for task management and web interaction..."), and Claude Code logged a warning that our
custom model alias isn't in its known catalog. Root cause: `ollama ps` showed the model running
with `context: 4096` — Ollama's silent default, applied regardless of a model's actual supported
window (`ollama show qwen3:8b` confirms **40960** tokens supported). Claude Code's real system
prompt plus its full tool-schema set is large enough that a 4096-token window plausibly crowded
out or truncated the actual user instruction, leaving the model responding to a fragment.
**Fix**: explicit `extra_body: options: num_ctx` in litellm's `litellm_params` per model entry
(litellm does not set this itself — verified via docs — Ollama's default silently applies unless
overridden).

**Out-of-memory incident.** First fix attempt set `num_ctx: 32768` (the model's near-max). This
caused the machine to run critically low on memory mid-test (`free -h` showed <200MB available,
swap actively used) and the harness force-killed the running process. Measured cause via `ollama
ps`: at `num_ctx: 32768` the loaded model's total footprint is **~10GB** (5.9GB weights + ~4.1GB
KV cache) on a 12GB WSL budget — too tight once litellm, Claude Code's own process, and OS
overhead are added.

**Orphaned server process — a real operational gotcha.** Killing the client process (the `claude`
CLI, or its wrapping `timeout` command) does **not** cancel the request already in flight to
litellm → Ollama. `llama-server` (Ollama's actual inference child process) kept running and
generating at 100% CPU independently, still holding ~10GB RSS, for many minutes after the
originating client was gone — confirmed via `ps aux` showing a `llama-server` process with no
corresponding live client. It doesn't respond to a normal `ollama stop` while mid-generation, and
because it runs as the `ollama` system user (not the working user), reclaiming it requires
`sudo systemctl restart ollama` — needed **twice** in this session before the machine reached a
stable, clean state. **Operational rule going forward: after any killed/timed-out test, always
run `ollama stop <model>` (or restart the service if that doesn't work) before starting another
test** — otherwise memory measurements and subsequent tests are unreliable.

**Fix, verified empirically before reuse**: dropped to `num_ctx: 8192`. Measured via a cheap
direct `ollama` request (not a full Claude Code run): total footprint **6.7GB**, ~4.5GB available
system-wide — a safe margin. Confirms KV cache scales roughly linearly with `num_ctx` for this
model (~4.1GB per 32768 tokens ≈ 0.125GB/1k tokens), useful for sizing any future context increase
needed for real SWE-bench tasks (which may need more than 8192 tokens once real repo files/diffs
are involved — will need re-measuring at that point, not assumed).

**CPU inference speed — the real open concern.** Even at the safe `num_ctx: 8192`, a full Claude
Code run on the trivial single-file-creation task did not finish within a **280-second** hard
timeout. This is a much bigger practical risk than model choice or context sizing: real SWE-bench
instances involve multi-turn agent loops (reading files, reasoning, editing, re-checking), and if
a trivial one-shot task doesn't complete in under 5 minutes on CPU-only 8B inference, a real
SWE-bench instance could take substantially longer — raising a real question about whether
CPU-only inference is practically viable for completing even 10 instances in a reasonable
timeframe, independent of whether the model would eventually get the *task* right. This directly
informed the discussion in §4.7 (lighter model vs. cloud GPU compute).

### 4.7 Pivot: local CPU-only → cloud VM with GPU (final infrastructure decision)

**Interim mitigation tried first**: swapped `qwen3:8b` → `qwen3:4b` (same family/template,
tool-calling re-confirmed working, ~3.9GB footprint vs. 6.7GB) to cut CPU compute. This helped but
did not resolve the core problem — timed tests were still repeatedly contaminated by two
compounding issues neither of which is fixable by model choice:

1. **Windows host-level memory starvation.** Diagnosed via `Get-CimInstance Win32_OperatingSystem`
   on the Windows side (not just `free -h` inside WSL, which looked fine in isolation): only
   **0.6GB free out of 15.4GB total physical RAM** at the host level. The `.wslconfig` cap
   (13GB) left too little (~2.4GB) for Windows itself, Docker Desktop's own host processes, and
   everything else — very likely causing disk-swap thrashing, which would explain response times
   far beyond what CPU-only token-generation math alone predicts. Mitigated by lowering the
   `.wslconfig` cap to `memory=10GB` (requires a full `wsl --shutdown` + restart to apply, done by
   the user outside this session) — but this is a mitigation for a symptom of the deeper problem,
   not a fix for CPU-only inference being fundamentally slow.
2. **Orphaned server-side generations.** Killing the client (the `claude` CLI, or a wrapping
   `timeout`) never cancels the request already in flight to litellm → Ollama — `llama-server`
   kept generating independently for over 40 minutes in one case, silently consuming CPU/RAM and
   starving subsequent test attempts. Required `sudo systemctl restart ollama` to clear, more than
   once.

**Given a hard deadline (originally 2026-09-12 Saturday, extended one day to 2026-09-13 Sunday to get the setup right)**, continuing to fight CPU-only inference —
un-recoverable per §3 (hardware fault, not fixable in software) — was judged not to be a good use
of remaining time, even before the instructor's answer came back. **Decision: move the entire
stack to a cloud VM with real GPU acceleration**, pending confirmation this doesn't violate the
exercise's constraints (see §1) — which the instructor then explicitly confirmed as acceptable.

**What does and doesn't change**: this is a deployment/infrastructure change, not an architecture
rewrite — direct validation of the abstraction principle stated back in the very first design
discussion (hardware and model choice should be config, not code, behind a stable HTTP API
boundary). Ollama, litellm, and Claude Code all move to the VM unchanged; `docker-compose.yml`
and `litellm/config.yaml` are the same files, just deployed somewhere with a working GPU. What
does change, now that compute is no longer the constraint: the `qwen3:4b` downgrade (§ above) was
a compute-driven compromise, not a quality preference — worth reconsidering `qwen3:8b` (or larger)
once a GPU is available, since coding quality matters more for SWE-bench than the CPU-only speed
concern that forced the smaller pick in the first place.

**Local WSL environment stopped, not deleted**: `docker compose down` (litellm container/network
removed) and `ollama stop` (model unloaded; the systemd service itself is left running — idle,
negligible resource cost) — done specifically so the local, GPU-fault-affected setup stops
competing for the same laptop resources while cloud provisioning is figured out. Nothing here was
uninstalled; the local setup remains available to fall back to if needed.

**Cloud provider selection.** GCP was the provider discussed with the instructor, but its free
trial **explicitly blocks GPU instances entirely** — confirmed via GCP's own documentation: GPU
quota is hard-set to 0 on free-trial billing and cannot be increased without upgrading to a paid
account (the $300 trial credit still applies afterward, but billing must be enabled). This
matches published guidance, not a misconfiguration on our end. Given the deadline,
paying to unblock GCP GPU quota was judged an acceptable, deliberate cost — not incurred lightly,
but justified by the deadline and by GCP being the option already discussed with the instructor.
(Genuinely free alternatives exist — Kaggle Notebooks offer ~30 guaranteed weekly GPU-hours with
no billing at all — but were set aside in favor of a real, persistent, SSH-able VM matching the
architecture already validated locally, rather than adapting to a notebook-session environment
under deadline pressure.)

**Provisioning tool: Terraform, not a plain `gcloud` shell script (revised choice).** A shell
script was written first and works fine for this scope (one VM, provisioned once) — Terraform's
usual value-adds (state tracking, drift detection, safe incremental changes across many resources
over time) aren't really needed here, the same reasoning already used to reject Kubernetes in
§4.4. Switched anyway: Terraform is the more recognized, industry-standard IaC practice, and
demonstrating it is worth more for the report than the marginal complexity cost, given this is
still just one resource and one `.tf` file. Noted here as a deliberate stylistic choice, not a
technical necessity — both were genuinely viable.

**Prep work completed while awaiting the paid account**, so provisioning is `terraform apply` once
billing is enabled (nothing here depends on the account existing yet):
- `cloud/main.tf` + `cloud/variables.tf` — a single `google_compute_instance` resource:
  `n1-standard-4` + one `nvidia-tesla-t4` GPU (cheapest GPU option; 16GB VRAM, comfortably fits
  even `qwen3:8b`'s ~5.9GB, priced ~$0.35-0.54/GPU-hour on-demand per current published rates),
  plain `ubuntu-2204-lts` base image (not a GCP Deep Learning VM image — deliberately avoided
  guessing an exact image-family string that couldn't be fully verified; a plain Ubuntu image +
  our own already-tested Ollama install script, which has its own NVIDIA driver installation
  logic for Debian/Ubuntu, is the lower-risk, already-proven choice). `scheduling.on_host_
  maintenance = "TERMINATE"` is required by GCP for any GPU-attached instance (no live migration
  support). Verified via `terraform validate` — config parses correctly.
- `cloud/startup-script.sh` — unchanged regardless of provisioning tool, referenced via
  `file()`: runs automatically on first boot, installs Docker, Ollama (+ GPU driver via Ollama's
  own installer), Node.js, Claude Code CLI, and pulls `qwen3:8b`.
- `cloud/terraform.tfvars.example` — only `project_id` needs to be filled in once the account
  exists; everything else has a sensible default.
- `gcloud` CLI (v584.0.0) and `terraform` CLI (v1.16.2, actual latest verified at install time,
  not a guessed/stale version) both installed locally under the user's home directory, no sudo
  needed, ready the moment billing/quota is available. `.gitignore` updated: `cloud/.terraform/`
  and `*.tfstate*` excluded (local cache, and state can contain resource details), but
  `.terraform.lock.hcl` is deliberately committed — same reproducibility principle as pinning
  `litellm==1.100.1`, it locks the exact provider version/checksum.

Remaining steps once the account is paid and Compute Engine API is enabled: fill in `project_id`
in `cloud/terraform.tfvars`, run `terraform apply` from `cloud/`, copy `docker-compose.yml` +
`litellm/config.yaml` to the VM (`gcloud compute scp`), `docker compose up -d`, then the
verification sequence from §7.

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
running 10 instances, not 500, so this trades wall-clock time for a large safety margin, which was
the right call at laptop scale (§4.6/§4.7) regardless of local vs. cloud, and worth stating as a
deliberate throughput/safety trade-off, not a limitation. Worth revisiting `max_workers` once
actual cloud VM specs are chosen (§4.7) — more cores may be available than the laptop had.

## 6. Current environment state (as of last check, post cloud-VM pivot)

| Component | Status |
|---|---|
| Exercise compliance | ✅ instructor confirmed cloud VM acceptable (§1), unblocking §4.7 |
| Local WSL: litellm container | ⏹️ stopped (`docker compose down`) — config files remain, unchanged |
| Local WSL: Ollama | ⏹️ model unloaded (`ollama stop`); systemd service left running, idle |
| Local WSL: `qwen2.5-coder:7b` | 🗑️ deleted (confirmed broken for tool-calling, §4.5, no longer needed) |
| Local WSL: `qwen3:8b`, `qwen3:4b` | 💾 still on disk (5.2GB + 2.5GB) — both confirmed working for tool-calling |
| `.wslconfig` | ✅ lowered to `memory=10GB` (§4.7) — needs `wsl --shutdown` + restart to take effect (user to do at home) |
| Cloud VM | ⏳ not yet provisioned — next concrete step |
| `docker-compose.yml`, `litellm/config.yaml`, `scripts/use-local-llm.sh` | ✅ written, validated locally, portable as-is to the VM |
| Claude Code round-trip (tool_use) | ✅ verified working via isolated curl tests; real Claude Code CLI run was never obtained *cleanly* on CPU (contaminated by host memory starvation + orphaned processes, §4.6/§4.7) — still an open validation once on the VM |
| swebench harness | ⏳ not yet installed anywhere |
| passwordless sudo | ⏳ not yet configured (optional convenience) |

## 7. Next steps (cloud VM pivot)

1. Provision a cloud VM with GPU (provider/instance type TBD with user — GCP was the
   instructor-cleared option discussed, e.g. a Compute Engine instance with an L4/T4 GPU)
2. On the VM: install Docker + NVIDIA Container Toolkit (or native NVIDIA driver if running Ollama
   natively, matching the local pattern in §4.2), then Ollama natively (same install script)
3. Copy `docker-compose.yml`, `litellm/config.yaml`, `scripts/use-local-llm.sh` to the VM
   unchanged — these were built specifically to not be laptop-specific (§4.7)
4. Pull the model — reconsider `qwen3:8b` over `qwen3:4b` now that compute is no longer the
   constraint (§4.7), for better coding quality on the actual SWE-bench tasks
5. Re-run the full verification sequence clean on the VM: tool-call curl test, then a real timed
   Claude Code CLI run (never obtained cleanly on the laptop) — this gives the first trustworthy
   end-to-end timing number for the whole project
6. Install Claude Code on the VM, confirm remote access/workflow (SSH session, port forwarding for
   litellm if needed, etc.)
7. Only then: install `swebench`, select ≥10 Verified instances, and begin actual runs
