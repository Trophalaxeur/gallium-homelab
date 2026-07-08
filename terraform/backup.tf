resource "proxmox_virtual_environment_container" "backup" {
  description  = "backup — isolated LXC running the rclone/HDD/object-lock jobs (no exposed service)"
  node_name    = var.proxmox_node
  vm_id        = var.backup_vmid
  started      = true
  unprivileged = true
  tags         = ["backup", "rclone", "homelab"]

  initialization {
    hostname = "backup"

    ip_config {
      ipv4 {
        address = "${var.backup_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  operating_system {
    template_file_id = var.backup_lxc_template
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    # Minimal: this LXC only runs rclone/aws-cli/msmtp on cron — no service,
    # no ML, no DB. Same gabarit as adguard (512 Mo).
    dedicated = 512
    swap      = 0
  }

  disk {
    datastore_id = var.lxc_datastore
    # rootfs only (rclone, awscli, scripts, logs). Photos/HDD are bind-mounts
    # below, never on this disk. ~5 Go per the space calc in
    # ~/.claude/plans/backup-strategy.md.
    size = 5
  }

  # ── Bind-mount 1: the Immich photos dataset, READ-ONLY ──────────────────────
  # This LXC copies the photos out to Scaleway/HDD but must never be able to
  # mutate them — a compromise of the backup jobs must not reach the source of
  # truth (Scénario 6 isolation). read_only enforces `ro=1` on the mount.
  # backup=false: excluded from PBS (photos are protected by sanoid + rclone).
  #
  # ⚠️ Same root@pam limitation as terraform/immich.tf: the scoped token
  # (terraform@pve!terraform_token) cannot create a `mount point type bind`
  # (API 403, "only allowed for root@pam"). On a from-scratch (re)create the
  # apply fails on THIS block until the mount is posted manually. Procedure:
  #   1) Comment out both mount_point blocks below.
  #   2) `terraform apply` — creates the LXC without the mounts.
  #   3) On the Proxmox root console, post them by hand:
  #        pct set 105 -mp0 /rpool/data/immich-photos,mp=/mnt/immich-photos,ro=1,backup=0
  #        pct set 105 -mp1 /mnt/hdd-external,mp=/mnt/hdd,backup=0
  #   4) Uncomment both blocks and re-run `terraform apply` — no diff expected.
  mount_point {
    volume    = "/rpool/data/immich-photos"
    path      = "/mnt/immich-photos"
    read_only = true
    backup    = false
  }

  # ── Bind-mount 2: the external HDD (WD Red, mounted host-side on
  # /mnt/hdd-external, fstab nofail — cf. Étape 0-bis). The 3rd physical copy.
  # Writable here (this is the only LXC that writes to the HDD, Scénario 6). ──
  mount_point {
    volume = "/mnt/hdd-external"
    path   = "/mnt/hdd"
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
    order = 6
  }
}

output "backup_ip" {
  value = var.backup_ip
}
