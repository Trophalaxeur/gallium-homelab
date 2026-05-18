# Proxmox snapshot schedule for LXC neon
#
# The bpg/proxmox provider does not expose a snapshot schedule resource.
# Configure it manually in the Proxmox UI after first `terraform apply`:
#
#   Datacenter → Backup → Add
#   - Node:       gallium
#   - Storage:    local (or local-zfs)
#   - Schedule:   daily
#   - Max backups: 7
#   - VM:         neon (ID = var.neon_vmid)
#   - Mode:       snapshot
#
# Alternatively, add a cron job on the Proxmox host:
#   0 4 * * * root vzdump <neon_vmid> --maxfiles 7 --mode snapshot --storage local
