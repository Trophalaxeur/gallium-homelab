terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_token_id}=${var.proxmox_api_token}"
  insecure  = true
}

resource "proxmox_virtual_environment_container" "adguard" {
  description  = "AdGuard Home — DNS local"
  node_name    = var.proxmox_node
  vm_id        = var.adguard_vmid
  started      = true
  unprivileged = true

  tags = ["adguard", "dns", "homelab"]

  initialization {
    hostname = "adguard"

    ip_config {
      ipv4 {
        address = "${var.adguard_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  operating_system {
    template_file_id = var.lxc_template
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 0
  }

  disk {
    datastore_id = var.lxc_datastore
    size         = 4
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  features {
    nesting = true
  }

  # First to boot, before every other LXC (neon 2, pbs 4, immich 5, backup 6,
  # uptime 7, homeassistant 8). AdGuard is the homelab's resolver: any service
  # that reaches the internet at startup fails until it answers. Home Assistant
  # made this visible — its cloud integrations (Overkiz for the Thermor towel
  # rail) resolve at boot. They do retry, but ordering the resolver first
  # removes the race instead of relying on retries.
  startup {
    order = 1
  }
}

output "adguard_ip" {
  value = var.adguard_ip
}
