resource "proxmox_virtual_environment_container" "uptime" {
  description  = "Uptime Kuma — self-hosted heartbeat + service monitoring (Docker Compose)"
  node_name    = var.proxmox_node
  vm_id        = var.uptime_vmid
  started      = true
  unprivileged = true
  tags         = ["uptime-kuma", "monitoring", "homelab"]

  initialization {
    hostname = "uptime"

    ip_config {
      ipv4 {
        address = "${var.uptime_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  operating_system {
    template_file_id = var.uptime_lxc_template
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    # Uptime Kuma is light (Node + SQLite). 1 Go leaves headroom for the
    # container + a handful of active probes. Same footprint class as adguard.
    dedicated = 1024
    swap      = 0
  }

  disk {
    datastore_id = var.lxc_datastore
    # rootfs + Docker image + Kuma's SQLite data dir (/opt/uptime-kuma/data).
    # No separate dataset: the monitoring config is small and fully recreatable,
    # so plain rootfs (covered by PBS) is enough — no bind-mount, no root@pam
    # console step (unlike immich/backup).
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
    order = 7
  }
}

output "uptime_ip" {
  value = var.uptime_ip
}
