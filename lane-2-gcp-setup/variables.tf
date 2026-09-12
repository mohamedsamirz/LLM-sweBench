variable "project_id" {
  description = "GCP project ID (billing enabled — GPUs are blocked on free-trial billing, see DECISIONS.md §4.7)"
  type        = string
}

variable "zone" {
  description = "GCP zone. us-central1-a has good T4 availability."
  type        = string
  default     = "us-central1-a"
}

variable "instance_name" {
  type    = string
  default = "swebench-agent-vm"
}

variable "machine_type" {
  description = "4 vCPU / 15GB RAM — pairs with one T4"
  type        = string
  default     = "n1-standard-4"
}

variable "gpu_type" {
  description = "Cheapest GPU option, 16GB VRAM — comfortably fits qwen3:8b (~5.9GB)"
  type        = string
  default     = "nvidia-tesla-t4"
}

variable "enable_gpu" {
  description = "Whether to attach a GPU. Default false until the GCP GPU quota increase (requested, pending approval — see DECISIONS.md §4.7) comes through."
  type        = bool
  default     = false
}

variable "disk_size_gb" {
  description = "OS + Docker images + model weights"
  type        = number
  default     = 50
}
