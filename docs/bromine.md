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

## Network & TLS

**LAN-only, served over HTTPS at `https://bromine.flefevre.fr`.** The extension
runs in a browser secure context (WebExtension page), so Firefox force-upgrades
any plain-HTTP `fetch()` to HTTPS (`upgrade-insecure-requests`) — the backend
*must* answer over TLS even on the LAN. The `bromine.flefevre.fr → 192.168.1.61`
AdGuard rewrite (previously unused) is now the live entrypoint. Use the
`.flefevre.fr` name, **not** `bromine.lan` — the cert only covers the former.

### How TLS is wired (B+D)

- **Caddy** on the bromine LXC terminates TLS on `:443` and reverse-proxies to
  the backend on `127.0.0.1:3000`. The Node app stays plain HTTP bound to
  loopback (`BIND_HOST=127.0.0.1`), so it never holds the TLS key and `:3000`
  can't be hit directly from the LAN to bypass TLS. Caddy's `tls <cert> <key>`
  is explicit → no ACME/DNS plugin in Caddy.
- **The cert is issued on the AdGuard LXC**, not here. AdGuard already runs
  `acme.sh` with the Online.net DNS API key (`online_api_key`) for its own cert;
  the `bromine-cert` role reuses it to issue `bromine.flefevre.fr` (DNS-01,
  EC-256) and **pushes cert+key to bromine over SSH** via acme.sh's ssh
  deploy-hook. Result: the domain-wide Online.net key never lands on bromine.
- **Renewal is automatic**: AdGuard's existing daily `acme.sh --cron` re-runs
  the saved deploy-hook on renewal → re-push + `systemctl restart caddy` on
  bromine. Nothing to schedule on bromine.
- The SSH push targets an unprivileged `certdeploy` user on bromine, locked down
  by a source-restricted (`from=<adguard-ip>`) authorized_key and a sudoers rule
  limited to `systemctl restart caddy`. The TLS key is written `0640` group
  `caddy` — readable by Caddy, **not** by `bromineuser` (the app).

**Internet exposure** remains an option later (e.g. trigger a generation from a
phone off-network) via a Cloudflare Tunnel on this LXC (`apt install cloudflared`
→ `cloudflared tunnel create` → public hostname `bromine.flefevre.fr` →
`http://localhost:3000`). Nothing in the current setup precludes it.

## What's provisioned

- Terraform: `terraform/bromine.tf` (container), `variables.tf` (bromine_vmid/bromine_ip/bromine_lxc_template)
- Ansible: `ansible/roles/bromine-agent/` (bromineuser, Node.js, msmtp, SSH deploy keys, Playwright/Chromium, systemd service, daily report cron, **Caddy + certdeploy**)
- Ansible: `ansible/roles/bromine-cert/` (runs on adguard — issues `bromine.flefevre.fr` via acme.sh DNS-01 and pushes it here over SSH)
- AdGuard DNS rewrites: `bromine.lan` + `bromine.flefevre.fr` → `192.168.1.61`

## Deploy keys

Three GitHub deploy keys are generated on the LXC and registered automatically by the `bromine-agent` role (one per repo, per-repo SSH host alias — see `deploy_key_repos` in `ansible/roles/bromine-agent/defaults/main.yml`):

- `carbon-notes` — **read+write** (the backend commits tailored CV content on "Valider")
- `bismuth-blog` — **read-only** (cloned only to render PDFs via `astro dev` + Playwright)
- `bromine-backend` — **read-only** (it's the code running on the box, not content it reads/writes)

## First-time setup order

1. Create and push the `bromine-backend` repo to GitHub (the Ansible role's git clone task expects it to already exist — see that repo's own README for local dev setup).
2. Fill in the required vault vars (`ansible-vault edit group_vars/all/vault.yml`): `vault_smtp_password`, `vault_gh_admin_token`, `vault_anthropic_api_token`, `vault_google_client_id`, `vault_google_client_secret`, `vault_bromine_allowed_emails`, `vault_bromine_cert_deploy_ssh_key` (private half of the adguard→bromine deploy key — see `docs/recovery.md`). `online_api_key` must already exist (shared with adguard-home).
3. `terraform apply` (provisions the LXC).
4. `ansible-playbook playbook.yml --limit adguard,bromine` — **adguard must be in scope**: the TLS cert is issued there and pushed to bromine. `--limit bromine` alone provisions the app but leaves Caddy without a cert (it won't start).

## Update / maintenance

### Update the backend code (after a merge to `main`)

- **Ansible (recommended, idempotent):** `ansible-playbook playbook.yml --limit bromine`.
  The `git` task (`force: true`) on `/opt/bromine-backend` re-pulls `main`,
  `npm ci` reinstalls, and the `Restart bromine-backend` handler restarts the
  service.
- **Manual hotfix (no playbook):** SSH to bromine as `bromineuser` →
  `cd /opt/bromine-backend && git pull && npm ci`, then
  `sudo systemctl restart bromine-backend`. ⚠️ the next Ansible run will
  `force`-reset any local divergence — push upstream first, never edit in place.
- Verify: `systemctl status bromine-backend` + `curl https://bromine.flefevre.fr/health`.

### TLS certificate renewal

- **Automatic:** AdGuard's daily `acme.sh --cron` renews at ~60 days and re-runs
  the saved ssh deploy-hook → re-push cert+key to bromine + `systemctl restart
  caddy`. Nothing to do.
- **Force / re-push manually** (on **adguard**, as root):
  ```bash
  # re-issue + redeploy:
  HOME=/root /root/.acme.sh/acme.sh --renew -d bromine.flefevre.fr --ecc --force
  # OR just re-push the current cert without re-issuing:
  HOME=/root /root/.acme.sh/acme.sh --deploy -d bromine.flefevre.fr --deploy-hook ssh
  ```
- **Observability:** renewal log on adguard at `/var/log/acme-renewal.log`.
  Check expiry on bromine: `openssl x509 -enddate -noout -in /etc/caddy/cert/cert.pem`.

### Rotate the adguard→bromine deploy key

1. Regenerate: `ssh-keygen -t ed25519 -f bromine-cert-deploy -N "" -C "acme deploy adguard->bromine"`.
2. Private half → `vault_bromine_cert_deploy_ssh_key` (`ansible-vault edit group_vars/all/vault.yml`),
   public half → `bromine_cert_deploy_ssh_pubkey` in `group_vars/all/vars.yml`.
3. Redeploy both hosts: `ansible-playbook playbook.yml --limit adguard,bromine`
   (bromine re-authorizes the new pubkey, adguard reinstalls the new private key).

### Update Caddy / the Caddyfile

Edit `roles/bromine-agent/templates/Caddyfile.j2`, then `ansible-playbook
playbook.yml --limit bromine` (the `Reload caddy` handler reloads it). Caddy
itself updates via `apt upgrade` (official repo).

## Daily report

A cron job (`/etc/cron.d/bromine-daily-report`, 07:30) runs `/opt/bromine-backend/scripts/daily-report.sh`, which emails `admin@flefevre.fr` via `msmtp` (independent SMTP config from neon's — see `ansible/roles/bromine-agent/templates/msmtprc.j2`) with: requests processed, CVs generated, commits made, and any errors from the previous day.
