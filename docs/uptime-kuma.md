---
title: "Uptime Kuma — monitoring & deadman switch"
description: "LXC 106 running self-hosted Uptime Kuma — heartbeat (push) monitors that catch a silently-dead backup cron, plus active service probes, served over TLS at uptime.flefevre.fr."
---

# Uptime Kuma — monitoring & deadman switch

LXC 106 on gallium, running [Uptime Kuma](https://github.com/louislam/uptime-kuma)
(Docker Compose). It is the homelab's **deadman switch**: each backup job pushes a
heartbeat on success, and Kuma alerts when a push is *late* — catching a
**silently-dead cron** that "email on error" can never detect (a job that doesn't
run sends nothing). It doubles as an active prober for the homelab services.

**Why self-hosted, not healthchecks.io** (decision 2026-07-08): a whole-gallium
outage is already self-evident — Immich goes down, you notice. The residual need
is catching a *silent* cron death while gallium is otherwise healthy, plus a test
bench for services. Kuma does heartbeat **and** active probes, with zero
third-party dependency. It lives in the LAN it watches (an LXC, not on the PVE
host — CLAUDE.md rule).

> ⚠️ **Trade-off, by design:** because Kuma runs on the same box it monitors, a
> total gallium/LAN death takes Kuma with it — it cannot alert on its own demise.
> That case is covered by being self-evident (Immich down). Kuma's job is the
> *silent partial* failure: gallium alive, one cron dead.

## Specs

| Parameter | Value |
|---|---|
| Hostname | `uptime.lan` (internal), `uptime.flefevre.fr` (dashboard) |
| IP | `192.168.1.65` |
| VMID | 106 |
| RAM | 1 GB |
| Disk | 8 GB (rootfs + Docker image + Kuma's SQLite data) |
| vCPU | 1 |
| OS | Debian 13, unprivileged LXC, `nesting=1` (Docker) |
| Version | `louislam/uptime-kuma:1.23.16` (pinned) |

Light footprint (Node + SQLite) — same class as adguard. Config + history live in
`/opt/uptime-kuma/data` on the rootfs → covered by PBS with the container. No
dedicated dataset, no bind-mount, so **no root@pam console step** (unlike
immich/backup).

## Network & TLS

Two entry points, on purpose:

- **`http://uptime.lan:3001`** — plain HTTP, LAN-only. **This is what the backup
  jobs push to** (`…/api/push/<token>`). No TLS needed machine-to-machine on the
  LAN, and `:3001` stays open deliberately.
- **`https://uptime.flefevre.fr`** — the **human dashboard**, fronted by Caddy
  with a real Let's Encrypt cert. Resolves internally only (AdGuard rewrites
  `uptime.lan` + `uptime.flefevre.fr` → `.65`); **never port-forwarded**.

### How TLS is wired

Identical mechanism to [immich](immich.md#how-tls-is-wired) and
[bromine](bromine.md): Caddy on this LXC terminates TLS on `:443`
and reverse-proxies to the Kuma container on `127.0.0.1:3001` (WebSocket/socket.io
handled transparently). The cert is issued on the **AdGuard LXC** (acme.sh,
DNS-01) and pushed here over SSH to a locked-down `certdeploy` user; the
Online.net key never lands here. Renewal is automatic via adguard's daily cron.
**Re-run `--limit adguard,uptime` once after an adguard rebuild** to re-sync the
deploy key.

## Monitors

Three **push monitors** back the backup chain — Kuma expects a ping within the
heartbeat window; a late ping flips the monitor to **DOWN**:

| Monitor | Pushed by | Heartbeat | Job schedule |
|---|---|---|---|
| `rclone-scaleway` | `backup-rclone-scaleway.sh` | ~1 day | 02:00 daily |
| `rclone-hdd` | `backup-rclone-hdd.sh` | ~1 day | 02:20 daily |
| `object-lock-renew` | `backup-object-lock-renew.sh` | ~8 days | 03:00 Sunday |

Each job pushes `?status=up` on success and an explicit `?status=down` on
failure (immediate alert, on top of the late-heartbeat safety net). The push
tokens are stored in the vault (`vault_kuma_push_rclone_scaleway`,
`vault_kuma_push_rclone_hdd`, `vault_kuma_push_object_lock_renew`) and rendered
into the job scripts by the
`backup` role — see [backup.md](backup.md#the-backup-jobs).

**Optional active probes** (not yet created): HTTP checks on
`https://photos.flefevre.fr/api/server/ping`, AdGuard, and PBS would give live
service status alongside the heartbeats.

## Notifications — how alerts actually leave the box

> ✅ **Configured (2026-07-10).** A **Gmail SMTP** channel ("Notif Gmail
> flefevre.fr") is attached as **default-enabled**, so all three monitors — and
> any future one — notify `admin@flefevre.fr` on DOWN. The steps below document
> how it was set up and how to add a second channel (e.g. Telegram).

Uptime Kuma has no notifications out of the box — you create a notification
*channel*, then attach it to each monitor. Two channels fit this homelab:

### Option A — Email/SMTP (recommended: reuses existing infra)

Consistent with everything else: `admin@flefevre.fr` already receives ZED and
backup-failure mail via msmtp. Kuma sends its own SMTP directly (outbound to
Gmail — works even though Kuma is LAN-only).

1. Generate a **dedicated Gmail App Password** (`me@flefevre.fr` → Google Account
   → Security → 2-Step Verification → App passwords). Same pattern as the neon /
   bromine / Immich SMTP secrets — don't reuse another service's password.
2. Kuma → **Settings → Notifications → Setup Notification**:
   - Type: **Email (SMTP)**
   - Hostname `smtp.gmail.com`, Port `587`, Security **STARTTLS** (or `465` /
     TLS)
   - Username `me@flefevre.fr`, Password = the app password
   - From `uptime@flefevre.fr`, To `admin@flefevre.fr`
3. **Test** → **Save**.

### Option B — Telegram (push to phone, independent channel)

Better if you want a "wake me up" alert on your phone, off-network, independent
of the mail pipeline:

1. Message **@BotFather** → `/newbot` → copy the **bot token**.
2. Message your new bot once, then open
   `https://api.telegram.org/bot<token>/getUpdates` and read `result[].message.chat.id`
   (or ask **@userinfobot**).
3. Kuma → Settings → Notifications → Setup Notification → Type **Telegram** →
   paste Bot Token + Chat ID → **Test** → **Save**.

### Attach it (the step that was missing)

Creating the channel is not enough — it must be wired to the monitors:

- **Fastest:** while creating the notification, tick **"Default enabled"** and
  **"Apply on all existing monitors"** → it attaches to all three at once and to
  any future monitor.
- **Per-monitor:** edit each monitor → **Notifications** section → toggle the
  channel on.

Also review, per push monitor: **Retries** and **"Resend Notification if Down X
times consecutively"** so a single missed heartbeat alerts rather than sits
silent. Then verify end-to-end: let a monitor go past its heartbeat window (or
temporarily disable a cron) and confirm the alert actually arrives.

## What's provisioned

- Terraform: `terraform/uptime.tf` (container), `variables.tf`
  (`uptime_vmid`/`uptime_ip`/`uptime_lxc_template`)
- Ansible role `uptime-kuma`: Docker, the Kuma compose stack, Caddy + `certdeploy`
- Ansible role `uptime-cert` (runs on **adguard**): issues `uptime.flefevre.fr`
  via acme.sh DNS-01 and pushes it here over SSH
- PBS: VMID 106 in `pbs_backup_vmids`
- AdGuard DNS rewrites: `uptime.lan` + `uptime.flefevre.fr` → `192.168.1.65`

## First-time setup order

1. `online_api_key` must already exist in the vault (shared with adguard). No
   Kuma-specific vault secret is needed *before* first boot — the push tokens are
   generated *by* Kuma (below).
2. `terraform apply` — provisions the LXC (no console step; no bind-mount).
3. `ansible-playbook playbook.yml --limit adguard,uptime` — **adguard must be in
   scope** (cert issued there and pushed here). `--limit uptime` alone leaves
   Caddy without a cert (dashboard won't come up), but Kuma on `:3001` still runs.
4. First visit `http://uptime.lan:3001` (or the HTTPS dashboard): create the admin
   account.
5. Create the **three push monitors** → copy each generated token into the vault
   (`vault_kuma_push_*`) → `ansible-playbook --limit backup` so the job scripts
   pick them up.
6. **Set up a notification channel and attach it** (see above) — otherwise the
   whole thing is decorative.

## Update / maintenance

- **Upgrade Kuma:** bump `uptime_kuma_version` in group_vars (check the latest
  `1.x` patch tag on [Docker Hub](https://hub.docker.com/r/louislam/uptime-kuma/tags)
  first — pinned, never `:latest`), then `ansible-playbook playbook.yml --limit
  uptime` (pulls + `docker compose up -d`). History/config persist in
  `/opt/uptime-kuma/data`.
- **TLS renewal:** automatic (adguard's daily cron); same as
  [immich](immich.md#tls-certificate-renewal).
- **Backup:** the SQLite data is on the rootfs → captured by the daily PBS job.
  Fully recreatable otherwise (monitors + notification are quick to re-add).
