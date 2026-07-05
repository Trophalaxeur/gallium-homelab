resource "proxmox_virtual_environment_container" "bromine" {
  description  = "Bromine — CV tailoring backend (bromine-cv-extension)"
  node_name    = var.proxmox_node
  vm_id        = var.bromine_vmid
  started      = true
  unprivileged = true
  tags         = ["bromine", "cv", "homelab"]

  initialization {
    hostname = "bromine"

    ip_config {
      ipv4 {
        address = "${var.bromine_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  operating_system {
    template_file_id = var.bromine_lxc_template
    type             = "debian"
  }

  cpu {
    cores = 2
  }

  memory {
    # ⚠️ Sized for low request volume (~10/week). A PDF render (astro dev +
    # Playwright/Chromium) peaks around 450–550 MB — see bromine-backend
    # README for the bump-to-1536 procedure if this proves too tight.
    dedicated = 1024
    swap      = 0
  }

  disk {
    datastore_id = var.lxc_datastore
    # ⚠️ bismuth-blog node_modules (~500 MB) + Chromium (~300 MB) + Astro
    # Content Layer cache (~200 MB, must persist between renders) + OS.
    # Bump if `df -h` gets tight — see bromine-backend README.
    size = 5
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  features {
    nesting = true
  }

  startup {
    order = 3
  }
}

output "bromine_ip" {
  value = var.bromine_ip
}
