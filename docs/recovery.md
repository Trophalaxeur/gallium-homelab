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
| `vault_multica_jwt_secret` | `ansible/group_vars/all/vault.yml` | No (gitignored) |
| `vault_gh_admin_token` (PAT, deploy key registration only) | `ansible/group_vars/all/vault.yml` | No (gitignored) |
| `vault_multica_pat` (added after Manual Setup) | `ansible/group_vars/all/vault.yml` | No (gitignored) |
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
| `vault_smtp_password` | Generate a new Gmail App Password (Google Account → Security → 2-step verification → App passwords). |
| `vault_claude_oauth_token` | Run `claude setup-token` on your local machine where Claude Code is logged in. |
| `vault_multica_jwt_secret` | `openssl rand -hex 32`. ⚠️ Rotating invalidates all active Multica sessions and PATs. |
| `vault_gh_admin_token` | GitHub → Settings → Developer settings → PAT (classic) → scope `repo`. Used once for deploy key registration; can be deleted after Phase 1. |
| `vault_multica_pat` | Generate a new PAT in the Multica UI (Settings → Personal Access Tokens). Update vault, then `ansible-playbook --tags phase2`. |

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
