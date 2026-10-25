---
title: "Backup & Disaster Recovery"
description: "The homelab's 3-2-1 backup architecture for Immich photos, the restore runbook, and the secret-recreation checklist that turns a lost NUC into a 45-minute rebuild."
---

# Backup & Disaster Recovery

How the gallium homelab protects its only irreplaceable data — the Immich photo
library and its database — and how to bring everything back after a failure.

> **Guiding principle: a backup exists to restore DATA. Infrastructure is
> recreated, data is not.** Photos and the Immich database are irreplaceable →
> maximum protection, several independent copies. Everything else (OS, configs,
> secrets) is rebuildable from git + Terraform + Ansible or re-issuable from its
> source → backed up for convenience (fast restore), never as the last line of
> defence.
>
> Corollary: **no lost password or key may ever cost a photo.** Encryption
> protects confidentiality but creates an *availability* risk (lost key =
> unreadable data). For irreplaceable data, availability wins: we stack
> **independent** restore paths, at least one of which depends on no key at all.

---

## Architecture at a glance

Three physical copies of the photos and of Home Assistant's backups, in two+
locations, one off-site — the classic **3-2-1**, plus local ZFS snapshots and
PBS on top.

```
┌────────────────────────────────────────────────────────────┐
│ NVMe 931 GB (rpool) — gallium                               │
│  LXC adguard ─┐                                             │
│  LXC neon ────┤                                             │
│  LXC immich ──┼──→ [PBS LXC 103] ──→ [PBS datastore]        │
│  LXC backup ──┤      incremental, dedup, verify             │
│  LXC uptime ──┤                                             │
│  LXC hassium ─┘                                             │
│                                                             │
│  rpool/data/immich-photos ──┬─ ZFS snapshots (sanoid)       │
│   (photos + DB dumps)        └─ mount RO ──→ [LXC backup]   │
│  rpool/data/hassium-backups ┬─ ZFS snapshots (sanoid)       │
│   (HA backup .tar)           └─ mount RO ──→ [LXC backup]   │
└───────────────────────────────────────────────┬────────────┘
                                                 │ rclone copy (nightly,
                                                 │ from LXC backup only)
              ┌──────────────────────────────────┼──────────────┐
              ▼                                                 ▼
   [Scaleway One Zone]                             [External HDD, always-on]
   SSE-ONE + Object Lock 90d + scoped IAM          PLAINTEXT, bind-mount into
   + lifecycle db-backups/ hassium-backups/ 90d    LXC backup only, --backup-dir
   ├── library/         (photos)                   3rd physical copy
   ├── db-backups/      (DB dumps)
   └── hassium-backups/ (HA backups)
```

### The four layers

| # | Layer | Medium | Encryption | Restores via | Protects against |
|---|---|---|---|---|---|
| 1 | ZFS snapshot | NVMe (local) | none | ZFS rollback | fat-finger delete, in-place corruption |
| 2 | Scaleway Object Storage | off-site | **SSE-ONE** + Object Lock | Scaleway account | fire/theft of the NUC, ransomware |
| 3 | External HDD | local, always-on | **none (plaintext)** | plug it in | everything above, key-free last resort |
| — | PBS | NVMe (local) | native (optional) | PBS UI restore | LXC loss/corruption (infra, not data) |

**Why the HDD is plaintext:** availability beats confidentiality for a
last-resort copy — no lost key can ever brick it. The trade-off is accepted: a
physical theft of the NUC exposes the HDD and the NVMe together. The copy that
*leaves* the house (Scaleway) is encrypted; the copy in clear (HDD) never leaves.
One exception: Home Assistant encrypts its archives itself, before they reach
any copy — restoring them, from the HDD too, needs the emergency-kit key.

**The guarantee:** to lose the photos you would have to lose *simultaneously*
access to the password manager (the only path to the Scaleway account, hence the
only way to delete the account and bypass Object Lock Compliance) **and** the
physical HDD — two independent failures.

---

## Coverage matrix — what is backed up, and where

