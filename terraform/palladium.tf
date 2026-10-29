resource "proxmox_virtual_environment_container" "palladium" {
  description  = "palladium — the only internet-facing LXC: Caddy with client certificates (mTLS) in front of hassium/immich, plus immich-public-proxy for share links"
  node_name    = var.proxmox_node
  vm_id        = var.palladium_vmid
  started      = true
  unprivileged = true
  tags         = ["gateway", "mtls", "homelab"]

  initialization {
    hostname = "palladium"

    ip_config {
      ipv4 {
        address = "${var.palladium_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  operating_system {
    template_file_id = var.palladium_lxc_template
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    # Caddy + one small Node container (immich-public-proxy). Same footprint
    # class as uptime.
    dedicated = 1024
    swap      = 0
  }

  disk {
    datastore_id = var.lxc_datastore
    # Stateless: Caddyfile, certificates and compose file are all pushed by
    # Ansible, so a rebuild is a `terraform apply` + one play. No bind-mount,
    # no root@pam console step, and left out of the PBS job on purpose.
    size = 8
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  features {
    nesting = true
  }

  startup {
    order = 9
  }
}

output "palladium_ip" {
  value = var.palladium_ip
}
