# Live demo

A separate, additive piece of this project: an on-demand chat interface where
a visitor picks any SWE-bench Verified instance and watches the same
Claude-Code-on-a-local-model pipeline (`../shared/scripts/run_swebench_instances.py`)
generate and evaluate a real patch, live.

This is **not** a revision of the three lanes documented in the top-level
`README.md`/`DECISIONS.md` — those describe the project's actual historical
trials (local CPU, GCP CPU-only, Colab GPU) and are left untouched. This demo
was built afterward, once V100/P100/P4 GPU quota was discovered available on
the same GCP project that `lane-2-gcp-setup/` had found blocked for T4/A100/L4.

## Pieces

- `gcp-backend/` — Terraform for a separate VM (`swebench-demo-vm`, distinct
  from lane-2's `swebench-agent-vm`) with a V100 attached. Stays stopped by
  default; a control layer (start/stop/status/run endpoints + an idle
  watchdog) boots it on demand and stops it after ~1 hour of inactivity, so
  cost is bounded to actual usage rather than however long the demo link is
  left circulating.
- A Vercel-hosted frontend (built separately) talks to this backend over a
  small API contract (`/api/instances`, `/api/vm/start`, `/api/vm/status`,
  `/api/run`) and streams the reasoning trace back live via SSE.

## Why a separate VM from lane-2-gcp-setup

Reusing `lane-2-gcp-setup`'s VM would mean either overwriting the config that
documents the CPU-only trial (making the repo contradict the report) or
juggling two conflicting states on one resource. A second VM, in a zone
(`europe-west4-a`) with confirmed V100/P100/P4 quota, keeps both fully
independent: lane-2 stays exactly as documented, this is new infrastructure
for a new purpose.