| Item | Nature | PBS | ZFS snap | Scaleway | HDD |
|---|---|:--:|:--:|:--:|:--:|
| **Immich photos/videos** (`library/`) | **DATA** | ✗¹ | ✓ | ✓ | ✓ |
| **Immich PostgreSQL** (logical dump) | **DATA** | ✓² | ✓ | ✓ | ✓ |
| **Home Assistant** (backup `.tar`: config, `.storage`, recorder DB) | **DATA** | ✗⁴ | ✓ | ✓ | ✓ |
| adguard / neon / uptime OS + config | INFRA | ✓ | ✓ | ✗ | ✗ |
| immich LXC OS (rootfs, incl. live Postgres) | INFRA | ✓ | ✓ | ✗ | ✗ |
| backup LXC OS (rclone/aws creds, crons) | INFRA | ✓ | ✓ | ✗ | ✗ |
| hassium LXC OS (rootfs, incl. live recorder DB) | INFRA | ✓ | ✓ | ✗ | ✗ |
| Config host PVE (bridge, storage, ACL) | INFRA | ✗ | ✗ | ✗ | ✗³ |
| Thumbnails, transcoded video, logs | disposable | ✗ | ✗ | ✗ | ✗ |

¹ Photos live on a separate ZFS dataset (`backup=no` by nature) — deliberately
excluded from PBS, which would otherwise copy 200 GB block-level on every run.
² PBS captures the rootfs (block-level) as a *fallback*. The **logical dump is
the source of truth** — see below.
³ **Not backed up anywhere** — recreated by the manual host-bootstrap runbook.
⁴ On its own dataset (`rpool/data/hassium-backups`), a bind-mount — PBS never
copies those. HA's own scheduled backup (daily 01:30, database included, 7
kept) is the application-consistent copy; PBS still holds the hassium rootfs
as a crash-consistent fallback. See `docs/home-assistant.md`.

**3-2-1 applies to the DATA only.** System-LXC backups are local-only (PBS + ZFS
on the same NVMe) — accepted, because that infra is recreatable from IaC.

---

## Immich: the database is the catch

Photos are files — easy. The database (albums, tags, faces, sharing) is the part
that quietly breaks a restore if you get it wrong.

- **The logical dump is the source of truth.** Immich's built-in *Database
  Backup* writes a `pg_dumpall` to `UPLOAD_LOCATION/backups/`, which sits on the
  photos dataset → it ships with the photos in the same nightly rclone run, so
  DB and files stay consistent to within one run.
