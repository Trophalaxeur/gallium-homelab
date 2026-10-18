---
title: "Home Assistant — home automation"
description: "LXC 107 running Home Assistant Container (no Supervisor) behind Caddy, why the Container install type was chosen over HA OS on a Proxmox homelab, and the ownership split between Git and the Home Assistant UI."
---

Home Assistant runs in LXC 107 (`homeassistant.lan` / `192.168.1.66`), served over
TLS at `homeassistant.flefevre.fr`. Same runtime shape as the rest of the
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

| Owned by Git (Ansible templates) | Owned by Home Assistant |
|---|---|
| `configuration.yaml` | `/config/.storage/*.json` |
| `automations-managed.yaml` | integrations, entity registry, areas, dashboards |

Integrations are stored in `/config/.storage/core.config_entries` as internal
JSON that must not be hand-edited. Adding Overkiz or a solar inverter is a UI
step by design — there is nothing to template.

Automations are Git-owned, enforced structurally rather than by convention.
`configuration.yaml` declares a **labeled** include:

```yaml
automation ansible: !include automations-managed.yaml
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
namespace. That is also why `trusted_proxies` is `127.0.0.1` rather than a
Docker subnet.

## Backups — read this before trusting them

The LXC is listed in `pbs_backup_vmids`, so PBS snapshots it nightly at 02:30.
**That is not sufficient on its own.** A `mode: snapshot` run copies the
recorder SQLite database while HA is writing to it; WAL usually replays cleanly
on restore, but that is a likelihood and not a guarantee.

The application-consistent layer is Home Assistant's own scheduled backup,
which must be enabled **once, manually**, in Settings → System → Backups. Its
tarballs are written to the LXC rootfs and are therefore swept up by the same
PBS run, giving a consistent restore point inside a crash-consistent image.

Until that is done, the only copy is the crash-consistent snapshot.

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

What differs with Container is file access: `/config` is a plain directory on
the LXC, editable over SSH or, better, templated from this repo. On HA OS the
same thing requires going through an SSH or Samba app.

## Deploying

```bash
terraform apply
ansible-playbook playbook.yml --limit adguard              # DNS rewrites + cert deploy keypair
ansible-playbook playbook.yml --limit adguard,homeassistant
```

The certificate play runs *on* AdGuard and pushes to this host, so `adguard`
must stay in scope — `--limit homeassistant` alone silently skips it.

Caddy is enabled but not started by the role: it refuses to start while
`/etc/caddy/cert/*.pem` are absent. The `home-assistant-cert` role's deploy
hook restarts it right after landing the certificate.

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
