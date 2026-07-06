resource "proxmox_virtual_environment_container" "pbs" {
  description  = "PBS — Proxmox Backup Server (adguard/neon/bromine, incremental)"
  node_name    = var.proxmox_node
  vm_id        = var.pbs_vmid
  started      = true
  unprivileged = true
  tags         = ["pbs", "backup", "homelab"]

  initialization {
    hostname = "pbs"

    ip_config {
      ipv4 {
        address = "${var.pbs_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  operating_system {
    template_file_id = var.pbs_lxc_template
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    # PBS minimum officiel ~1 Go RAM ; le "8 Go recommandé" de la doc Proxmox
    # vise des datastores multi-To. Ici ~100 Go / 3 LXC — largement dans les
    # clous à 1 Go, cohérent avec le footprint d'adguard (512 Mo).
    dedicated = 1024
    swap      = 0
  }

  disk {
    datastore_id = var.lxc_datastore
    # rootfs (~5 Go) + datastore PBS (~85-105 Go estimés pour 3 LXC sys, 30j,
    # cf. ~/.claude/plans/backup-strategy.md) — headroom inclus.
    size = 150
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  features {
    nesting = true
  }

  startup {
    order = 4
  }
}

output "pbs_ip" {
  value = var.pbs_ip
}