- **PBS-rootfs Postgres is a fallback only.** A block-level copy of a live
  Postgres data directory is unreliable (Immich's own docs say so). Never restore
  from it if a logical dump exists.
- **Restore procedure:** follow Immich's official steps — stop the stack, restore
  the DB dump, restore the files, restart. Do **not** point a new Immich at the
  old files without the matching DB.

### Immich ↔ Postgres image pin — update on every upgrade

Immich runs on a **forked Postgres with a vector extension** (`vectorchord` /
`pgvectors`). The image is pinned by digest (never `:latest`). **A DB restore
uses `pg_dumpall` + a fresh Postgres image — if the extension name/version
drifted between the dump and the image you restore into, the restore can fail.**
Keep this table current; bump both rows together, never one alone.

| Immich version | Postgres image (pinned by digest) | Valkey/Redis |
|---|---|---|
| `v3.3.5` (current) | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357…40b1c23` | `docker.io/valkey/valkey:9@sha256:c123e37…08e1d` |
| `v3.0.1` | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357…40b1c23` | `docker.io/valkey/valkey:9@sha256:4963247…966f2d9` |

Source of truth: `ansible/roles/immich/templates/docker-compose.yml.j2` +
`immich.env.j2` (`IMMICH_VERSION`). Verify the extension test explicitly at the
next restore drill (Étape 6).

---

## The backup jobs

All jobs run on the **dedicated `backup` LXC (105)** — never on Immich itself.
The photos and `hassium-backups` datasets are mounted **read-only** there; the HDD and the Scaleway
credentials exist only on this LXC. A compromised Immich (its web/API/ML surface)
therefore has no write path to any backup copy (Scénario 6 isolation).

Managed by the `backup` Ansible role (`ansible/roles/backup/`). Crons
(`/etc/cron.d/`, all as root, each script mails admin on failure via msmtp).
**The backup LXC runs in UTC**: the schedules below are UTC, i.e. one hour later
in Paris in winter (03:00 CET) and two in summer (04:00 CEST). Side effect: the
jobs never run twice or get skipped on a DST change.

| Schedule | Script | What it does |
|---|---|---|
| `02:00` daily | `backup-rclone-scaleway.sh` | `rclone copy` originals → `library/`, DB dumps → `db-backups/` and Home Assistant backups → `hassium-backups/`, all with Object Lock Compliance +90 d. `thumbs/` and `encoded-video/` are **excluded** — regenerable, and their in-place rewrites collide with Object Lock (Forbidden overwrites → locked version pile-up). **Gates on both a DB dump and an HA backup being < 25 h old** before pinging success. |
| `02:20` daily | `backup-rclone-hdd.sh` | `rclone copy` photos and HA backups → HDD, with `--backup-dir /mnt/hdd/.versions/<date>` so an in-place overwrite keeps the old version. **`mountpoint`-guarded** (Scénario 8). |
| `03:00` Sunday | `backup-object-lock-renew.py` | Walks still-present `library/` objects and pushes their `retain-until-date` to now +90 d (sliding retention). `db-backups/` and `hassium-backups/` are deliberately **not** renewed — those age out via the bucket lifecycle. |

Key design points:

- **`rclone copy`, never `sync`** — a copy never deletes on the destination, so a
  local `rm -rf` (accident or ransomware) can't propagate to the cloud.
- **Object Lock Compliance** makes objects immutable even for the account owner —
  the only true ransomware protection. It only allows *extending* retention, so
  the weekly renewal is safe to re-run. A photo deleted in Immich simply stops
  being renewed and becomes deletable ~90 d later.
- **The `mountpoint` guard is not optional.** Without it, a detached HDD would
  make rclone write into the backup LXC's rootfs with no error, and the job would
  ping success while the 3rd copy silently didn't happen.
- **Lifecycle on `db-backups/` and `hassium-backups/` (90 d,
  `scripts/scaleway-lifecycle.json`)** bounds accumulation — `copy` never
  deletes, so timestamped dumps and archives would otherwise pile up forever.
  The bucket is versioned (Object Lock requires it), and on a versioned bucket
  Scaleway's `Expiration` "only deletes the current version": it leaves a delete
  marker and the data stays, billed, as a noncurrent version. Each rule therefore
  also carries `NoncurrentVersionExpiration` (1 day). By then the version's
  Object Lock retention (+90 d from upload, never renewed for these prefixes) has
  run out, so the lock does not block the purge.
- **No lifecycle rule on `library/`, on purpose.** If ransomware encrypts the
  photos and the nightly copy pushes the encrypted files, the good originals
  become noncurrent versions: they are the rollback. A noncurrent-version purge
  there would delete exactly what a restore needs.

---

## Monitoring & alerting

Two independent channels, because "email on error" is blind to a **dead cron**
(it sends nothing when it doesn't run):

- **Uptime Kuma deadman switches** (self-hosted, LXC 106,
  `http://uptime.lan:3001`). Each backup job pushes `?status=up` on success and
  an explicit `?status=down` on failure. A **late push** = a silently-dead cron →
  Kuma flags it even while gallium is otherwise healthy. Three push monitors:
  `rclone-scaleway` (1 d), `rclone-hdd` (1 d), `object-lock-renew` (8 d).
  Self-hosted on purpose: a whole-gallium outage is self-evident (Immich goes
  down), so the residual need is catching a *silent* cron death — no third party
  required.
- **ZED (ZFS Event Daemon)** on the host — mails admin on pool `DEGRADED`,
  checksum errors, or scrub failure. Without it, a disk dying in silence defeats
  all three local layers unnoticed. Plus a monthly `zpool scrub`
  (`zfs-scrub-monthly@rpool.timer`).

> ✅ **Kuma notifications configured (2026-07-10).** A Gmail SMTP channel is
> attached as default-enabled, so a late/failed push notifies `admin@flefevre.fr`.
> Setup details in [uptime-kuma.md](uptime-kuma.md#notifications--how-alerts-actually-leave-the-box).

PBS ships a verify/prune capability; scheduled verify + GC are not yet enabled
(low volume today). A **daily digest email** aggregating PBS/ZFS/Scaleway/HDD
status is designed but deferred.

---

## Cost

Scaleway Object Storage, One Zone, ~200 GB baseline (verified pricing
€0.00803/GB/month):

| Item | €/month |
|---|---|
| Photos live (200 GB) | 1.61 |
| Retained DB dumps (~90 × <1 GB, lifecycle-bounded) | < 0.40 |
| Retained HA backups (~90 × <100 MB, lifecycle-bounded) | < 0.10 |
| **Total** | **~2.00** |
| Full-restore egress (one-shot, 75 GB free then €0.01/GB) | 1.25 |

SSE-ONE is free. One Zone (single-AZ) chosen deliberately: the local HDD already
covers "lost an AZ".

---

## Restore runbook

| # | Scenario | Procedure | Time |
|---|---|---|---|
| 1 | File deleted in an LXC | PBS UI → yesterday's snapshot → Restore. Photo → Immich trash (30 d) else HDD/Scaleway. | ~5 min |
| 2 | LXC lost/corrupted | PBS UI → Restore snapshot. Photos (separate dataset) untouched. | ~10-15 min |
| 3 | PVE OS corrupt, NVMe intact | Reinstall PVE → **host bootstrap runbook** → `zpool import rpool` → LXCs + dataset reappear. | ~30-60 min |
| 4 | The NUC burns (NVMe + HDD gone) | Cloud only — see below. | ~80 min usable, ~7-8 h with photos |
| 5 | Human error on a photo | ZFS rollback (instant) OR Scaleway version OR HDD. Three nets. | seconds-minutes |
| 6 | Stolen rclone key / compromised Immich | Object Lock + scoped IAM + RO/isolated backup LXC hold. Restore from locked versions / HDD. | — |
| 7 | Thallium (control plane) lost | No irreplaceable data on it — recreate the vault + secrets, `terraform import`. See checklist. | ~30-45 min |
| 8 | HDD off/dead at run time | `mountpoint` guard aborts, no false success. Scaleway + ZFS cover the missed night; next run catches up. | auto |

### Scenario 4 — full disaster recovery (the NUC burns)

```
1. New hardware → Proxmox + host bootstrap (bridge, storage)      [40 min]
2. terraform apply → empty LXCs                                   [10 min]
3. ansible-playbook → software                                    [15 min]
4. Recreate secrets (checklist below)                             [15-30 min]
5. rclone copy Scaleway → NVMe: 200 GB @ ~100 Mbps                ≈ 4.4 h
6. Immich re-indexes (thumbnails, ML)                             [30-60 min]
→ Usable without photos: ~80 min · With photos: ~7-8 h
```

SSE-ONE decrypts transparently (key lives with the Scaleway account, not the
password manager).

Home Assistant comes back after step 3: onboarding → restore from backup →
upload the latest `.tar` from `hassium-backups/` (or the HDD) → enter the
emergency-kit key from LastPass.

---

## Secret-recreation checklist (Scénario 7) — the critical artifact

Thallium holds **no irreplaceable data** — only the IaC control plane (vault,
`.vault_pass`, `terraform.tfstate`). Losing it is an *infra* problem. Every
secret below is **re-issuable from its own source** — this is the whole reason
Restic-for-secrets was dropped. Recreate a fresh vault (new password) and
re-enter each value:

| Secret | Recreate from |
|---|---|
| `proxmox_api_token` | Proxmox → Datacenter → Permissions → API Tokens → re-add `terraform@pve!terraform_token`. |
| `root_password` | Reset per LXC via the Proxmox console (`passwd root`). |
| AdGuard admin password (+ bcrypt hash) | Choose a new password, `bcrypt` it into `vault.yml`, re-run playbook. |
| `online_api_key` | Online.net console → API keys (used only for the acme.sh DNS-01 challenge). |
| `vault_smtp_password` | New Gmail App Password (`me@flefevre.fr`). |
| `vault_claude_oauth_token` | `claude setup-token` on a logged-in machine. |
| `vault_gh_admin_token` | GitHub PAT (classic, `repo`) — deploy-key registration only. |
| `vault_multica_pat` | multica.ai → Settings → API tokens. |
| `vault_immich_db_password` | Choose a new one **before first Immich start**; the DB is initialized with it. On restore into an existing dump, it must match the dump's role password. |
| `vault_rclone_scaleway_access_key` / `vault_rclone_scaleway_secret_key` | Scaleway console → IAM → regenerate a **scoped** key on `homelab-photos-backup` (Put/Get/List/PutObjectRetention; deny Delete*/PutBucketVersioning). Distinct from `online_api_key` — different provider account. Kept in **LastPass** ("Scaleway Gallium backup API key"). |
| `vault_kuma_push_rclone_scaleway` / `vault_kuma_push_rclone_hdd` / `vault_kuma_push_object_lock_renew` | Create three Push monitors in the Kuma UI, copy each token into the vault. |
| Immich SMTP app password | New Gmail App Password — entered in the **Immich UI** (Settings → Notifications), stored in the Immich DB, not our IaC. |
| Scaleway bucket-admin creds (`scripts/.scaleway-credentials.env`) | Needed for any **bucket configuration** change — lifecycle rules, bucket policy, the bootstrap script. Must be a key of the bucket policy's `OWNER_PRINCIPAL` (see [Bucket configuration changes](#bucket-configuration-changes)). The scoped `gallium-backup-lxc` key does **not** work here. |
| Home Assistant backup encryption key (emergency kit) | **The exception: NOT re-issuable.** Generated by HA when backups are set up; the only way to open the archives on Scaleway and the HDD. Kept in **LastPass**. A new key only applies to backups made after it. |
| ansible-vault password / `.vault_pass` | New vault password of your choosing (re-encrypts the recreated `vault.yml`). |
| SSH keypair | `~/.ssh/id_ed25519.pub` re-authorized via `terraform.tfvars` + `vars.yml`. |
| adguard→{immich,uptime} cert deploy keys | **Not vault secrets** — regenerated on adguard at deploy time. Re-run `--limit adguard,<host>` once after an adguard rebuild. |

**Two Immich admin accounts must both be recreated** on a full rebuild:
`admin@flefevre.fr` (service/bootstrap) and the daily-use account (admin rights,
to avoid account-switching in maintenance) — intentional, not a bug.

Then: deploy keys are re-registered by Ansible/gh on redeploy; a lost tfstate is
rebuilt with `terraform import` per LXC; `ansible-playbook` reconciles the rest.
**Total ~30-45 min, zero photos lost.**

---

## Host PVE bootstrap (not IaC)

The Proxmox host's own config is **not** captured by Terraform/Ansible and must
be reapplied by hand on scenarios 3 and 4:

- **Network:** bridge `vmbr0` on the physical NIC(s).
- **Storage:** `rpool` ZFS pool (`zpool import rpool` if the disk survived),
  local template store, PBS storage registration (`pvesm add pbs …` — the API
  token ACL must be granted to the full `user!token` authid, privilege-separated).
- **Disable enterprise APT repos** (`pve-enterprise`, `ceph`) → enable
  `pve-no-subscription`, else `apt update` 401s without a subscription.
- **HDD mount:** by UUID at `/mnt/hdd-external`, fstab `nofail`, then
  `chown 100000:100000` so the unprivileged backup LXC's mapped root can write it.
- **root SSH:** re-add your public key via the Proxmox web shell (not provisioned
  by IaC, unlike the LXCs).

---

## Operational reminders

- **`pbs_backup_vmids` is a manual CSV**, not auto-discovery
  (`ansible/playbook.yml`, `hosts: proxmox` play). It is currently
  `100,101,104,105,106,107`. **Add a new LXC's VMID here** when you create one, or
  PBS silently ignores it despite the IaC.
- **On every Immich upgrade:** bump `IMMICH_VERSION` *and* the pinned Postgres
  digest together, and update the mapping table above.
- **Restore drill (Étape 6):** run at least annually (quarterly ideal). Simulate
  "the NUC burns" on a throwaway LXC end-to-end, and **record the measured time
  in the validation log below.**
- **Scaleway billing:** an expired card can suspend the bucket silently — glance
  at it occasionally (same failure family as a dead cron).

### Bucket configuration changes

Scaleway makes a bucket policy **authoritative**: any principal it does not list
is denied, admin keys included. `scripts/scaleway-bucket-policy.json` lists two:

| Principal | Rights | Can change lifecycle / policy? |
|---|---|---|
| `OWNER_PRINCIPAL` (set when the policy was applied) | `s3:*` | yes |
| Backup LXC application — API key `gallium-backup-lxc` | list, get/put objects, get/put retention | **no, by design** |

The scoped key must never be able to rewrite the lifecycle: a compromised backup
LXC could otherwise expire every archive in a day. Measured on 2026-10-24: with
that key, `get-bucket-policy` and `put-bucket-lifecycle-configuration` both
return `AccessDenied`.

To add or change a lifecycle rule, either:

- **Console** (simplest for a one-off): Object Storage → `homelab-photos-backup`
  → *Lifecycle rules*, logged in as the owner. Mirror `scripts/scaleway-lifecycle.json`
  exactly — same rule ID, prefix with its trailing `/`, days — so repo and bucket
  agree. This is how `expire-hassium-backups-90d` was added.
- **CLI**: a key of `OWNER_PRINCIPAL` in `scripts/.scaleway-credentials.env`,
  loaded in a subshell so the credentials do not outlive the command:

  ```bash
  (
    set -a; source scripts/.scaleway-credentials.env; set +a
    aws --endpoint-url https://s3.fr-par.scw.cloud --region fr-par s3api \
      put-bucket-lifecycle-configuration --bucket homelab-photos-backup \
      --lifecycle-configuration file://scripts/scaleway-lifecycle.json
  )
  ```

  Without that file loaded, the AWS CLI falls back to `~/.aws/credentials`
  `[default]` and the call fails with `Forbidden`.

---

## Known limitations

1. **The NUC burning takes the HDD with it** — only Scaleway survives a
   house-level loss. (Max paranoia would add a 2nd offline HDD stored elsewhere.)
2. **Initial seed is bound by upstream bandwidth** — 200 GB can take 10-40 h the
   first time; daily deltas afterwards are tiny.
3. **PBS on the same NVMe is not a 2nd physical copy** — an NVMe failure kills
   live + PBS together. A true 2nd medium only comes after moving the datastore to
   the internal M.2 or a USB disk (Étape 5, triggered when NVMe > 60-70%).
4. **Host PVE config is out of IaC** — manual runbook above.
5. **3-2-1 covers DATA only** — system-LXC backups are local-only by design.

---

## Validation log

**2026-07-10 — full 3-2-1 validated end-to-end** (real, over SSH to `backup.lan`):

- ✅ Photos mount `ro` (runtime write refused) + HDD mounted.
- ✅ rclone → Scaleway: seed OK.
- ✅ Object Lock `COMPLIANCE` applied automatically on upload, retain-until ≈ +90 d.
- ✅ Delete refused with the scoped key: `AccessDenied` (deny via bucket policy,
  *not only* Object Lock) → double lock. Object survives.
- ✅ rclone → HDD with `--backup-dir` ready.
- ✅ Object Lock renewal: retain-until pushed forward.
- ✅ Three Kuma probes receive the `status=up` push.
- ✅ `https://uptime.flefevre.fr` reachable (real Let's Encrypt cert).

Live (Immich NVMe) + Scaleway (off-site, immutable 90 d) + HDD (3rd local copy),
plus ZFS snapshots + PBS. Scénario 6 isolation verified (scoped key ≠ delete).

**2026-10-24 — Home Assistant backups wired in** (PR #31):

- ✅ Dataset `rpool/data/hassium-backups` created, owned `100000:100000`.
- ✅ The 5 existing archives copied from the hassium rootfs, sha256-verified on
  both sides, then removed from the rootfs.
- ✅ Hassium (107) mount `rw`, write test OK; inside the container
  `/mnt/hassium-backups` is mounted over `/config/backups`.
- ✅ Backup LXC (105) mount `ro`: a write fails with `Read-only file system`.
- ✅ Home Assistant lists all 5 archives (database included, encrypted).
- ✅ `rclone copy --dry-run` to `hassium-backups/`: 5 archives, 8.9 MiB.
- ✅ `terraform plan`: no diff on either mount.
- ✅ Lifecycle rule `expire-hassium-backups-90d` added (console, see
  [Bucket configuration changes](#bucket-configuration-changes)).
- ✅ First real nightly run (2026-10-25, 02:00 / 02:20 UTC): the 6 archives are on
  Scaleway `hassium-backups/` and on `/mnt/hdd/hassium-backups`; the three Kuma
  probes are `up`, 0 down overnight; no failure mail. The DST change the same night
  caused no double run (the backup LXC runs in UTC; PBS ran once).
- ⚠️ The Scaleway job logs a burst of `403 Forbidden` every night (20–188 per run
  over the last 9 logs), always recovered by rclone's attempt 2/3 — rc=0, so Kuma
  stays up. Not caused by the HA prefix; under investigation.

**Last full restore drill (Étape 6): _not yet run_** — schedule and record here.
