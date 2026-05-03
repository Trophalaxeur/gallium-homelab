# Proxmox — Terraform Service Account Setup

Create a Terraform service account on Proxmox with a least-privilege custom role, authenticated via API token.

---

## 1. Create the custom role `TerraformProv`

```bash
pveum role add TerraformProv -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Audit VM.PowerMgmt Datastore.AllocateSpace Datastore.Audit"
```

> `VM.Monitor` no longer exists in Proxmox 9 — do not include it.

---

## 2. Create the user

```bash
pveum user add terraform@pve --comment "Terraform service account"
```

No password: this user is API-only.

---

## 3. Assign the role

```bash
pveum acl modify / --user terraform@pve --role TerraformProv
```

---

## 4. Create the API token

```bash
pveum user token add terraform@pve terraform_token --privsep=0
```

> The secret is shown **once only** — store it immediately (LastPass, `.tfvars` gitignored).  
> `--privsep=0`: the token inherits the user's permissions, required by the Terraform provider.

---

## 5. Verify

```bash
pveum acl list | grep terraform
```

Expected output:
```
/ | TerraformProv | user | terraform@pve | 1 |
```

If `PVEAdmin` appears as a leftover, remove it:
```bash
pveum acl delete / --user terraform@pve --roles PVEAdmin
```

---

## 6. Terraform provider configuration

```hcl
provider "proxmox" {
  endpoint  = "https://<PROXMOX_IP>:8006"
  username  = "terraform@pve!terraform_token"
  api_token = "<UUID_SECRET>"
  insecure  = true  # self-signed certificate
}
```

---

## Proxmox 9 roles reference

| Role | Usage |
|---|---|
| `Administrator` | Full access including system management |
| `PVEAdmin` | Admin without system management — too broad for Terraform |
| `TerraformProv` | Custom least-privilege role — recommended |
| `PVEVMAdmin` | VM management only, no datastore access |
