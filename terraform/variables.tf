variable "proxmox_endpoint" {
  description = "URL de l'API Proxmox (ex: https://192.168.1.32:8006)"
  type        = string
}

variable "proxmox_token_id" {
  description = "Token ID Proxmox (format: user@realm!token-name)"
  type        = string
  default     = "terraform@pve!terraform_token"
}

variable "proxmox_api_token" {
  description = "Secret du token Proxmox API (UUID)"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Nom du nœud Proxmox"
  type        = string
  default     = "gallium"
}

variable "proxmox_ip" {
  description = "IP du serveur Proxmox"
  type        = string
  default     = "192.168.1.32"
}

variable "lxc_template" {
  description = "Template LXC (doit être présent dans Proxmox)"
  type        = string
  default     = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
}

variable "lxc_datastore" {
  description = <<-EOT
    Proxmox datastore pour les disques LXC (REQUIRED — pas de default).
    Valeurs typiques: "local-zfs" (pool ZFS local) ou "local-lvm".
    ⚠️ ForceNew sur changement — terraform RECRÉE le conteneur, perte de données.
    Set explicitement dans terraform.tfvars selon le pool effectivement utilisé.
  EOT
  type        = string
}

variable "adguard_vmid" {
  description = "VMID du conteneur AdGuard"
  type        = number
  default     = 100
}

variable "adguard_ip" {
  description = "IP statique du LXC AdGuard Home"
  type        = string
  default     = "192.168.1.53"
}

variable "gateway" {
  description = "Passerelle réseau"
  type        = string
  default     = "192.168.1.1"
}

variable "root_password" {
  description = "Mot de passe root du conteneur LXC"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Clé SSH publique pour accès root au LXC"
  type        = string
}

# --- neon ---

variable "neon_vmid" {
  description = "VMID du conteneur neon"
  type        = number
  default     = 101
}

variable "neon_ip" {
  description = "IP statique du LXC neon"
  type        = string
  default     = "192.168.1.60"
}

variable "neon_lxc_template" {
  description = "Template LXC pour neon (Debian 12 recommandé)"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
}
