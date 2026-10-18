resource "proxmox_virtual_environment_container" "homeassistant" {
  description  = "Home Assistant — domotique (HA Container + Caddy, Docker Compose)"
  node_name    = var.proxmox_node
  vm_id        = var.homeassistant_vmid
  started      = true
  unprivileged = true
  tags         = ["home-assistant", "domotique", "homelab"]

  initialization {
    hostname = "homeassistant"

    ip_config {
      ipv4 {
        address = "${var.homeassistant_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  operating_system {
    template_file_id = var.homeassistant_lxc_template
    type             = "debian"
  }

  cpu {
    cores = 2
  }

  memory {
    # HA Container alone idles around 400 Mo, but the recorder, the websocket
    # frontend and the companion services added later (Mosquitto, Zigbee2MQTT,
    # evcc — phases 2/3) all land in this same LXC. 2 Go leaves room for them
    # without a resize. Officially HA asks for 2 Go minimum.
    dedicated = 2048
    swap      = 0
  }

  disk {
    datastore_id = var.lxc_datastore
    # rootfs + Docker images + /opt/home-assistant/config, which holds the
    # recorder SQLite DB. That DB grows with the number of entities and the
    # retention window (default 10 days) — 16 Go is comfortable for a homelab
    # and resizable later. No separate dataset: the whole thing is small and
    # covered by PBS (vmid must be listed in pbs_backup_vmids, playbook.yml).
    size = 16
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  features {
    nesting = true
  }

  startup {
    order = 8
  }
}

output "homeassistant_ip" {
  value = var.homeassistant_ip
}
