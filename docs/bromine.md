# Bromine — CV tailoring backend

LXC 102 on gallium, hosting `bromine-backend` (`Trophalaxeur/bromine-backend`), the API consumed by the `bromine-cv-extension` Firefox extension to generate on-demand, AI-tailored CVs (job-offer or custom-prompt driven).

## Specs

| Parameter | Value |
|---|---|
| Hostname | `bromine.lan` |
| IP | `192.168.1.61` |
| VMID | 102 |
| RAM | 1 GB |
| Disk | 5 GB |
| vCPU | 2 |
| OS | Debian 13, unprivileged LXC |

⚠️ **Sized for low traffic (~10 requests/week).** A PDF render (`astro dev` + Playwright/Chromium, both spawned fresh per request) peaks around 450–550 MB RAM. If the backend OOMs or swaps under real usage, bump `memory.dedicated` in `terraform/bromine.tf` to `1536` and re-apply. Disk: bismuth-blog `node_modules` (~500 MB) + Chromium (~300 MB) + Astro Content Layer cache (`.astro/`, ~200 MB, must persist between renders — do not wipe the bismuth-blog clone between requests) can get tight on 5 GB; bump `disk.size` to 8 if `df -h` runs low.

## Network exposure

**LAN-only for now.** The extension talks to `http://bromine.lan:3000` from any device on the local network. No port is forwarded, no reverse proxy is configured.

**To expose it on the internet later** (e.g. to trigger CV generation from a phone off-network): set up a Cloudflare Tunnel on this LXC.

```bash
apt install cloudflared
cloudflared tunnel login
cloudflared tunnel create bromine-backend
# Configure a public hostname: bromine.flefevre.fr → http://localhost:3000
cloudflared service install
```

This creates an outbound-only connection to Cloudflare's edge — no port forwarding on the home router, automatic HTTPS. The `bromine.flefevre.fr` DNS rewrite already exists in AdGuard (currently unused, resolves to the LAN IP — update it to point at the tunnel once configured, or rely on Cloudflare's public DNS for that hostname instead).

## What's provisioned

- Terraform: `terraform/bromine.tf` (container), `variables.tf` (bromine_vmid/bromine_ip/bromine_lxc_template)
- Ansible: `ansible/roles/bromine-agent/` (bromineuser, Node.js, msmtp, SSH deploy keys, Playwright/Chromium, systemd service, daily report cron)
- AdGuard DNS rewrites: `bromine.lan` + `bromine.flefevre.fr` → `192.168.1.61`

## Deploy keys

Three GitHub deploy keys are generated on the LXC and registered automatically by the `bromine-agent` role (one per repo, per-repo SSH host alias — see `deploy_key_repos` in `ansible/roles/bromine-agent/defaults/main.yml`):

- `carbon-notes` — **read+write** (the backend commits tailored CV content on "Valider")
- `bismuth-blog` — **read-only** (cloned only to render PDFs via `astro dev` + Playwright)
- `bromine-backend` — **read-only** (it's the code running on the box, not content it reads/writes)

## First-time setup order

1. Create and push the `bromine-backend` repo to GitHub (the Ansible role's git clone task expects it to already exist — see that repo's own README for local dev setup).
2. Fill in the required vault vars (`ansible-vault edit group_vars/all/vault.yml`): `vault_smtp_password`, `vault_gh_admin_token`, `vault_anthropic_api_token`, `vault_google_client_id`, `vault_google_client_secret`, `vault_bromine_allowed_emails`.
3. `terraform apply` (provisions the LXC).
4. `ansible-playbook playbook.yml --limit bromine`.

## Daily report

A cron job (`/etc/cron.d/bromine-daily-report`, 07:30) runs `/opt/bromine-backend/scripts/daily-report.sh`, which emails `admin@flefevre.fr` via `msmtp` (independent SMTP config from neon's — see `ansible/roles/bromine-agent/templates/msmtprc.j2`) with: requests processed, CVs generated, commits made, and any errors from the previous day.
