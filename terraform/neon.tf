resource "proxmox_virtual_environment_container" "neon" {
  description  = "Neon — Multica agents platform"
  node_name    = var.proxmox_node
  vm_id        = var.neon_vmid
  started      = true
  unprivileged = true
  tags         = ["neon", "agents", "homelab"]

  initialization {
    hostname = "neon"

    ip_config {
      ipv4 {
        address = "${var.neon_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  operating_system {
    template_file_id = var.neon_lxc_template
    type             = "debian"
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 1024
    swap      = 0
  }

  disk {
    datastore_id = var.lxc_datastore
    size         = 20
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  features {
    nesting = true
  }

  startup {
    order = 2
  }

  on_boot = true
}

output "neon_ip" {
  value = var.neon_ip
}
