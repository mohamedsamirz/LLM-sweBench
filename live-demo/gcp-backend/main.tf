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

# This is a SEPARATE resource from lane-2-gcp-setup's swebench-agent-vm — that
# VM documents the project's actual historical CPU-only GCP trial (T4 quota
# blocked, see ../../DECISIONS.md §1.7) and is left untouched. This VM exists
# for a different purpose: an on-demand live demo backend, built after V100/
# P100/P4 quota was discovered available on this same account/project.
#
# External IP is deliberately left ephemeral (not a reserved static address):
# a static IP attached to a STOPPED instance still bills (~$0.01/hr), which
# works against the whole point of stopping this VM between demo sessions.
# An ephemeral IP is free while stopped and freshly assigned on each start —
# the control layer resolves the current IP after each start rather than
# assuming a fixed hostname.
resource "google_compute_instance" "swebench_demo" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone

  # Lets Terraform stop -> resize -> restart in place for a machine_type or
  # gpu_type change instead of requiring a full destroy/recreate.
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.disk_size_gb
    }
  }

  network_interface {
    network = "default"
    access_config {} # ephemeral external IP — see note above
  }

  dynamic "guest_accelerator" {
    for_each = var.enable_gpu ? [1] : []
    content {
      type  = var.gpu_type
      count = 1
    }
  }

  # TERMINATE is required by GCP for any instance with an attached GPU (no
  # live migration support for GPU instances).
  scheduling {
    on_host_maintenance = var.enable_gpu ? "TERMINATE" : "MIGRATE"
    automatic_restart   = true
  }

  # Same base stack as lane-2-gcp-setup (Docker, Ollama + NVIDIA driver via
  # Ollama's own installer, Node, Claude Code CLI) plus this VM's own
  # control-layer pieces (start/stop/status/run endpoints, idle watchdog,
  # Caddy for TLS) — see startup-script.sh.
  metadata_startup_script = file("${path.module}/startup-script.sh")
}

output "instance_name" {
  value = google_compute_instance.swebench_demo.name
}

output "external_ip" {
  value = google_compute_instance.swebench_demo.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.swebench_demo.name} --zone=${var.zone} --project=${var.project_id}"
}
