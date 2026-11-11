# Updating the homelab

How to bring every host and pinned application up to date, in the order that
keeps a rollback possible at each step. Distilled from the 2026-11-11 pass
(PRs #44 and #45). Per-app details stay in each app's doc; this page is the
order of operations and the traps.

## What updates itself, and what doesn't

| Layer | Automatic? | How it is updated |
|---|---|---|
| Debian **security** patches, all 8 LXCs | Yes, daily | `unattended-upgrades` role (`Debian-Security` origins only) |
| Caddy on palladium | Yes, daily | extra origin in the palladium role (internet-facing host) |
| Debian point releases (13.x), all LXCs | No | `apt full-upgrade` — [step 2](#2-lxcs-apt-full-upgrade) |
| gallium (PVE, kernel, ZFS) | No, never | `apt full-upgrade` + reboot — [step 3](#3-gallium-full-upgrade-and-reboot) |
| PBS, Docker CE (neon), NodeSource, Caddy (immich, uptime, hassium) | No | third-party repos: same `apt full-upgrade` |
| Pinned apps (table below) | No | bump in Git, deploy with Ansible — [step 4](#4-pinned-applications) |
| Terraform provider | No | [step 5](#5-terraform-provider) |

Check what `unattended-upgrades` is allowed to touch on a host:
`unattended-upgrade --dry-run -d 2>&1 | grep 'Allowed origins'` — only
`label=Debian-Security` lines (plus `cloudsmith/caddy/stable` on palladium).

## 1. Inventory and pre-flight

1. **Pending OS updates**, per host (`ssh root@<ip>`):
   `apt-get update -qq && apt list --upgradable`. On gallium also `pveversion`;
   on pbs `proxmox-backup-manager versions`.
2. **Pinned versions**: everything lives in `ansible/group_vars/all/vars.yml`
   (plus Immich's Postgres/Valkey digests in
   `ansible/roles/immich/templates/docker-compose.yml.j2`). Compare each with
   its upstream release page (table in [step 4](#4-pinned-applications)) and
   read the release notes of every version skipped, not just the last one.
3. **Fresh backups before anything**. The daily PBS job runs at 02:30; take a
   new one right before the session, on gallium:

   ```bash
   vzdump 100 101 104 105 106 107 --storage pbs --mode snapshot \
     --notes-template "pre-upgrade $(date +%F) {{guestname}}"
   ```

   pbs (103) and palladium (108) are not in the job: both are rebuilt from IaC.
4. **Before any one-way migration** (major HA, Immich or Uptime Kuma bump):
   also check the app's own backup is fresh — see the table.

## 2. LXCs: apt full-upgrade

Non-critical hosts first, **adguard last** (it is the LAN DNS: the others need
it during their own upgrade):

`uptime` → `backup` → `neon` → `pbs` → `immich` → `hassium` → `palladium` → `adguard`

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
```

`--force-confold` keeps Ansible-managed files (e.g. `/etc/caddy/Caddyfile`)
instead of prompting. Ansible re-asserts them on the next run anyway.

No per-LXC reboot needed if gallium is rebooted next (step 3 restarts every
container). Otherwise `pct reboot <vmid>` from gallium picks up libc/systemd.

Avoid backup's job window (02:00–02:40, `/etc/cron.d/backup-jobs`).

## 3. gallium: full-upgrade and reboot

After the LXCs, so everything restarts on a fresh state:

```bash
apt-get update && apt-get full-upgrade      # never `apt upgrade` on Proxmox
proxmox-boot-tool status                    # the new kernel must be listed
systemctl reboot
```

- `grub-probe: error: unknown filesystem` during the upgrade is expected on the
  ZFS root (the ESP is managed by `proxmox-boot-tool`), not a failure.
- Every LXC is `onboot=1`: wait until `pct list` shows all 8 `running`, then
  run the [checks](#6-post-upgrade-checks).
- Downtime: a few minutes for everything (DNS, Home Assistant, Immich).

## 4. Pinned applications

Bump in Git on a branch, then deploy (vault always required):

```bash
cd ansible
ansible-playbook playbook.yml --ask-vault-pass --limit 'homelab:!proxmox' --check --diff
ansible-playbook playbook.yml --ask-vault-pass --limit 'homelab:!proxmox'
```

`--check --diff` is meaningful: read-only probes run under check mode, side
effects (image pulls, `compose up`, cert issuance) are skipped. Narrow
`--limit` to one host for a risky bump. neon needs `--tags phase1` only when
you want to skip phase2.

| Variable(s) | Upstream | Pin | Notes |
|---|---|---|---|
| `adguard_home_version` + `_sha256` | [releases](https://github.com/AdguardTeam/AdGuardHome/releases) | sha256 from `checksums.txt` | [adguard-config.md](adguard-config.md#how-the-binary-is-installed-and-upgraded). A UI self-update is reverted. |
| `acme_sh_version` | [releases](https://github.com/acmesh-official/acme.sh/releases) | git tag | Reinstalled in place, certs and account kept. |
| `immich_version` + compose digests | [releases](https://github.com/immich-app/immich/releases) | tag + Postgres/Valkey digests copied from upstream's compose for that tag | One-way DB migration. [immich.md](immich.md#upgrade-immich), and update the [mapping table](backup.md#immich--postgres-image-pin--update-on-every-upgrade). |
| `homeassistant_version` + `_image_digest` | [releases](https://github.com/home-assistant/core/releases) | index digest | One-way recorder migration: PBS backup of 107 first. Read the release's *backward-incompatible changes*. |
| `ha_mcp_version` + `_image_digest` | [releases](https://github.com/homeassistant-ai/ha-mcp/releases) | index digest | |
| `cozytouch_commit` | [repo](https://github.com/gduteil/cozytouch) | full commit SHA | Tags are older than `main`. Read `release_notes/` (entity renames). Must move past [#206](https://github.com/gduteil/cozytouch/issues/206) before HA 2027.11. |
| `uptime_kuma_version` + `_image_digest` | [Docker Hub](https://hub.docker.com/r/louislam/uptime-kuma/tags) | index digest | Never the `*-rootless` tags. |
| `immich_public_proxy_version` + `_image_digest` | [releases](https://github.com/alangrainger/immich-public-proxy/releases) | index digest | |
| `rclone_version` + `_sha256` | [downloads](https://downloads.rclone.org/) | sha256 from `SHA256SUMS` | After a bump, run `backup-rclone-scaleway.sh` by hand once (S3/Object Lock upload path). |
| `nodejs_major` | [Node releases](https://nodejs.org/en/about/previous-releases) | major line | LTS lines only. |
| `claude_code_version`, `repomix_version` | npm | exact version | Claude Code: the `stable` dist-tag. Installed as root, so it cannot self-update. |
| `multica_version` + `_sha256` | [releases](https://github.com/multica-ai/multica/releases) | sha256 from `checksums.txt` | Then `systemctl restart multica-daemon` on neon (no handler on purpose). |

**Index digest** (one value valid on every architecture):
`docker buildx imagetools inspect <image>:<tag>` (the `Digest:` line), or
`docker pull <image>:<tag>` then
`docker inspect --format '{{index .RepoDigests 0}}' <image>:<tag>`. Always bump
the version and its digest/sha256 in the same commit.

## 5. Terraform provider

The lock file is gitignored, so CI already resolves the newest provider the
`~> x.y` constraint in `terraform/main.tf` allows. Locally:

```bash
cd terraform
terraform init -upgrade
terraform plan        # must say "No changes"
```

A provider upgrade can change how existing state is **read**, not just
written. Any diff after `init -upgrade` is a red flag, never something to
apply blindly: on 2026-11-11 the new provider finally read immich's real
`keyctl=1`, so the plan wanted to turn it *off*. Fix the code to the real
value, re-plan to "No changes", then raise the constraint to that version.

## 6. Post-upgrade checks

- Per LXC: `systemctl --failed` empty, `cat /etc/debian_version`,
  `apt list --upgradable` empty.
- Containers: `docker ps` — all `Up`, `healthy` where a healthcheck exists.
- Apps: `https://photos.flefevre.fr/api/server/version`,
  `https://hassium.flefevre.fr`, `https://uptime.flefevre.fr`, PBS on `:8007`,
  `dig @192.168.1.53 photos.flefevre.fr`.
- Home Assistant log: new `WARNING`s about deprecated APIs from custom
  integrations (they announce the HA version that will break them).
- Uptime Kuma: every monitor green. The backup deadman pushes only arrive after
  the next 02:00 run (or a manual run of the job).

## Known traps

- **`--start-at-task` or skipping a failing task is not a fix.** A task that
  fails on a steady-state run is a role bug; fix the role.
- **An upstream `install.sh` usually installs the latest release**, whatever
  tag the script was fetched from. Pin the release artifact + its checksum.
- **`state: present` never upgrades** an installed package (apt, npm): pin a
  version (`name=pkg=1.2.*`, npm `version:`).
- **A read-only `command` probe needs `check_mode: false`**, or `--check` skips
  it and returns `stdout: ''`, `rc: None` — crashes `from_json`, fails `rc`
  asserts.
- **Debian's stock `unattended-upgrades` config is not security-only**: it also
  allows the stable suite. The role `#clear`s it
  (`51unattended-upgrades-security-only`).
- **The GitHub admin token is single-use** (recovery.md): neon's phase1 only
  needs it when a deploy key is missing; a 401 means a key really is missing.
