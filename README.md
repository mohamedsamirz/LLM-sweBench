# Local-LLM SWE-bench Agent

A local, open-weight LLM wired up to Claude Code as the agent harness, used
to attempt real [SWE-bench Verified](https://www.swebench.com/) issues end
to end — patch generation and real Docker-based evaluation, not just "a
patch was produced."

This repo contains **three parallel lanes** of that setup, each pursued as
earlier lanes hit hardware or platform limits, plus the evaluation results
scored against the real SWE-bench Docker harness.

## Start here

- **`DECISIONS.md`** — the full architecture/decisions log: every technical
  choice made, why, and what broke along the way.
- **`shared/`** — code and data common to more than one lane:
  - `scripts/run_swebench_instances.py` — the canonical generation script
    (checks out each instance's repo at its base commit, builds the agent
    prompt, runs Claude Code non-interactively, captures the resulting diff
    plus a full reasoning trace).
  - `swebench_selected_instances.json` — the original 10-instance selection
    (smallest gold-patch instances in SWE-bench Verified, used as a
    complexity proxy), shared across lanes so results are directly
    comparable.
- **`docker-compose.yml`** — starts the litellm proxy container; shared by
  the local and GCP setups (see below) — same stack either would run on a
  GPU if one were available.

## The three lanes

| Lane | Where it runs | GPU? | Status |
|---|---|---|---|
| [`lane-1-local-setup/`](lane-1-local-setup/README.md) | Local machine, WSL2 | No (hardware fault, see `DECISIONS.md` §1.7) | Surfaced key findings (tool-calling model swap, context-window truncation, a hallucination incident), too slow for a full run |
| [`lane-2-gcp-setup/`](lane-2-gcp-setup/README.md) | GCP VM (Terraform) | No (GPU quota blocked) | Cloud CPU, run independently |
| [`lane-3-colab-gpu/`](lane-3-colab-gpu/README.md) | Google Colab | Yes (T4) | Produced this project's actual logged, evaluated 15-instance result set |

## Evaluation

- **`evaluation/eval_reports/`** — the real SWE-bench Docker harness's
  resolved/unresolved verdicts (`swebench.harness.run_evaluation`, dataset
  `SWE-bench/SWE-bench_Verified`) for the generated patches. This is the
  number that actually matters — a non-empty patch is not itself a "pass."
- Evaluation runs on a Docker-capable machine only (Colab cannot run
  Docker at all — see `lane-3-colab-gpu/README.md`), using the `.venv-eval/`
  virtualenv (`uv venv .venv-eval && uv pip install --python
  .venv-eval/bin/python swebench`) to work around the system Python's
  PEP 668 restriction.

Generated in two rounds on Colab/T4 (round 1: 10 instances, 900s timeout;
round 2: 5 more, 1000s timeout), now merged into one manifest —
`lane-3-colab-gpu/predictions.jsonl` and
`lane-3-colab-gpu/swebench_selected_instances_colab.json`.

**Combined: 5 resolved, 4 unresolved, 6 empty patches, out of 15 attempted
instances** — see the Results section at the end of this file for the
per-instance breakdown.

## Reasoning logs

Every attempted instance has a full reasoning trace and stats, not just its
final patch:

- `lane-3-colab-gpu/logs/<instance_id>/{reasoning.md,stats.json}` — all 15
  instances, both rounds

Each `stats.json` records elapsed time, whether the timeout was hit, tool
call counts, whether the model searched the codebase before editing,
thinking length, and patch size. Each `reasoning.md` is the model's full
chain of thought for that instance.

## Results

15 [SWE-bench Verified](https://www.swebench.com/) instances attempted,
evaluated against the real SWE-bench Docker harness — **5 resolved, 4
unresolved, 3 timed out, 3 hallucinated** (produced no patch despite not
timing out — see each instance's `reasoning.md` for what actually happened).

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
| `django__django-13406` | 1 | 🌀 Hallucination — model fabricated a fake tool-call transcript instead of editing real files |
| `sympy__sympy-13757` | 1 | 🌀 Hallucination — model produced generic chat filler instead of attempting a fix |
| `sympy__sympy-19040` | 1 | 🌀 Hallucination — model correctly reasoned about the fix in prose but never called `Edit` |

Full manifest: `lane-3-colab-gpu/swebench_selected_instances_colab.json`.
Full reasoning traces: `lane-3-colab-gpu/logs/<instance_id>/reasoning.md`.
