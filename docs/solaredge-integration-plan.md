---
title: "SolarEdge photovoltaic system — integration plan"
description: "Implementation brief for bringing the SolarEdge SE6000H inverter, its SE-MTR-3Y energy meter and 16 S440 optimisers into Home Assistant: objectives, constraints, evidence gathered so far, current status and phased steps, written without prescribing a technology."
---

This document briefs whoever (human or AI) implements the integration of
the photovoltaic system into Home Assistant. It records **what has to be
achieved**, **what is already known and proven**, and **what is still open**.
It deliberately does **not** choose an integration, protocol, library or
install method. Those choices belong to the implementer. They must be
justified against the objectives and constraints below and recorded in the
final documentation.

Status on 2026-11-11: discovery done, Modbus TCP enabled and verified from a
LAN workstation, nothing deployed. A draft implementation exists (see
[Existing work](#existing-work)). It is a proposal, not a decision.

## How to use this document

1. Read [Constraints](#constraints) first. They come from the repository
   rules (`CLAUDE.md`) and from the existing Home Assistant setup
   (`docs/home-assistant.md`), and they are not negotiable.
2. Re-check every item in [Evidence](#evidence) that your design depends on.
   The values were measured once, from a workstation, at night. Some of them
   change over time (firmware, IP, Wi-Fi), and none were measured from
   the Home Assistant LXC.
3. Work through the [phases](#phases) in order. Each phase ends with a
   **done when** clause. Do not start a phase while the previous one is not
   done, unless the phase says it is independent.
4. Update [Current status](#current-status) as you go. It is the single place
   a later reader looks to know where things stand.

## Objectives

### Functional

| Id | Objective | Priority |
|---|---|---|
| O1 | Real-time PV production (W) visible in Home Assistant | must |
| O2 | Grid import and grid export power (W), in real time | must |
| O3 | Cumulative energy counters suitable for the HA **Energy dashboard**: solar production (kWh), grid import (kWh), grid export (kWh) | must |
| O4 | Home consumption derivable from the above (production + import − export) | must |
| O5 | Inverter state visible (producing / sleeping / fault…), plus enough diagnostic values to spot a problem (AC voltage, frequency, temperature) | should |
| O6 | Data refresh fast enough to drive surplus-based automations later (order of seconds to a minute, not 15 min). The automations themselves are **out of scope** | should |
| O7 | Detection when the data source stops answering (entities unavailable, or a monitored check), so a silent outage does not go unnoticed for days | should |
| O8 | Per-panel (per-optimiser) production for the 16 S440 | could |

### Non-functional

| Id | Objective |
|---|---|
| N1 | **Reproducible**: everything a rebuild needs is described in Git (this repo) or in the private config repo `hassium-automation`, or is explicitly listed as a UI step to redo (`docs/home-assistant.md`, "UI-side choices to redo after a rebuild"). |
| N2 | **Pinned**: any third-party code is pinned to an immutable reference, like every other component in this homelab (images by digest, community integrations by commit SHA). |
| N3 | **Read-only towards the inverter**: no write to inverter or meter registers or settings (power limits, export limits, curtailment, grid code). Reading only. |
| N4 | **No secrets in this repo**: it is public. Credentials, if any are needed, go to the vault. |
| N5 | **Survives restarts** of the inverter, the Wi-Fi, the Livebox and the hassium LXC without manual action. |
| N6 | **Documented**: the final state, choices made and their reasons are written into `docs/home-assistant.md` (or a dedicated doc linked from it). |

### Out of scope

- Automations (surplus routing, load shifting, notifications on production).
- Any change to the inverter's grid, country, power or safety settings.
- Physical electrical work. If the chosen design needs hardware in the
  switchboard, the plan stops and the owner decides.

## Constraints

From `CLAUDE.md`:

- **Nothing runs on the Proxmox host** (`gallium`, 192.168.1.32). Any
  extra service goes into an LXC or VM.
- **Ansible needs the vault.** Every `ansible-playbook` / `ansible-lint` run,
  including `--syntax-check` and `--check --diff`, needs vault access. **Ask
  the owner how to provide it before running any Ansible command.** Never read
  `.vault_pass` or decrypted vault content. Commands handed to the owner always
  carry `--ask-vault-pass` or `--vault-password-file <path>`.
- **kebab-case** for every folder and path this repo creates, except paths
  dictated by third-party software (for example a Python package directory
  name inside `custom_components/`).
- **New VM / LXC checklist** (AdGuard rewrites, inventory, Terraform
  variables, `group_vars`) applies **only if** the design adds a VM or an LXC.
  The inverter itself is a LAN device, not a VM. The repo already gives
  LAN devices an IP variable and AdGuard rewrites: see `printer_ip`.
- `docs/next-steps.md` is a gitignored working log, updated at the end of
  each work session.

From the Home Assistant setup (`docs/home-assistant.md`):

- Home Assistant runs as **HA Container** (no Supervisor, no add-on store) in
  LXC 107 `hassium` (192.168.1.66), Docker Compose, `network_mode: host`.
  HACS is **not** installed.
- HA version pinned in `group_vars/all/vars.yml` (`homeassistant_version`,
  2026.11.1 at the time of writing). Any integration must support it.
- Config ownership is split. YAML lives in the private repo
  `hassium-automation`, deployed by Ansible after `check_config` validation.
  Integrations configured through the UI live in `.storage/`, which is not
  in Git.
- An existing precedent pins a community integration by commit SHA and
  mounts it read-only (Cozytouch, `docs/thermor-allure-4-plan.md`). It is a
  precedent, not an obligation.
- The homelab already runs Uptime Kuma (`docs/uptime-kuma.md`), available
  for O7 if relevant.

From the device (see [Evidence](#evidence)):

- The inverter accepts **a single Modbus TCP client at a time**. This is
  documented SolarEdge behaviour and was not tested here. Any manual test
  while HA is connected will conflict with HA.
- The inverter is on **Wi-Fi**. SolarEdge documents Modbus TCP for Ethernet.
  Over Wi-Fi it is not guaranteed, and stability is unproven.
- **There is no installer access.** The installer is unreachable. Anything
  that needs installer credentials (SetApp installer account, portal admin
  rights granted by the installer) must be obtained some other way, or
  avoided.

## Equipment

Sources: installer quote, photo of the installation, Modbus readout
(E5, E6).

| Item | Value | Source |
|---|---|---|
| Panels | 16 × SolarEdge SPV375-R60JWMG, 375 Wc each (6 kWc), monocrystalline full black | quote |
| Optimisers | 16 × SolarEdge S440, integrated with the panels | quote |
| Inverter | SolarEdge **SE6000H-RW000BEN4**, HD-Wave, **SetApp** model (no LCD, LED bar + `1/0/P` switch underneath), single-phase | photo, E5 |
| Inverter firmware | `0004.0023.0036` | E5 |
| Energy meter | SolarEdge **SE-MTR-3Y-400V-A**, three-phase, configured **Export+Import**, with current clamps, read by the inverter (RS485) | quote, E6 |
| Mounting / protection | K2 Systems structure. Yomatec DC/AC protection box under the inverter: DC and AC emergency cut-off, surge arresters. **Do not touch** | quote, photo |
| Monitoring | SolarEdge cloud monitoring platform. The owner's access level on it is **unknown** | quote |
| Grid meter | Linky, present but not integrated, possible cross-check source | context |

Note: the meter is three-phase and the inverter single-phase, a common
setup. The inverter feeds one phase only. Keep this in mind when
interpreting per-phase meter values.

## Evidence

Each entry: what was observed, how, when. Re-verify before relying on it.

| Id | Date | Observation | Method |
|---|---|---|---|
| E1 | 2026-11-11 | Inverter is on the LAN at **192.168.1.118**, MAC **84:D6:C5:41:15:6A** (OUI SolarEdge), connected through **Wi-Fi**, internet "connecté" | Livebox device list (screenshot) |
| E2 | 2026-11-11 | The blue LED on the inverter is lit. On SetApp models this is the communication LED | photo |
| E3 | 2026-11-11 | Before activation: TCP 1502 → `Connection refused`. TCP 502 → timeout | `nc -zv [-w 3]` from an Arch workstation on the LAN |
| E4 | 2026-11-11 | Modbus TCP enabled **by the owner** through the inverter's local commissioning access (switch on `P` for under 5 s → Wi-Fi hotspot `SEDG-xxxxxxxx` → `http://172.16.0.1`). Afterwards: TCP 1502 → `succeeded` | owner report + `nc -zv 192.168.1.118 1502` |
| E5 | 2026-11-11, night | SunSpec readout, unit id 1, base 40000. `C_SunSpec_ID` = `SunS`. Manufacturer `SolarEdge`. Model `SE6000H-RW000BEN4`. Firmware `0004.0023.0036`. Inverter model id **101** (single-phase). AC power 0 W (raw 0, SF 0). Lifetime energy **20 358 860 Wh** (SF 0) = 20 358.86 kWh. Status **2 = SLEEPING**. AC voltage 230.9 V, frequency 49.997 Hz, heatsink 26.96 °C | read-only Modbus script run from the workstation |
| E6 | 2026-11-11, night | Meter found at base **40121**, meter model id **203** (three-phase wye). Model `SE-MTR-3Y-400V-A`, option Export+Import. Instantaneous power **−902.7 W** (raw −9027, SF −1). Lifetime export **11 216.057 kWh**. Lifetime import **15 975.402 kWh** | same script |
| E7 | 2026-11-11 | Sign convention deduced from E5 + E6: inverter at 0 W at night and meter at −902.7 W, so **negative meter power = import from grid**, positive = export. Consistent with SolarEdge documentation | deduction |
| E8 | 2026-11-11 | Lifetime production of about 20 MWh on a 6 kWc system points to an installation roughly 3 years old, not new. Useful for sanity checks | deduction |

### Register reference (verified subset)

Facts from the SunSpec layout as implemented by SolarEdge. Addresses are
0-based holding registers, unit id 1. Only the rows marked **verified** were
read on this inverter (E5, E6). The others come from SolarEdge's *SunSpec
Implementation Technical Note* and must be checked against it.

| Address | Field | Type | Status |
|---|---|---|---|
| 40000–40001 | `C_SunSpec_ID` ("SunS") | string | verified |
| 40004–40019 | Manufacturer | string(32) | verified |
| 40020–40035 | Model | string(32) | verified |
| 40044–40051 | Version (firmware) | string(16) | verified |
| 40052–40067 | Serial number | string(32) | verified (value not recorded here, public repo) |
| 40069 | Inverter model id (101 = single-phase) | uint16 | verified |
| 40083 / 40084 | AC power / scale factor | int16 / int16 | verified |
| 40085 / 40086 | AC frequency / SF | uint16 / int16 | verified (value) |
| 40093–40094 / 40095 | Lifetime AC energy (Wh) / SF | acc32 / uint16 | verified |
| 40103 / 40106 | Heatsink temperature / SF | int16 / int16 | verified (value) |
| 40107 | Operating state (1 off, 2 sleeping, 3 starting, 4 producing/MPPT, 5 throttled, 6 shutting down, 7 fault, 8 standby) | uint16 | verified (value 2) |
| 40121 | Meter 1 common block | — | verified (present) |
| 40188 | Meter 1 model id (203) | uint16 | verified (value) |

Per-optimiser data is **not** exposed over Modbus.

## Current status

| Area | Status | Notes |
|---|---|---|
| Inverter reachable on LAN | ✅ done | E1 |
| Modbus TCP enabled | ✅ done | E4. May be reset by a firmware update |
| Modbus readout (inverter + meter) | ✅ verified from a workstation | E5, E6 |
| Readout from the hassium LXC | ❌ not tested | Phase 1 |
| DHCP reservation for 192.168.1.118 on the Livebox | ❓ unknown, assume not done | Phase 0 |
| Wi-Fi link stability under continuous polling | ❓ unknown | Phase 5 |
| Owner access to SolarEdge cloud portal (login, admin rights, API key) | ❓ unknown | Only needed if a design or O8 relies on the cloud |
| Integration chosen | ❌ open | Phase 2. See [Existing work](#existing-work) |
| Integration deployed | ❌ not done | |
| Energy dashboard configured | ❌ not done | Phase 4 |
| Outage detection (O7) | ❌ not done | Phase 5 |
| Per-panel data (O8) | ❌ not started | Phase 6 |
| Final documentation | ❌ not done | Phase 7 |

## Existing work

Draft pull request
[Trophalaxeur/gallium-homelab#46](https://github.com/Trophalaxeur/gallium-homelab/pull/46),
**not merged, not deployed**. It contains one possible implementation:

- `solaredge_ip` in `group_vars/all/vars.yml`, and AdGuard rewrites
  `solaredge.lan` and `solaredge.flefevre.fr`.
- A community integration pinned by commit SHA, checked out by the
  `home-assistant` role and bind-mounted read-only, following the Cozytouch
  precedent.
- A "SolarEdge inverter" section in `docs/home-assistant.md`.

It was written before this plan and did not go through Phase 2's evaluation.
The implementer may adopt it, amend it or discard it. Whatever is
chosen, it must meet the objectives below. If it is discarded, revert the
parts that do not apply (IP variable and DNS rewrites are useful whatever
the integration).

## Phases

### Phase 0 — prerequisites (owner, no code)

- The owner reserves 192.168.1.118 for MAC `84:D6:C5:41:15:6A` in the
  Livebox DHCP settings.
- The owner says how vault access is provided for Ansible runs.
- The owner says whether they can log in to the SolarEdge monitoring portal,
  and with which rights (viewer or admin, API access available or not). This
  only matters if Phase 2 or Phase 6 considers a cloud source.

**Done when:** the IP is reserved (owner confirmation), the vault method is
known, and the portal access level is recorded in Current status.

### Phase 1 — reachability from the Home Assistant host

The workstation could read Modbus. That says nothing yet about `hassium`.

- From the hassium LXC, check that TCP 192.168.1.118:1502 answers, and that a
  read-only SunSpec read returns `SunS` at 40000. Remember the single-client
  rule: nothing else may be connected during the test.
- Check that the hassium LXC can download whatever the chosen solution
  needs at runtime (for example Python packages fetched by Home Assistant on
  first load), or plan for it.
- If a name is used instead of the IP, check that it resolves from hassium.

**Done when:** a read from hassium returns the values of E5 (model, firmware)
and a lifetime energy ≥ 20 358.86 kWh.

### Phase 2 — choose the integration path

Evaluate the options against the objectives, then write the decision and its
reasons down. Criteria to cover, at minimum:

| Criterion | Linked to |
|---|---|
| Covers inverter **and** meter (O1–O4), ideally in one place | O1–O4 |
| Exposes energy counters with the attributes the Energy dashboard needs (`device_class: energy`, `state_class: total_increasing` or `total`, unit kWh/Wh) | O3 |
| Refresh interval | O6 |
| Local or cloud, and what happens when the internet or the vendor cloud is down | N5, O6 |
| Read-only by default, and whether write features can be left disabled | N3 |
| Compatible with HA Container without Supervisor or HACS, and with the pinned HA version | Constraints |
| Can be pinned to an immutable reference and deployed reproducibly | N1, N2 |
| Maintenance health: recent releases, open issues, user base, support for this inverter model and firmware | risk |
| Needs credentials? Where they would be stored | N4 |
| Behaviour with the single-client Modbus limit (reconnects, holds the connection, recovers) | N5 |

Known solution space, **non-exhaustive and unranked**. Verify each fact
before using it.

- Core Home Assistant integrations related to SolarEdge (cloud monitoring
  API, Modbus-based ones), and the generic core `modbus` integration with
  hand-written sensors.
- Community integrations dedicated to SolarEdge over Modbus TCP.
- Community integrations scraping the SolarEdge portal (the only known path
  to per-optimiser data, relevant to O8).
- Independent measurement that does not depend on the inverter at all
  (Linky TIC interface, clamp meters). It needs hardware and possibly
  electrical work, which is out of scope without the owner's decision.

**Done when:** the decision, the rejected alternatives and the reasons are
written in the final documentation draft, and the owner has agreed.

### Phase 3 — implement and deploy

- Implement the chosen path in this repo and/or `hassium-automation`,
  respecting the constraints (pinning, no secrets, kebab-case, vault).
- Give the inverter a stable name or variable, following the repo's
  conventions for LAN devices (see `printer_ip`).
- If DNS rewrites are added, redeploy AdGuard. Redeploy hassium. Each
  command handed to the owner carries the vault option.
- Any UI-only configuration step is written down so a rebuild can redo it
  (N1).

**Done when:** Home Assistant shows inverter and meter entities with live
values, and the readings match the [validation values](#validation).

### Phase 4 — Energy dashboard

- Configure the Energy dashboard: solar production, grid consumption
  (import), return to grid (export).
- Check the sign convention (E7). Import must count as consumption and export
  as return, not the other way round.
- Decide where this configuration lives: UI/`.storage`, or YAML. Record the
  decision.

**Done when:** after a sunny day, the dashboard shows production, import
and export for that day, and daily production + import − export gives a
plausible home consumption. The counter deltas must match the inverter
and meter lifetime counters over the same period, within rounding.

### Phase 5 — robustness

- Observe the link for at least 48 h, including one night (inverter
  `SLEEPING`) and one morning start-up. Record disconnections.
- If disconnections are frequent, report it to the owner with evidence.
  Wiring the inverter by Ethernet is a physical change and the owner's
  decision.
- Make outages visible (O7): entities going `unavailable`, an external
  check, or both.
- Write down how to recover after a firmware update disables Modbus TCP
  (the procedure of E4).

**Done when:** 48 h of data with no unexplained gaps (or gaps documented),
and an outage of the source is visible without opening HA's logs.

### Phase 6 — per-panel data (optional, O8)

Independent of Phases 3–5 and only if the owner wants it. The only known
source is the SolarEdge cloud portal, so it needs the owner's portal access
(Phase 0). Evaluate it like Phase 2, with extra weight on fragility
(unofficial scraping) and on credential storage (vault).

**Done when:** 16 per-optimiser power or energy values appear in HA, and
their sum is consistent with the inverter's DC/AC production. Alternatively,
the owner decides not to do it, and that is recorded.

### Phase 7 — documentation and close-out

- Update `docs/home-assistant.md`: the device table row for the solar
  inverter, plus a section with the final design, its reasons, the UI steps,
  the recovery procedure and the known limits.
- Update this plan's [Current status](#current-status). Then either mark the
  plan complete, or delete it once its content lives in the main doc.
- Update `docs/next-steps.md` (working log).

**Done when:** a reader who never saw this conversation can rebuild the
integration from the repo and the docs alone.

## Validation

Reference values for sanity checks. The counters only grow, so later
readings must be **greater than or equal to** these.

| Quantity | Reference (2026-11-11, night) | Check |
|---|---|---|
| Inverter lifetime energy | 20 358.86 kWh | ≥ reference, increases only while producing |
| Meter lifetime export | 11 216.057 kWh | ≥ reference |
| Meter lifetime import | 15 975.402 kWh | ≥ reference |
| Inverter AC power | 0 W at night | > 0 W in daylight, ≤ about 6 000 W |
| Inverter status | 2 (sleeping) at night | 4 (producing) in daylight |
| AC voltage | 230.9 V | 207–253 V |
| Frequency | 49.997 Hz | about 50 Hz |
| Meter power at night | −902.7 W | negative = import while the inverter is off |

Daytime cross-check: with the inverter producing, meter power ≈ inverter
power − home consumption. Positive means export.

## Risks and pitfalls

| Risk | Effect | Mitigation to consider |
|---|---|---|
| Two Modbus clients at once (manual test + HA, or two integrations) | One gets refused or kicked, and data drops out | One client only. Stop HA's source before manual tests |
| Firmware update resets Modbus TCP | All entities unavailable | O7 detection, plus the documented re-enable procedure (E4) |
| Wi-Fi instability | Gaps, reconnect loops | Phase 5 observation. Ethernet is the owner's decision |
| IP change | Integration loses the inverter | Phase 0 DHCP reservation |
| A write feature enabled by mistake (power control, export limit) | Production curtailed, possibly non-compliant with grid rules | N3. Keep writes disabled and say so in the docs |
| Changing settings in the commissioning UI beyond Modbus TCP | Inverter off-grid or non-compliant | Only the Communication menu is ever touched |
| Sign convention inverted | Energy dashboard swaps import and export | Phase 4 check against E7 |
| Unofficial cloud scraping breaks (O8) | Per-panel data disappears | Treat as optional. Isolate it from O1–O4 |
| Recorder migration or HA upgrade breaks the integration | Loss of data source | Pin. Check compatibility before an HA bump |
| Serial numbers or credentials committed | Leak in a public repo | N4. Values like the serial number stay out of Git |
