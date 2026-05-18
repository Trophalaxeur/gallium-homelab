# Proxmox backup schedule for LXC neon (vzdump --mode snapshot)
#
# Proxmox distinguishes two concepts:
#   - Snapshot: filesystem-level point-in-time copy, lives on the same storage as the LXC.
#   - Backup (vzdump): exported archive, can use a snapshot internally as the consistency
#     mechanism (`--mode snapshot`). What we configure here is a backup job in snapshot mode.
#
# The bpg/proxmox provider does not expose a backup schedule resource.
# Configure it manually in the Proxmox UI after first `terraform apply`:
#
#   Datacenter → Backup → Add
#   - Node:         gallium
#   - Storage:      a backup-capable storage on your Proxmox node
#                   (often the same pool used for the LXC disks — see var.lxc_datastore)
#   - Schedule:     daily
#   - Max backups:  7
#   - VM:           neon (ID = var.neon_vmid)
#   - Mode:         snapshot
#
# Alternatively, add a cron job on the Proxmox host (replace <storage>):
#   0 4 * * * root vzdump <neon_vmid> --maxfiles 7 --mode snapshot --storage <storage>
