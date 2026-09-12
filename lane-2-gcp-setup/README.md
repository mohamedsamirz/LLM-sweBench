# GCP setup: cloud VM lane (Terraform), run in parallel with Colab

## Why this exists

After the local setup (`../lane-1-local-setup/`) proved too slow for full
SWE-bench runs, the project pivoted to a cloud VM to get past the local
machine's CPU/RAM ceiling. This setup is GPU-capable by design — `enable_gpu`
is a Terraform variable and `startup-script.sh` installs the NVIDIA
driver/CUDA runtime whenever a GPU is attached — but GPU quota turned out to
be hard-blocked on this GCP account (confirmed via two independent
self-service paths — see `../DECISIONS.md` §1.7), so this VM ran CPU-only,
same as the local setup, just with more cores/RAM. Running Colab
(`../lane-3-colab-gpu/`) in parallel with this lane was a hedge, not a
replacement — whichever produced enough logged results first, or the better
result, is what's used. In practice, Colab's real T4 GPU produced this
project's actual final results.

## What's here

- `main.tf`, `variables.tf`, `.terraform.lock.hcl`,
  `terraform.tfvars.example` — Terraform IaC provisioning the GCP VM.
  `terraform.tfvars` (real project ID/region, gitignored, not committed)
  and `.terraform/` / `*.tfstate*` (also gitignored — local plugin cache and
  state) are not tracked in git.
- `startup-script.sh` — the VM's metadata `startup-script`, runs
  automatically as root on first boot: installs Docker, installs Ollama
  (its installer also handles NVIDIA driver/CUDA setup if a GPU were
  present), installs Node.js + the Claude Code CLI, pulls the model. It's
  idempotent enough to re-run safely if it fails partway.
- This VM depends on the same `../docker-compose.yml` +
  `../lane-1-local-setup/litellm/config.yaml` as the local setup — those
  get copied to the VM at deploy time rather than duplicated here, since
  they're the identical stack.

## How to run it

```bash
cd lane-2-gcp-setup
terraform init
terraform apply   # provisions the VM, runs startup-script.sh automatically
# then copy ../docker-compose.yml and ../lane-1-local-setup/litellm/config.yaml
# to the VM and run: docker compose up -d
```

## Outcome

See `../DECISIONS.md` §1.7–§1.8 for the cloud-pivot and GPU-quota-block
decisions and the evaluation harness/instance-selection methodology (this
lane picked the original 10-instance list shared with Colab,
`../shared/swebench_selected_instances.json`). This lane's own
generation/evaluation results, if produced independently of Colab, are
tracked wherever they were logged.
