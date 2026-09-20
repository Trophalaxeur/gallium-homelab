---
title: "Bromine — CV tailoring backend (decommissioned)"
description: "Historical record of LXC 102, the on-demand AI CV tailoring backend, decommissioned on 2026-09-19 after two months without a single request."
---

# Bromine — CV tailoring backend (decommissioned)

> **Decommissioned on 2026-09-19.** LXC 102 no longer exists. Nothing replaces
> it. This page is kept as a historical record — the URL stays valid and the
> service is still referenced from the backup and recovery runbooks.

## What it was

LXC 102 on gallium, hosting `bromine-backend` (`Trophalaxeur/bromine-backend`),
an API consumed by the `bromine-cv-extension` Firefox extension to generate
on-demand, AI-tailored CVs (job-offer or custom-prompt driven). It cloned
`carbon-notes` for the CV source content and `bismuth-blog` to render PDFs
(`astro dev` + Playwright/Chromium), called the Anthropic API for the tailoring
pass, and committed validated results back to `carbon-notes`.

| Parameter | Value |
|---|---|
| Hostname | `bromine.lan` / `bromine.flefevre.fr` |
| IP | `192.168.1.61` (released) |
| VMID | 102 (**retired — not to be reused**, see below) |
| RAM / Disk / vCPU | 1 GB / 5 GB / 2 |
| OS | Debian 13, unprivileged LXC |
| Lifetime | 2026-07-05 → 2026-09-19 |

## Why it was decommissioned

Zero usage. `journald` recorded no `cv/generate` request in the 30 days before
decommissioning, and the last tailored-CV session dated from 2026-07-13 — over
two months of an idle Node.js process, a Caddy instance and a nightly PBS
backup, for a workflow that had quietly moved elsewhere.

## What was removed

- **Infrastructure**: LXC 102 destroyed via `terraform destroy`; AdGuard DNS
  rewrites for `bromine.lan` / `bromine.flefevre.fr` dropped.
- **Code**: `terraform/bromine.tf`, roles `bromine-agent` and `bromine-cert`,
  `group_vars/bromine/`, both plays in `playbook.yml`, and the
  adguard→bromine cert deploy keypair generation.
- **Credentials**: three GitHub deploy keys (`carbon-notes` — the only one with
  write access — `bismuth-blog`, `bromine-backend`), the dedicated Anthropic API
  key, the Google OAuth client, and the four vault entries
  (`vault_anthropic_api_token`, `vault_google_client_id`,
  `vault_google_client_secret`, `vault_bromine_allowed_emails`).
- **TLS**: `bromine.flefevre.fr` removed from acme.sh's renewal list on adguard,
  along with its cert directory and the `bromine-cert-deploy` keypair.
- **Data**: the 10 untracked tailored-CV sessions under `cv/tailored/` on the
  box were deliberately discarded — they were never committed upstream.

## What was deliberately left standing

- The GitHub repos `bromine-backend` and `bromine-cv-extension` — abandoned, not
  deleted.
- The PBS snapshots of vmid 102, including a final `pre-decommission` backup
  taken on 2026-09-19. They expire on their own under the job's `keep-daily=30`
  retention.
- **VMID 102 is retired.** PBS indexes snapshots by vmid, so reusing 102 for a
  future LXC would mix its backups with bromine's archives. The next container
  takes vmid 107. The IP `192.168.1.61` carries no such constraint and is free
  to reuse.

## Recovering the code

The full role, Terraform definition and original documentation are in the git
history:

```bash
git log --diff-filter=D --oneline -- ansible/roles/bromine-agent
git show <sha>^:docs/bromine.md          # the original operational doc
```

## TLS pattern

Bromine was the first service in this homelab to use the "cert issued on
adguard, pushed over SSH to a locked-down `certdeploy` user" pattern. That
mechanism is still in use by Immich and Uptime Kuma — it is now documented in
[immich.md](immich.md#how-tls-is-wired).
