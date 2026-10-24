resource "proxmox_virtual_environment_container" "hassium" {
  description  = "Home Assistant — domotique (HA Container + Caddy, Docker Compose)"
  node_name    = var.proxmox_node
  vm_id        = var.hassium_vmid
  started      = true
  unprivileged = true
  tags         = ["home-assistant", "domotique", "homelab"]

  initialization {
    hostname = "hassium"

    ip_config {
      ipv4 {
        address = "${var.hassium_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  operating_system {
    template_file_id = var.hassium_lxc_template
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
    # retention window (recorder.purge_keep_days, set in hassium-automation's
    # configuration.yaml) — 16 Go is comfortable and resizable later.
    #
    # ⚠️ BACKUP CAVEAT — this LXC is in pbs_backup_vmids (playbook.yml), but a
    # PBS `mode: snapshot` run copies the recorder SQLite DB while HA is
    # writing to it. WAL usually replays cleanly on restore; that is a
    # likelihood, NOT a guarantee. The application-consistent layer is Home
    # Assistant's own scheduled backup, which must be enabled once in the UI
    # (Settings → System → Backups) — its tarballs land on the dataset
    # mounted below, NOT on this rootfs. Same reasoning that put the Immich
    # photos on their own dataset with logical dumps rather than trusting a
    # live snapshot. See docs/home-assistant.md.
    size = 16
  }

  # ── Bind-mount: Home Assistant's backups dataset ──────────────────────────
  # rpool/data/hassium-backups, created by the Ansible play "Provision ZFS
  # datasets". HA writes its scheduled backups here (docker-compose.yml.j2
  # mounts it over /config/backups). A dataset rather than the rootfs: it
  # survives a rebuild of this LXC, sanoid snapshots it, and the backup LXC
  # (105) mounts it read-only to ship it to Scaleway + HDD — the Immich photos
  # pattern. backup=false: PBS never copies bind-mounts anyway.
  #
  # ⚠️ Same root@pam limitation as terraform/immich.tf: the scoped token cannot
  # create a bind mount (API 403). On a from-scratch create: 1) comment this
  # block out, 2) `terraform apply`, 3) on the Proxmox root console:
  #      pct set <vmid> -mp0 /rpool/data/hassium-backups,mp=/mnt/hassium-backups,backup=0
  # 4) uncomment and re-apply — no diff expected.
  mount_point {
    volume = "/rpool/data/hassium-backups"
    path   = "/mnt/hassium-backups"
    backup = false
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

output "hassium_ip" {
  value = var.hassium_ip
}
