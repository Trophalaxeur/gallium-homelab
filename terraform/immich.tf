resource "proxmox_virtual_environment_container" "immich" {
  description  = "Immich — self-hosted photo/video backup (Docker Compose, ML enabled)"
  node_name    = var.proxmox_node
  vm_id        = var.immich_vmid
  started      = true
  unprivileged = true
  tags         = ["immich", "photos", "homelab"]

  initialization {
    hostname = "immich"

    ip_config {
      ipv4 {
        address = "${var.immich_ip}/24"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.root_password
    }
  }

  operating_system {
    template_file_id = var.immich_lxc_template
    type             = "debian"
  }

  cpu {
    cores = 4
  }

  memory {
    # ML complet activé (face recognition + smart search CLIP) — décision
    # Révision 3 de ~/.claude/plans/backup-strategy.md, sizing généreux
    # assumé plutôt que throttled. Vérifié 2026-07-06 : gallium a 30 Gi RAM
    # total / 21 Gi libres avant cette LXC — 6 Go dédiés tient large.
    dedicated = 6144
    swap      = 0
  }

  disk {
    datastore_id = var.lxc_datastore
    # rootfs OS + images Docker (server/ML/postgres/redis). Les photos ne
    # sont PAS ici — dataset ZFS séparé monté ci-dessous (backup=no).
    size = 20
  }

  # Bind-mount du dataset ZFS créé par le play Ansible "Provision ZFS dataset
  # for Immich photos". Exclu de PBS : protégé par sanoid (template_photos) +
  # rclone (Scaleway/HDD) à la place.
  # ⚠️ Le token terraform@pve!terraform_token (scopé, pas root@pam) ne peut PAS
  # créer ce bloc lui-même — l'API Proxmox refuse "mount point type bind" hors
  # root@pam. Il a donc été posé une fois manuellement via la console root
  # (`pct set 104 -mp0 ...`, cf. next-steps.md 2026-07-06) puis déclaré ici tel
  # quel pour que Terraform le voie au refresh et cesse de vouloir le détruire
  # (une valeur absente du .tf force le remplacement complet du conteneur).
  # Si cette LXC est un jour recréée de zéro, refaire le `pct set` à la main
  # juste après le `terraform apply` initial.
  mount_point {
    volume = "/rpool/data/immich-photos"
    path   = "/mnt/immich-photos"
    backup = false
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  features {
    nesting = true
    # keyctl=1 est bien posé côté Proxmox (`pct config 104` et l'API REST le
    # confirment tous les deux), mais le provider bpg/proxmox 0.105.0 ne le
    # parse pas correctement en lecture (state refresh-only renvoie
    # keyctl=false quel que soit l'état réel — bug de parsing du champ
    # `features`, pas une histoire de permissions cette fois). Déclarer
    # `keyctl = true` ici ferait donc croire à un drift permanent et Terraform
    # retenterait un PUT à chaque apply → 403 root@pam (même restriction que
    # le mount_point). Laissé à `false` pour matcher ce que le provider peut
    # effectivement lire ; la vraie valeur (1) reste posée manuellement hors
    # Terraform, cf. next-steps.md 2026-07-06.
    keyctl = false
  }

  startup {
    order = 5
  }
}

output "immich_ip" {
  value = var.immich_ip
}
