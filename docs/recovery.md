# Secrets Inventory & Recovery Guide

This document lists every secret used in this project, where it lives, and how to recover it if lost.

> Store all secrets in a password manager (e.g. LastPass Secure Note). Never commit `terraform.tfvars` or `vault.yml`.

---

## Secrets inventory

| Secret | Location | Committed |
|---|---|---|
| `proxmox_api_token` | `terraform/terraform.tfvars` | No (gitignored) |
| `root_password` | `terraform/terraform.tfvars` | No (gitignored) |
| AdGuard admin password (plaintext) | Password manager only | No |
| AdGuard admin password hash (bcrypt) | `ansible/group_vars/all/vault.yml` | No (gitignored) |
| `online_api_key` (acme.sh DNS-01) | `ansible/group_vars/all/vault.yml` | No (gitignored) |
| `vault_smtp_password` (Gmail App Password) | `ansible/group_vars/all/vault.yml` | No (gitignored) |
| `vault_claude_oauth_token` | `ansible/group_vars/all/vault.yml` | No (gitignored) |
| `vault_gh_admin_token` (PAT, deploy key registration only) | `ansible/group_vars/all/vault.yml` | No (gitignored) |
| `vault_multica_pat` (Multica cloud API token — Phase 2) | `ansible/group_vars/all/vault.yml` | No (gitignored) |
| ansible-vault password | Password manager only | No |

---

## Recovery procedures

### `proxmox_api_token` lost

Regenerate the token in the Proxmox UI:

1. Datacenter → Permissions → API Tokens
2. Select `terraform@pve!terraform_token` → Remove
3. Re-create: `pveum user token add terraform@pve terraform_token --privsep=0`
4. Copy the new UUID secret → update `terraform/terraform.tfvars`

### `root_password` lost

The same `root_password` is used for all LXCs provisioned by Terraform. Reset it on each affected container directly via the Proxmox console (no SSH needed):

1. Proxmox UI → select the affected LXC → Console
2. Run: `passwd root`
3. Repeat for every LXC that needs the new password.

### AdGuard admin password / vault lost

If `vault.yml` or the ansible-vault password is lost, re-generate everything:

```bash
# 1. Generate a new bcrypt hash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'YOUR_PASSWORD', bcrypt.gensalt(10)).decode())"

# 2. Write the hash into vault.yml (before encrypting)
# ansible/group_vars/all/vault.yml:
#   adguard_admin_password_hash: "$2a$10$..."

# 3. Re-encrypt
ansible-vault encrypt ansible/group_vars/all/vault.yml
```

Then re-run the playbook to apply the new password:

```bash
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml --ask-vault-pass
```

### `online_api_key` lost

Generate a new API key in the Online.net console (Account → API keys) and update `vault.yml` via `ansible-vault edit`. acme.sh will pick it up on the next renewal cron run.

### Neon vault secrets lost

| Secret | How to regenerate |
|---|---|
| `vault_smtp_password` | Generate a new Gmail App Password (`me@flefevre.fr` → Google Account → Security → 2-Step Verification → App passwords). |
| `vault_claude_oauth_token` | Run `claude setup-token` on your local machine where Claude Code is logged in. |
| `vault_gh_admin_token` | GitHub → Settings → Developer settings → PAT (classic) → scope `repo`. Used once for deploy key registration; can be deleted after Phase 1. |
| `vault_multica_pat` | Generate a new API token on multica.ai (Settings → API tokens). Update vault, then `ansible-playbook --tags phase2`. |

### SSH key lost

The public key is always available at `~/.ssh/id_ed25519.pub`. If the private key is lost, generate a new pair:

```bash
ssh-keygen -t ed25519 -C "flefevre@thallium"
```

Then update `ssh_public_key` in `terraform/terraform.tfvars` and re-apply Terraform.

---

## LastPass recommended structure

```
Homelab / terraform.tfvars          ← full file content
Homelab / ansible-vault password    ← vault encryption password
Homelab / AdGuard admin password    ← plaintext password (before hashing)
```

---

## Architecture decision: Multica cloud vs self-host

**Decision (2026-05-18): Multica cloud.**

### Options considered

| | Self-host | Cloud |
|---|---|---|
| Kanban data | On neon LXC (postgres in Docker) | multica.ai |
| UI access | SSH tunnel or reverse proxy required | Direct (any browser, any network) |
| Agent execution | Local on neon | Local on neon (same daemon) |
| Auth flow | Email → 6-digit code → JWT (manual DB injection on first setup) | multica.ai account |
| Ops overhead | Docker, JWT secret, postgres backup, manual setup | API token only |
| Data sovereignty | Full | Kanban content on multica.ai servers |

### Why self-host was tried first

The initial implementation followed the self-host quickstart to avoid any external dependency. However, the setup revealed friction that wasn't worth the trade-off for this use case:

- The Multica UI is bound to `127.0.0.1:3000` by Docker Compose (intentional, not configurable without patching). This forces a permanent SSH tunnel or a reverse proxy just to access the kanban.
- The first-login flow (email → 6-digit code) requires SMTP to be functional from the first run, with no fallback. Any SMTP misconfiguration (wrong credentials, alias vs real account) blocks the entire setup.
- `multica.cli` auth status and JWT management require a working local backend before Phase 2 can run at all.

### Why cloud was chosen

The deciding factor: **neon-agents is a public repository**. The kanban content (tickets, agent comments, skill definitions) contains no information that requires on-premise storage. Data sovereignty is not a concern here.

Cloud eliminates:
- The Docker stack (5 packages, APT repo, 6 Ansible tasks, docker-compose healthcheck)
- The postgres backup cron (nightly pg_dump to `/home/neonuser/.neon/backups/postgres`)
- `vault_multica_jwt_secret` (JWT secret for the self-hosted backend)
- The SSH tunnel requirement for UI access
- The manual first-login workaround via direct Postgres query

What stays identical in both modes:
- `multica daemon start` runs as a systemd service under `neonuser`
- Agent execution is always local — the daemon connects outbound to multica.ai; no inbound port opened
- SMTP is still needed for `context-nightly.sh` failure emails (unrelated to Multica)

### If switching back to self-host

Reverse the changes in `feat/multica-cloud` (PR #4). You will also need to:
1. Restore `vault_multica_jwt_secret` in vault
2. Re-add the Docker stack tasks to phase1
3. Re-add the postgres backup tasks
4. Run `multica setup self-host --server-url http://localhost:8080 --app-url http://localhost:3000` before phase2
5. Set up a reverse proxy or accept SSH tunnel for UI access
