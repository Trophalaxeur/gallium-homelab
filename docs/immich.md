---
title: "Immich — self-hosted photos"
description: "LXC 104 running Immich (Docker Compose, ML enabled) — the homelab's photo/video library, served over TLS at photos.flefevre.fr, with its photos on a dedicated ZFS dataset."
---

# Immich — self-hosted photos

LXC 104 on gallium, running [Immich](https://immich.app) as a Docker Compose
stack (server + machine-learning + PostgreSQL + Valkey). It is the homelab's
photo/video library — the **only irreplaceable data** on the box — served over
HTTPS at `https://photos.flefevre.fr`, publicly reachable.

Its photos live on a **separate ZFS dataset**, not the container rootfs, so they
get their own backup treatment (ZFS snapshots + off-site rclone). See
[backup.md](backup.md) for the full 3-2-1 story — this page covers the service
itself.

## Specs

| Parameter | Value |
|---|---|
| Hostname | `immich.lan` (internal), `photos.flefevre.fr` (public) |
| IP | `192.168.1.63` |
| VMID | 104 |
| RAM | 6 GB |
| Disk | 20 GB (rootfs + Docker images — **photos are elsewhere**) |
| vCPU | 4 |
| OS | Debian 13, unprivileged LXC, `nesting=1` (Docker) |

**Sized for ML.** Immich runs full machine learning (face recognition + CLIP
smart search) — deliberately not throttled. 4 vCPU / 6 GB is generous for a
homelab library; the
initial import indexes everything and will use the CPU hard for a while.
Verified 2026-07-06: gallium has 30 GiB RAM / 21 GiB free before this LXC, so
6 GB dedicated fits with room to spare.

## Storage architecture — photos are not on the rootfs

This is the non-obvious part. The 20 GB disk holds only the OS + Docker images.
The actual photos + Immich's DB dumps live on a **dedicated ZFS dataset**
(`rpool/data/immich-photos`) bind-mounted at `/mnt/immich-photos`:

- **Why separate:** PBS backs up the rootfs block-level. If the photos were on
  it, PBS would re-copy 200 GB every night. The dataset is `backup=false`
  (excluded from PBS) and protected instead by sanoid snapshots + rclone to
  Scaleway/HDD — the right tools for a large, append-mostly store.
- **The bind-mount is a manual step.** The scoped Terraform token
  (`terraform@pve!terraform_token`, not `root@pam`) **cannot** create a `bind`
  mount point — the Proxmox API returns 403. It was set once via the root
  console (`pct set 104 -mp0 …`) and then *declared* in `terraform/immich.tf` so
  Terraform stops trying to destroy it. **If this LXC is ever rebuilt from
  scratch, redo it by hand** — the full procedure is in the comments of
  `terraform/immich.tf`.
- **A mountpoint guard protects the data.** The Ansible role refuses to deploy if
  `/mnt/immich-photos` isn't actually a mount (`mountpoint -q`). Without it, a
  missing bind-mount would make Docker write photos silently into the rootfs —
  unprotected, and swept into PBS. Same failure class as the HDD rclone job's
  guard (Scénario 8 in [backup.md](backup.md)).

```
rpool/data/
├── subvol-104-disk-0   ← LXC OS: 20 GB (PBS)
└── immich-photos       ← photos + DB dumps: ~200 GB (backup=no; sanoid + rclone)
     ├── library/       ← originals
     └── backups/       ← pg_dumpall dumps (source of truth for a DB restore)
```

## Network & TLS

**Publicly exposed at `https://photos.flefevre.fr`** — unlike the LAN-only
services, this one is reachable from the internet:

- **Public path:** `photos.flefevre.fr` is registered at Online.net → resolves to
  the home WAN IP; the Livebox 6 Pro forwards `:443` → `192.168.1.63`. Verified
  reachable from an external exit point (`{"res":"pong"}` on
  `/api/server/ping`, no hairpin NAT).
- **Internal path:** AdGuard rewrites both `immich.lan` and `photos.flefevre.fr`
  → `192.168.1.63`, so LAN clients hit it directly (no hairpin). `immich.lan`
  stays the internal/technical name; the cert only covers `photos.flefevre.fr`.

### How TLS is wired

Identical mechanism to [bromine](bromine.md) and [uptime-kuma](uptime-kuma.md):

- **Caddy** on this LXC terminates TLS on `:443` and reverse-proxies to the
  Immich server container, published on `127.0.0.1:2283` (loopback only, so
  `:2283` can't be hit directly from the LAN to bypass TLS). Caddy's
  `tls <cert> <key>` is explicit → no ACME plugin in Caddy.
- **The cert is issued on the AdGuard LXC**, not here. AdGuard's `acme.sh` (with
  the Online.net DNS key) issues `photos.flefevre.fr` (DNS-01, EC-256) and
  **pushes cert+key over SSH** to a locked-down `certdeploy` user here. The
  domain-wide Online.net key never lands on immich.
- **Renewal is automatic:** AdGuard's daily `acme.sh --cron` re-runs the saved
  deploy-hook → re-push + `systemctl restart caddy`. Nothing scheduled here.
- Because the deploy keypair is generated on adguard, **re-run
  `--limit adguard,immich` once after an adguard rebuild** to re-sync it.

## Docker stack & pinned versions

The compose file (`ansible/roles/immich/templates/docker-compose.yml.j2`) is the
official Immich stack, with **every image pinned** (never `:latest`/`release`):

| Service | Image |
|---|---|
| immich-server | `ghcr.io/immich-app/immich-server:${IMMICH_VERSION}` |
| immich-machine-learning | `ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION}` |
| database | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357…` |
| redis | `docker.io/valkey/valkey:9@sha256:4963247…` |

`IMMICH_VERSION` is set in `.env` (currently `v3.0.1`, from `immich_version` in
group_vars). **The Postgres image is a fork with a vector extension** — a DB
restore into a mismatched extension version can fail, so the
[Immich ↔ Postgres mapping table in backup.md](backup.md#immich--postgres-image-pin--update-on-every-upgrade)
must be updated on **every** Immich upgrade.

## What's provisioned

- Terraform: `terraform/immich.tf` (container + ZFS bind-mount declaration),
  `variables.tf` (`immich_vmid`/`immich_ip`/`immich_lxc_template`)
- Ansible role `immich`: Docker, the compose stack, the mountpoint guard, Caddy +
  `certdeploy` (TLS reverse proxy)
- Ansible role `immich-cert` (runs on **adguard**): issues `photos.flefevre.fr`
  via acme.sh DNS-01 and pushes it here over SSH
- Ansible play "Provision ZFS dataset for Immich photos" (`hosts: proxmox`):
  creates `rpool/data/immich-photos` and chowns it to the LXC's mapped root
- Ansible play "Register PBS storage and daily backup job": VMID 104 is in
  `pbs_backup_vmids` (rootfs only — photos excluded)
- AdGuard DNS rewrites: `immich.lan` + `photos.flefevre.fr` → `192.168.1.63`

## First-time setup order

1. Fill the vault (`ansible-vault edit group_vars/all/vault.yml`):
   `vault_immich_db_password`. `online_api_key` must already exist (shared with
   adguard). The adguard→immich cert deploy key is generated automatically on
   adguard — no vault entry.
2. `terraform apply` — provisions the LXC. **The bind-mount will fail (403)** on a
   from-scratch create → follow the console procedure in `terraform/immich.tf`
   (comment out the `mount_point`, apply, `pct set … -mp0 …` by hand, uncomment,
   re-apply).
3. `ansible-playbook playbook.yml --limit adguard,immich` — **adguard must be in
   scope**: the TLS cert is issued there and pushed to immich. `--limit immich`
   alone leaves Caddy without a cert (it won't start).
4. **First web visit** (`https://photos.flefevre.fr`): create the admin account —
   strong password, no default. Then the manual settings below.

### Manual, one-time settings (not in IaC — stored in the Immich DB)

- **Enable Database Backup** (Admin → Settings → Backup) — writes `pg_dumpall` to
  `UPLOAD_LOCATION/backups`, the source of truth for a DB restore. **Without it,
  the DB is not backed up off-site**, only the unreliable PBS-rootfs copy.
- **SMTP** (Admin → Settings → Notifications → Email) — a dedicated Gmail App
  Password, entered by hand. Lives in the Immich DB, not our vault.
- **Two admin accounts are intentional**: `admin@flefevre.fr` (service/bootstrap)
  + a daily-use account with admin rights. **Both must be recreated** on a full
  rebuild — noted in the [secret-recreation checklist](backup.md#secret-recreation-checklist-scénario-7--the-critical-artifact).

## Update / maintenance

### Bulk import from Google Photos

Migrating a full Google Photos library in is a one-shot runtime operation, not part
of the IaC. The reproducible procedure — single-pass `immich-go` import staged on the
ZFS dataset and pulled from Google Drive via rclone, with the metadata/duplicate
pitfalls — lives in
[immich-google-photos-import.md](immich-google-photos-import.md).

### Upgrade Immich

1. Check the [Immich release notes](https://github.com/immich-app/immich/releases)
   for breaking changes and read the **upstream compose diff** for that tag.
2. Bump `immich_version` in group_vars **and** the pinned Postgres/Valkey digests
   in `docker-compose.yml.j2` **together** — copy them verbatim from upstream's
   compose for that exact version. Never bump one without the other.
3. Update the [mapping table in backup.md](backup.md#immich--postgres-image-pin--update-on-every-upgrade).
4. `ansible-playbook playbook.yml --limit immich` (pulls new images,
   `docker compose up -d` recreates changed containers).
5. Verify: `docker compose ps` (all `healthy`) + `curl https://photos.flefevre.fr/api/server/ping`.

### TLS certificate renewal

Automatic (adguard's daily cron). To force a re-issue/re-push, run on **adguard**:
`HOME=/root /root/.acme.sh/acme.sh --renew -d photos.flefevre.fr --ecc --force`.
Same mechanics as [bromine's cert](bromine.md#tls-certificate-renewal).

### Restore

Follow Immich's official restore procedure (stop stack → restore DB dump →
restore files → restart). The [backup.md runbook](backup.md#restore-runbook)
frames it in the homelab's scenarios.

## Security notes

- **No native 2FA/TOTP.** Immich has no built-in second factor, and this instance
  is internet-facing (`photos.flefevre.fr`). Hardening path = an external OAuth
  IdP (Authentik/Authelia) in front. Tracked as Multica ticket **MEN-13** — still
  open.
- No rate-limiting / WAF / fail2ban in front of the login today — password
  strength is the only gate. Consider before treating public exposure as
  permanent.
