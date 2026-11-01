---
title: "Network Troubleshooting"
description: "Diagnosing and recovering from LAN connectivity loss to gallium, adguard, and neon."
---

# Network Troubleshooting

## Symptom: full LAN unreachability

All three homelab hosts (`gallium` 192.168.1.32, `adguard` 192.168.1.53, `neon` 192.168.1.60) stop responding at once:

- `ping` to all three fails
- `ssh` returns `No route to host`
- `.lan` DNS resolution also fails (expected — AdGuard itself is one of the unreachable hosts)
- `ip neigh show` on thallium shows ARP state `FAILED` or `INCOMPLETE` for all three IPs, on both interfaces

This is an L2 (ARP) failure, not a DNS or routing issue — the hosts are simply absent from the LAN.

## Diagnosis steps

Run these from thallium, in order, to confirm scope before assuming the worst:

1. **Check the gateway is reachable** — rules out a thallium-side network stack issue (dhcpcd/iwd):
   ```bash
   ping -c2 192.168.1.1
   ip neigh show | grep "192.168.1.1 "
   ```
   If the Livebox gateway responds and ARP-resolves normally, thallium's network stack is fine.

2. **Sweep the LAN for any live hosts** — confirms the switch/LAN segment itself is up:
   ```bash
   for i in $(seq 1 254); do (ping -c1 -W1 192.168.1.$i >/dev/null 2>&1 &); done
   sleep 6
   ip neigh show | grep -v FAILED | grep -v INCOMPLETE | sort
   ```
   If other devices on the subnet respond but `.32`/`.53`/`.60` don't, the problem is isolated to the NUC — it is not present on the LAN at all, which a remote ARP/ping/SSH retry cannot fix.

3. At that point nothing further is diagnosable remotely. The NUC must be checked physically (or via Proxmox console if available another way).

## Root cause observed (2026-06-30)

The NUC was powered off (or had silently dropped off the network — exact trigger wasn't captured). `ping`/ARP swept the rest of the LAN and found other devices responding normally, confirming the outage was isolated to the NUC and its LXCs, not thallium or the Livebox.

**Fix:** physically power-cycle the NUC. Once it finished booting, `gallium`/`adguard`/`neon` all came back within the diagnostic re-test (ARP went `FAILED` → `DELAY`/`STALE` → resolved).

The LXCs' addresses are static, set in Terraform (`ip_config`), so a power cycle cannot change them. Since 2026-10-29 the Livebox DHCP pool is `.100`–`.200`: it cannot hand a homelab address to another device. Static leases cover what sits on the LAN outside the LXCs: gallium (`.32`), thallium wired (`.20`) and the printer (`.29`). Any new device with a fixed address needs one too, or an address outside the pool.

```
192.168.1.x
  .1          Livebox
  .2 – .99    fixed addresses, never handed out by DHCP
                .20  thallium (wired)   .29  printer     .32  gallium
                .53  adguard            .60  neon        .62  pbs
                .63  immich             .64  backup      .65  uptime
                .66  hassium            .68  palladium
  .100 – .200 Livebox DHCP pool: phones, Wi-Fi, guests, IoT
```

## Symptom: no internet on any device while gallium is down

The Livebox hands out AdGuard (`192.168.1.53`) as both primary and secondary DNS, and IPv6 is off, so
AdGuard is the only resolver on the LAN. When gallium is down (power loss, reboot, AdGuard redeploy),
every name lookup fails: devices are still connected, but nothing loads.

Quick check from any device: `ping 1.1.1.1` works while `ping example.com` fails.

**Fallback** (about 2 minutes), only if the outage will last:

1. On the Livebox DHCP page (the one with the primary/secondary DNS fields), set both DNS servers to
   `192.168.1.1` (the Livebox's own resolver) and save.
2. Disconnect and reconnect each device's Wi-Fi (unplug/replug wired ones) so it renews its DHCP lease
   and picks up the new DNS.
3. Internet works again; internal names (`*.lan`, `*.flefevre.fr` services) don't, since only AdGuard
   knows them — and their LXCs are down anyway.

**Revert** once gallium is back: set both DNS servers to `192.168.1.53` again and reconnect the
devices. A device left on the Livebox DNS bypasses the ad filter and cannot resolve internal names.

A router with a DNS forwarder that falls back automatically (AdGuard first, public resolver second)
removes this manual step.

## Related gotchas hit during recovery

- **`gallium` SSH is expected to fail** (`Permission denied (publickey,password)`) even when the host is fully up — no SSH key was ever authorized on the bare PVE host (see `homelab.md`). This is normal, not a sign the host is still down.
- **`vault_gh_admin_token` can be expired/deleted** — per [recovery.md](recovery.md#neon-vault-secrets-lost), this PAT is documented as "used once for deploy key registration; can be deleted after Phase 1." If you re-run `ansible-playbook --tags phase1` later (e.g. after renaming a repo in `deploy_key_repos`), the "List/Register deploy keys" tasks will fail with `401 Unauthorized` if the token was deleted. Either follow the recovery.md procedure to mint a new one, or — faster for a one-off — register the deploy key manually with an already-authenticated `gh` CLI session and resume the playbook with `--start-at-task "Clone <repo> to context repos"` to skip past the GitHub API tasks.
