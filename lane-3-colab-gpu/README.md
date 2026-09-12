# Colab lane: GPU-accelerated generation, run in parallel with the GCP setup

## Why this exists

The GCP VM ended up CPU-only — GPU quota is hard-blocked on this account,
confirmed via two independent self-service paths (see `../DECISIONS.md`
§1.7). Colab's free tier gives a real T4 GPU with no quota fight at all.
Running this in parallel with the GCP/local setups was a hedge, not a
replacement: this lane is the one that ended up producing the full set of
logged, evaluated SWE-bench Verified results.

## What this is *not*

This does not run SWE-bench's evaluation harness inside Colab. That harness
builds/pulls a Docker image and runs a container **per instance** to apply
the patch and execute `FAIL_TO_PASS`/`PASS_TO_PASS`. Docker does not run
inside Colab's sandbox (no privileged containers, no accessible dockerd) —
this isn't a workaround choice, it's a real platform constraint.

The split is:

| Lane | Where | Produces |
|---|---|---|
| **Generation** | Colab, T4 GPU | `predictions.jsonl` — one Claude-Code-produced patch per instance |
| **Evaluation** | local WSL machine (Docker Desktop) | `../evaluation/eval_reports/` — the actual resolved/unresolved verdicts, the number that matters |

The only handoff between the two is the patch file itself — the Colab-side
git worktrees used to generate patches are gone (VM disconnected after each
session) but that doesn't matter: evaluation runs against SWE-bench's own
independent pre-built Docker images, not those worktrees.

## Two rounds were run, now merged into one set of outputs

**Round 1** — 10 instances (smallest gold-patch instances in SWE-bench
Verified, same list also used by the local/GCP setups so results are
directly comparable — see `../shared/swebench_selected_instances.json`),
900s per-instance timeout, model `qwen3:8b`.

**Round 2** — 5 different, previously-unattempted instances, 1000s
per-instance timeout (raised after round 1 produced empty patches on 2
genuine timeouts), same model. Launched after restarting Ollama/litellm
with `start_new_session=True` following a zombie-process incident (see
`../DECISIONS.md`).

Both rounds' predictions and logs are combined into a single
`predictions.jsonl` / `logs/` here — `swebench_selected_instances_colab.json`
is the authoritative manifest of all 15 instances this lane attempted, which
round each came from, its timeout, and its final outcome.

## Final results (evaluated against real SWE-bench Docker harness)

| Instance | Round | Outcome |
|---|---|---|
| `django__django-16429` | 1 | ✅ Resolved |
| `sympy__sympy-23950` | 1 | ✅ Resolved |
| `pallets__flask-5014` | 2 | ✅ Resolved |
| `django__django-14089` | 2 | ✅ Resolved |
| `django__django-16333` | 2 | ✅ Resolved |
| `django__django-14534` | 1 | ❌ Unresolved |
| `django__django-16082` | 1 | ❌ Unresolved |
| `sympy__sympy-22914` | 1 | ❌ Unresolved |
| `psf__requests-1921` | 2 | ❌ Unresolved |
| `scikit-learn__scikit-learn-14141` | 1 | ⏱️ Timeout (900s) |
| `sympy__sympy-23534` | 1 | ⏱️ Timeout (900s) |
| `sympy__sympy-15875` | 2 | ⏱️ Timeout (1000s) |
| `django__django-13406` | 1 | 🌀 Hallucination — model fabricated a fake tool-call transcript instead of editing (see `logs/django__django-13406/reasoning.md`) |
| `sympy__sympy-13757` | 1 | 🌀 Hallucination — model produced generic chat filler instead of attempting a fix |
| `sympy__sympy-19040` | 1 | 🌀 Hallucination — model correctly reasoned about the fix in prose but never called `Edit` |

**5/15 resolved, 4/15 unresolved, 3/15 timed out, 3/15 hallucinated.**

