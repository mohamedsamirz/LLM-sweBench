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

  guest_accelerator {
    type  = var.gpu_type
    count = 1
  }

  # Required by GCP for any instance with an attached GPU — live migration
  # isn't supported, so the instance must terminate (and auto-restart) for
  # host maintenance instead.
  scheduling {
    on_host_maintenance = "TERMINATE"
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
