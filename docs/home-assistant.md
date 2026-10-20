---
title: "Home Assistant — home automation"
description: "LXC 107 running Home Assistant Container (no Supervisor) behind Caddy, why the Container install type was chosen over HA OS on a Proxmox homelab, and the ownership split between Git and the Home Assistant UI."
---

Home Assistant runs in LXC 107 (`hassium.lan` / `192.168.1.66`), served over
TLS at `hassium.flefevre.fr`. Same runtime shape as the rest of the
homelab: Docker Compose inside an unprivileged LXC, Caddy in front, certificate
issued on the AdGuard LXC and pushed over SSH.

## Why HA Container and not HA OS

Home Assistant ships four install types. Two matter in practice:

| | Supervisor / apps | What it is |
|---|---|---|
| **HA OS** | yes | A dedicated appliance OS. Officially recommended; roughly 80% of installs. |
| **HA Container** | no | A plain Docker image on a host you maintain. Roughly 18% of installs. |

HA OS brings the Supervisor, which adds an app store (Mosquitto, Zigbee2MQTT,
ESPHome, evcc), **Ingress** — apps embedded in the HA sidebar behind HA's own
authentication — and one-click updates. It is also an opaque appliance: no SSH,
no package manager, nothing that Ansible can describe.

Container was chosen because every device targeted in phase 1 speaks IP and
none of them needs the Supervisor:

