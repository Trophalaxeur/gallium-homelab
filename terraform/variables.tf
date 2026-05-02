variable "proxmox_endpoint" {
  description = "URL de l'API Proxmox (ex: https://192.168.1.32:8006)"
  type        = string
}

variable "proxmox_username" {
  description = "Utilisateur Proxmox API (ex: terraform@pve!token-id)"
  type        = string
}

variable "proxmox_password" {
  description = "Mot de passe Proxmox"
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
  default     = "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
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
