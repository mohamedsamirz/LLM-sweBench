variable "project_id" {
  description = "GCP project ID (same project as lane-2-gcp-setup, separate VM resource)"
  type        = string
}

variable "zone" {
  description = "europe-west4-a carries V100, P100, and P4 all together (confirmed via `gcloud compute accelerator-types list` + a per-region quota check) — us-central1-a and us-east1-d were both ruled out in lane-2-gcp-setup's history for unrelated machine-type stockouts, not quota."
  type        = string
  default     = "europe-west4-a"
}

variable "instance_name" {
  description = "Deliberately distinct from lane-2-gcp-setup's swebench-agent-vm — this is a separate resource for the live demo, not a replacement of the historical CPU-only trial VM."
  type        = string
  default     = "swebench-demo-vm"
}

variable "machine_type" {
  description = "4 vCPU / 15GB RAM — N1 family required to pair with V100/P100/T4"
  type        = string
  default     = "n1-standard-4"
}

variable "gpu_type" {
  description = "V100, 16GB VRAM. Quota confirmed at 1 in this zone (T4/A100/L4 are 0 on this account). P100 (also quota 1 here) is the fallback if V100 hits a capacity stockout at apply time."
  type        = string
  default     = "nvidia-tesla-v100"
}

variable "enable_gpu" {
  description = "This VM's whole purpose is the GPU lane, so this defaults true (unlike lane-2-gcp-setup, where it defaults false to match that lane's actual CPU-only history)."
  type        = bool
  default     = true
}

variable "disk_size_gb" {
  description = "OS + Docker images + model weights"
  type        = number
  default     = 50
}