| Device | Path | Needs an app? |
|---|---|---|
| Thermor Allure 4 towel rail | Overkiz integration (**cloud only** — no Atlantic/Thermor gateway appears in Overkiz's local-API list) | no |
| Shelly plugs and switches | local integration, no cloud account | no |
| Solar inverter | local API or Modbus TCP over the LAN | no |
| Wallbox / EV | local API or vendor cloud | no |

The two real costs of Container are priced and accepted:

- **No Ingress.** Companion services get their own port and their own
  authentication instead of appearing in the sidebar. This homelab already has
  the Caddy + acme.sh pattern that solves exactly that, so the marginal cost is
  close to zero.
- **Matter and Thread are hard.** Running the Matter Server as a standalone
  container is explicitly unsupported upstream, and Thread additionally needs
  IPv6 forwarding in a kernel this unprivileged LXC does not control. No
  current device uses Matter. If that changes, a third-party Thread border
  router (HomePod, Nest Hub) removes the hardest half, and migrating to HA OS
  costs roughly half a day and no money: restore an HA backup during onboarding
  (supported from every install type) and copy Zigbee2MQTT's `data/` directory
  so the Zigbee network survives without re-pairing.

Choosing a **network** Zigbee coordinator over a USB dongle removes the last
piece of hardware coupling and makes that migration trivial.

## Ownership split

This is the part that surprises people: **most of Home Assistant's
configuration is not YAML**, on any install type.

| Owned by Git — private config repo | Owned by Home Assistant |
|---|---|
| `configuration.yaml` | `/config/.storage/*.json` |
| `automations-managed.yaml` | integrations, entity registry, areas, dashboards |
| | HTTP server settings — reverse proxy, IP ban, listen addresses (since 2026.8) |

Integrations are stored in `/config/.storage/core.config_entries` as internal
JSON that must not be hand-edited. Adding Overkiz or a solar inverter is a UI
step by design — there is nothing to version.

The HTTP server settings went the same way in Home Assistant 2026.8: they now
live in Settings → System → Network, and the configuration ships no `http:`
block. See [Network settings](#network-settings--one-time-after-the-first-deploy).

### Two repositories: how Home Assistant is installed, and what it does

This repository is public and only describes **how** Home Assistant is
installed: Terraform, Docker Compose, Caddy, certificates, the validation
gate. **What** Home Assistant does — `configuration.yaml`, the automations —
lives in a private repository, `hassium-automation`, because it
describes how the home is used: presence, absences, schedules.

The root of that private repository **is** Home Assistant's `/config`. That
makes it independent of the install type:

- **HA Container (current)** — clone it next to this repository. The role reads
  it from `homeassistant_config_repo_dir` on the control node and copies only the
  files listed in `homeassistant_config_files`.
- **HA OS (if the install type ever changes)** — the official *Git pull* app
  clones the same repository straight into `/config`. It has no sub-folder
  option, which is why the configuration sits at the repository root.

Guard rails in the role:

- **Missing repository → the play stops.** Carrying on would look successful
  while replacing the live configuration with nothing.
- **`internal_url` must match `homeassistant_domain`.** The domain lives in two
  places by design: `group_vars` (Caddy, certificate, DNS rewrite) and the
  private `configuration.yaml`, which must stay plain YAML for HA OS. The role
  refuses to deploy when they disagree.
- **Copied, never templated.** Home Assistant automations carry their own Jinja
  (`{{ trigger.to_state.state }}`, `{{ states('sensor.x') }}`). Through Ansible's
  template engine they would be rendered by Ansible instead, and the play fails
  on `'trigger' is undefined` (measured).
- Files are deployed with mode `0600` and go through the `check_config` gate.

Automations are Git-owned, enforced structurally rather than by convention.
`configuration.yaml` declares a **labeled** include:

```yaml
automation git: !include automations-managed.yaml
```

The HA UI automation editor only ever writes to an *unlabeled* `automation:`
include. There is none, so the editor cannot overwrite the repo — and creating
an automation from the UI fails. That is deliberate. Adding
`automation ui: !include automations.yaml` restores UI editing; the two keys
coexist as long as their labels differ.

## Networking

The container runs with `network_mode: host`. This is mandatory, not a
shortcut:

- HA discovers devices through mDNS and SSDP broadcasts, which do not cross a
  Docker bridge network.
- Shelly generation 1 devices push CoIoT to **UDP 5683**. Upstream
  documentation is explicit that on non-HA-OS installs this port must reach the
  HA service.

The consequence is that no `ports:` mapping is possible — HA binds 8123 on the
LXC itself, and Caddy reverse-proxies to `127.0.0.1:8123` from the same network
namespace. That is also why the trusted proxy (set in the UI, see below) is
`127.0.0.1` rather than a Docker subnet.

## Backups — read this before trusting them

The LXC is listed in `pbs_backup_vmids`, so PBS snapshots its rootfs nightly
at 02:30. **That is not sufficient on its own.** A `mode: snapshot` run copies
the recorder SQLite database while HA is writing to it; WAL usually replays
cleanly on restore, but that is a likelihood and not a guarantee. And PBS
stays on gallium's NVMe: it does not survive the NUC.

The application-consistent layer is Home Assistant's own scheduled backup,
enabled **once, manually**, in Settings → System → Backups: daily at 01:30,
database included, 7 kept, location *This system*, encrypted. HA writes it
to `/config/backups`, which is not the rootfs but the
`rpool/data/hassium-backups` ZFS dataset — the Immich photos pattern:

- bind-mounted read-write here (`terraform/hassium.tf`, mounted over
  `/config/backups` by `docker-compose.yml.j2`), so the archives survive a
  rebuild of this LXC;
- snapshotted by sanoid, like every dataset under `rpool/data`;
- bind-mounted **read-only** into the backup LXC (105), which copies it
  nightly to Scaleway (`hassium-backups/`, Object Lock and lifecycle 90 days)
  and to the external HDD. That job fails — Kuma down, mail — when no
  archive is younger than 25 hours, so a backup schedule that silently stops
  does not go unnoticed. See `docs/backup.md`.

**The encryption key is the one thing that cannot be recreated.** Without the
emergency kit (LastPass), every off-site copy is unreadable.

To restore, onboarding offers *restore from backup*: upload a `.tar`, enter
the key. Supported on Container since 2025.1 — not yet exercised here.

### One-time setup of the backups dataset

The scoped Terraform token cannot create bind-mounts (API 403, root@pam
only), so the two mounts are posted by hand, as for the photos:

```bash
ansible-playbook playbook.yml --limit proxmox   # creates the dataset
# on the Proxmox root console:
pct set 107 -mp0 /rpool/data/hassium-backups,mp=/mnt/hassium-backups,backup=0
pct set 105 -mp2 /rpool/data/hassium-backups,mp=/mnt/hassium-backups,ro=1,backup=0
pct reboot 107 && pct reboot 105
terraform plan                                  # expect no diff on either mount
ansible-playbook playbook.yml --limit adguard,hassium,backup
```

The `home-assistant` role refuses to deploy while the mount is missing:
Docker would otherwise create an empty directory on the rootfs, and the
archives would land outside the dataset that leaves the house.

`recorder.purge_keep_days` is set to 14 explicitly. Long-term statistics — the
hourly aggregates behind the Energy dashboard — live in a separate table that
purging never touches, so shortening the detailed history does not cost solar
or consumption history.

## Driving it from a terminal

Three paths, all of them independent of the install type because they are HTTP:

- **REST API** at `/api/` with a long-lived access token: `states`, `services`,
  `config/core/check_config`, `template`, `history`, `logbook`, `error_log`.
- **MCP Server** — a core integration since release 2025.2, implementing
  Streamable HTTP at `/api/mcp`. It exposes only the entities explicitly shared
  with it through the Assist API, so it controls devices but cannot create
  automations or add integrations.
- **`hass-cli`** (`pipx install homeassistant-cli`) — maintained, though
  development is mostly dependency upkeep. The Arch AUR package lags; prefer
  PyPI.

### ha-mcp — the path Claude Code uses

The core MCP Server cannot remove an integration or read a device's live
configuration, so Claude Code goes through
[ha-mcp](https://github.com/homeassistant-ai/ha-mcp) instead: a community MCP
server with admin reach (integrations, automations, registries, live states).
It runs as a sidecar container in this LXC's compose, pinned by version and
digest in `group_vars` (`ha_mcp_version`, `ha_mcp_image_digest`).

```
Claude Code ──HTTPS──▶ Caddy :443 ──/<secret>*──▶ 127.0.0.1:8086 ha-mcp
                              └──── anything else ──▶ 127.0.0.1:8123 HA
ha-mcp ──HTTPS https://hassium.flefevre.fr──▶ Caddy ──▶ HA
```

- **The secret path is the only credential.** `ha-mcp-web` has no other auth:
  whoever knows `https://hassium.flefevre.fr/<secret>` drives HA as an admin.
  It is published on loopback only; Caddy, over TLS, is the only way in.
- **ha-mcp reaches HA through Caddy, never `127.0.0.1:8123`** — see
  [IP ban](#ip-ban--measured-behaviour): a stale token from `127.0.0.1` would
  ban Caddy and lock everyone out. Through Caddy, a ban hits only the sidecar's
  bridge IP. The LXC does not resolve `hassium.flefevre.fr` (Livebox DNS), so
  the compose pins it with `extra_hosts`.
- **Where the secret path lives on hassium**: `/etc/caddy/Caddyfile`,
  `/opt/home-assistant/ha-mcp.env`, and ha-mcp's container log — uvicorn's
  access log prints the request path on every MCP call, and `LOG_LEVEL` does not
  govern it. All three are root-only, the same trust boundary as the HA token
  in `ha-mcp.env`; the log is rotated (5 MB × 2). Caddy gets no access log, to
  avoid a fourth copy.
- **Reading ha-mcp's log**: mask on the host, before it reaches a terminal or a
  transcript:
  `docker logs ha-mcp 2>&1 | sed "s#$(sed -n 's#^MCP_SECRET_PATH=/##p' /opt/home-assistant/ha-mcp.env)#<SECRET>#g"`

Prerequisites, once:

1. A dedicated Home Assistant user `claude` — Administrator, *local network
   only* — and a long-lived token created from its own profile (Security tab).
   Never your own login: revoking it must not lock you out.
2. Two vault entries (`ansible-vault edit group_vars/all/vault.yml`):
   `vault_ha_mcp_ha_token` (that token) and `vault_ha_mcp_secret_path`
   (`openssl rand -hex 24`, no leading slash).

Registering the client on thallium, after the deploy:

```bash
read -s "HA_MCP_PATH?Secret path: "
claude mcp add --transport http --scope user home-assistant \
  "https://hassium.flefevre.fr/$HA_MCP_PATH"
unset HA_MCP_PATH
```

Appending `/readonly` to the URL gives a connection where write tools are
hidden and blocked — same secret, restricted mode.

Rotation: change `vault_ha_mcp_secret_path` and redeploy (Caddy and ha-mcp pick
it up together), then re-run `claude mcp add`. For the HA side, delete the
token in the `claude` user's profile, or deactivate the user.

What differs with Container is file access: `/config` is a plain directory on
the LXC, readable and editable over SSH — but the Git-owned files are
overwritten by the next deploy from `hassium-automation`. On HA OS the same
access requires going through an SSH or Samba app.

## Deploying

```bash
terraform apply
ansible-playbook playbook.yml --limit adguard              # DNS rewrites + cert deploy keypair
ansible-playbook playbook.yml --limit adguard,hassium
```

The certificate play runs *on* AdGuard and pushes to this host, so `adguard`
must stay in scope — `--limit hassium` alone silently skips it.

On a fresh LXC, the backups bind-mount must exist before the `hassium`
play — see [One-time setup of the backups dataset](#one-time-setup-of-the-backups-dataset).

Caddy is enabled but not started by the role: it refuses to start while
`/etc/caddy/cert/*.pem` are absent. The `home-assistant-cert` role's deploy
hook restarts it right after landing the certificate.

The deploy is not finished at this point: the HTTPS URL answers **400** until
the network settings below exist.

## Network settings — one-time, after the first deploy

Home Assistant 2026.8 moved the HTTP server settings from `configuration.yaml`
to the UI. Measured on the pinned 2026.10.2: an `http:` block still works, but
is imported as unconfirmed *pending* settings and raises a
`http/deprecated_yaml` repair issue. The configuration therefore ships none, and
these settings are set by hand once — like onboarding or backups.

On a fresh install, Home Assistant does not trust Caddy yet: every request
through `https://hassium.flefevre.fr` gets **HTTP 400** (measured). Do
the onboarding at `http://192.168.1.66:8123`, then the two steps below, in
Settings → System → Network.

Saving these settings restarts Home Assistant, and **an administrator must
confirm them within 5 minutes, or Home Assistant reverts to the previous
ones**. That is what makes each step below safe to try.

**Step 1 — trust the proxy.** Keep *Listen addresses* empty for now.

| Setting | Value |
|---|---|
| Trust X-Forwarded-For | on |
| Trusted proxies | `127.0.0.1` |
| IP ban | on |
| Login attempts threshold | `5` |

Save, confirm, then check that `https://hassium.flefevre.fr` loads.
Only `127.0.0.1` is trusted because it is Caddy's upstream: a request carrying
`X-Forwarded-For` from an unlisted source such as `::1` gets 400 (measured).

**Step 2 — no plaintext on the LAN.** Set *Listen addresses* to `127.0.0.1`.
After the restart, the `http://192.168.1.66:8123` tab stops answering — that is
the point. **Confirm from the HTTPS URL**, within 5 minutes; if you don't, Home
Assistant reverts and the IP answers again. Caddy then becomes the only way in.
The one known casualty is battery-powered Shelly gen2, whose websocket targets
HA's IP directly; none are deployed.

### IP ban — measured behaviour

On 2026.10.2: after 5 failed attempts, the 6th request gets 403 and the client
is written to `/config/ip_bans.yaml`. A request with an **invalid bearer
token counts as a failed attempt**. Behind Caddy, the ban is keyed on the
`X-Forwarded-For` client address, not on Caddy. Bans never expire.

- To unban, delete the entry from `/config/ip_bans.yaml` **and restart** Home
  Assistant — deleting the line alone is not enough.
- Never authenticate against Home Assistant from the LXC itself
  (`127.0.0.1`, no `X-Forwarded-For`): a local script with a stale token would
  ban `127.0.0.1` — that is, Caddy, and therefore everyone.

### Name resolution on the LAN

The Livebox hands DHCP clients `192.168.1.53` (AdGuard), then `1.1.1.1`
(measured on thallium's wlan0 lease). `hassium.flefevre.fr` exists only
as an AdGuard rewrite, with no public record, so a client that falls back to
`1.1.1.1` cannot resolve it — expect occasional failures from phones. The LXCs
themselves do not use AdGuard at all: they resolve through the Livebox.

## Compliance with the official Container install

Checked against [the official Container instructions](https://www.home-assistant.io/installation/linux/)
on 2026-10-19.

| Official requirement | Here |
|---|---|
| Docker Engine 23.0.0 or later, not Docker Desktop | `docker.io` 26.1.5 from Debian trixie |
| Official image `ghcr.io/home-assistant/home-assistant` | Same image, pinned `version@digest` instead of `:stable` |
| `/config`, `/etc/localtime:ro`, `network_mode: host`, `TZ`, `restart: unless-stopped` | Identical |
| `stop_grace_period: 60s` | Identical — see the comment in `docker-compose.yml.j2` for the measured shutdown chain |
| Update with `pull` then `up -d`; restart with `docker compose restart` | What the role and its handler do |

Two keys of the official compose are left out on purpose:

- **`privileged: true`** appears in the official examples but is never listed
  as a prerequisite. It grants every host device and every capability. When a
  device is needed, the documented alternative is a targeted `devices:`
  mapping.
- **`/run/dbus:/run/dbus:ro`** is described as optional, needed only for the
  Bluetooth integration. This LXC has no Bluetooth adapter; Bluetooth goes
  through an ESPHome proxy instead.

**Grey zone — Docker inside an LXC.** The documentation neither allows nor
forbids it. [ADR 0012](https://github.com/home-assistant/architecture/blob/master/adr/0012-define-supported-installation-method.md)
defines "supported" as *tested and documented*, which this nesting is not.
Home Assistant's own code still classifies the install as
**Home Assistant Container**, the supported type: in 2026.10.2 the condition is
`user == "root" and is_official_image()`, the latter checking for
`/OFFICIAL_IMAGE` inside the image.

That same condition rules out a tempting hardening: **never add a non-root
`user:` to the service.** The install would then report itself as
*Unsupported Third Party Container*.

**First-boot check.** Dropping `privileged` was measured on a plain Docker
host, not inside this LXC. After the first start, look for errors from the
discovery integrations that `default_config` loads:

```bash
ssh root@hassium.lan \
  'cd /opt/home-assistant && docker compose logs homeassistant' \
  | grep -E 'ERROR|WARNING' | grep -iE 'usb|bluetooth|dhcp'
```

Bluetooth reporting a missing adapter or D-Bus is expected here. Errors from
`usb` or `dhcp` are not — they would point at the missing privileged mode.

## Roadmap

- **Phase 1** (this document): Home Assistant alone. No Mosquitto, no
  Zigbee2MQTT, no evcc, no radio dongle — nothing a phase-1 device needs.
- **Phase 2**: Mosquitto + Zigbee2MQTT as additional services in the same
  Compose file, with a network Zigbee coordinator, when a Linky TIC reader
  (ZLinky) or a pilot-wire module arrives. Zigbee2MQTT ships **no
  authentication by default** and `network_mode: host` would expose its
  frontend on the LAN — that needs handling before it goes up. Note that the
  NodOn pilot-wire module is incompatible with ZHA, so Zigbee2MQTT is the
  required driver, not a preference.
- **Phase 3**: evcc for solar-surplus EV charging, plus the `ha-evcc`
  integration from HACS.

The Linky TIC reader needs **standard mode**, which has to be requested from
the electricity supplier and is the longest lead time in the project. Grid
injection is only reported in standard mode, so historical mode would lose the
single most useful measurement for a solar setup.
