terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }
}

provider "google" {
  project = var.project_id
  zone    = var.zone
}

# Single VM, provisioned once for a short-lived evaluation run — no multi-resource
# dependency graph or drift-tracking need here (see DECISIONS.md §4.7 for why
# Terraform was chosen over a plain gcloud script anyway: report-visible IaC
# practice, despite the scope being small enough that either would work).
resource "google_compute_instance" "swebench_agent" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone

  # Lets Terraform stop -> resize -> restart the instance in place for a
  # machine_type change (e.g. bumping vCPUs for a faster CPU-only eval run)
  # instead of erroring out or requiring a full destroy/recreate. Boot disk
  # persists either way, so Docker/Ollama/the pulled model survive a resize.
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.disk_size_gb
    }
  }

  network_interface {
    network = "default"
    access_config {} # ephemeral external IP — needed for SSH access
  }

  # GPU is toggleable: new paid-billing GCP projects start with a hard 0 GPU
  # quota that requires manual Google approval (see DECISIONS.md §4.7 —
  # request submitted, pending). Until it's granted, we deploy CPU-only
  # (identical stack, just slower inference) and flip enable_gpu back to
  # true, one `terraform apply`, once quota comes through.
  dynamic "guest_accelerator" {
    for_each = var.enable_gpu ? [1] : []
    content {
      type  = var.gpu_type
      count = 1
    }
  }

  # TERMINATE is required by GCP for any instance with an attached GPU (live
  # migration isn't supported for GPU instances). Without a GPU, most modern
  # machine families (e.g. e2) actively reject TERMINATE unless preemptible,
  # so MIGRATE (GCP's normal default) is used instead.
  scheduling {
    on_host_maintenance = var.enable_gpu ? "TERMINATE" : "MIGRATE"
    automatic_restart   = true
  }

  # Same startup-script used regardless of how the VM is provisioned — installs
  # Docker, Ollama (+ NVIDIA driver via Ollama's own installer), Node, Claude
  # Code, and pulls qwen3:8b. See DECISIONS.md §4.7 for why a plain Ubuntu image
  # + this script was chosen over a GCP Deep Learning VM image.
  metadata_startup_script = file("${path.module}/startup-script.sh")
}

output "instance_name" {
  value = google_compute_instance.swebench_agent.name
}

output "external_ip" {
  value = google_compute_instance.swebench_agent.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.swebench_agent.name} --zone=${var.zone} --project=${var.project_id}"
}
