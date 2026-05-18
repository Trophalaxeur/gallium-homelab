# Project instructions

## Naming conventions
- All folder names and unix paths must use kebab-case (e.g. `my-module`, not `MyModule` nor `my_module`).
- Exception: paths dictated by third-party software (e.g. `/opt/AdGuardHome/`) must not be renamed.

## New VM / LXC checklist

Each time a new VM or LXC is added to the homelab, apply these steps before considering it done:

1. **AdGuard DNS rewrites** — add `<hostname>.lan` and `<hostname>.flefevre.fr` pointing to the VM IP in `ansible/roles/adguard-home/templates/adguard-home.yaml.j2`, then redeploy AdGuard (`ansible-playbook playbook.yml --limit adguard`).
2. **inventory.ini** — add the host to the relevant group and to `[homelab:children]`.
3. **Terraform variables** — add `<vm>_ip` and `<vm>_vmid` to `variables.tf` and `terraform.tfvars.example`.
4. **group_vars/all/vars.yml** — add `<vm>_ip` for use in templates.

## New branch / session checklist

Before starting work that touches shared files (playbook.yml, group_vars, inventory.ini, variables.tf):
- Run `git status` first.
- If there are uncommitted changes, ask before including them in the new branch.

## Next steps log
At the end of each response, if the work session produced relevant next steps, update `docs/next-steps.md`.

Each entry must follow this format:
```
## YYYY-MM-DD — <objective>

### Next steps
- ...
```

Prepend new entries at the top of the file. Never overwrite the file — always preserve existing content below the new entry. The file is gitignored and serves as a running working log.