(Evaluated as two separate harness runs before the merge —
`../evaluation/eval_reports/colab-qwen3-8b.colab-qwen3-8b-run2.json` for
round 1's 10 instances and
`../evaluation/eval_reports/colab-qwen3-8b-batch2.colab-qwen3-8b-batch2-run1.json`
for round 2's 5 — the table above merges both into one manifest.)

Full per-instance reasoning traces and stats are in `logs/` — one
`reasoning.md` + `stats.json` per instance, for all 15.

## How to run this

1. Open `SWE_Bench_Colab_Runner.ipynb` in Google Colab (upload it, or
   Colab → File → Upload notebook). This notebook has been cleaned up to
   match exactly what actually ran and produced the results above — the
   tightened prompt, the `git diff` fix, and the reasoning/stats logging are
   all baked into the embedded `run_swebench_instances.py` cell (identical
   to `../shared/scripts/run_swebench_instances.py`), and the debug/check
   cells used along the way (repeated `nvidia-smi`/`ps aux` checks, raw
   transcript dumps, path-hunting for the `claude` binary, etc.) have been
   removed — those were live troubleshooting, not part of the pipeline.
2. Runtime → Change runtime type → **T4 GPU** (not the default — must be
   set explicitly every fresh connection).
3. Run cells top to bottom: install + start Ollama, pull `qwen3:8b`; install
   + start litellm; install Node.js + Claude Code CLI, export
   `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL` (same
   variable names as `../lane-1-local-setup/scripts/use-local-llm.sh`); a
   one-shot sanity test; install `swebench` + `datasets`; write out the
   generation script; a single-instance smoke test; round 1 (10 instances,
   900s timeout); inspect results; round 2 (5 instances, 1000s timeout) —
   both rounds append into the same `predictions.jsonl` / `logs/` since the
   script skips instance_ids already present in `--output`; inspect results;
   back up `predictions.jsonl` + `logs/` to Google Drive (Colab's disk
   disappears when the runtime recycles).
4. Move `predictions.jsonl` to a Docker-capable machine and evaluate:

   ```bash
   # from the repo root, using the local eval venv (see ../evaluation/)
   .venv-eval/bin/python -m swebench.harness.run_evaluation \
     --dataset_name SWE-bench/SWE-bench_Verified \
     --split test \
     --predictions_path lane-3-colab-gpu/predictions.jsonl \
     --max_workers 1 \
     --run_id <run-name>
   ```

   **Important:** the dataset must be `SWE-bench/SWE-bench_Verified`, not
   `princeton-nlp/SWE-bench_Verified` — the latter lacks the `image` field
   the installed `swebench==5.0.2` requires (`KeyError: 'image'` in
   `make_test_spec` otherwise). `--max_workers 1` is deliberate: parallel
   image pulls split bandwidth badly on a first run and made a run look
   "stuck" when it was just slow (~4.35GB per-instance images).

## Files here

- `SWE_Bench_Colab_Runner.ipynb` — the notebook, cleaned to the actual
  working flow (see above).
- `litellm_config_colab.yaml` — native-process variant of
  `../lane-1-local-setup/litellm/config.yaml`: `api_base:
  http://localhost:11434` (not `host.docker.internal`, nothing is
  containerized here), `qwen3:8b` at `num_ctx: 32768`.
- `predictions.jsonl` — all 15 generated patches (both rounds merged).
- `swebench_selected_instances_colab.json` — the combined, post-run manifest
  for all 15 instances: which round each came from, its timeout, and its
  final outcome (round 1's instance list is also
  `../shared/swebench_selected_instances.json`, shared with the local/GCP
  setups for comparability).
- `logs/` — per-instance `reasoning.md` (full LLM reasoning trace) +
  `stats.json` (tool-call counts, timing, patch size, whether the model
  searched before editing) for all 15 instances.

## Known limitations

- `--allowedTools` syntax has changed across Claude Code versions and was
  only ever verified with a single-tool example in this project's earlier
  tests — check `claude --help` if reproducing this and the smoke test
  misbehaves.
- The runner script does not execute each repo's own test suite before
  submitting a patch (no per-repo dependency environment installed in
  Colab) — it relies entirely on the evaluation harness's Docker containers
  for the actual pass/fail signal. Deliberate scope cut given the deadline.
