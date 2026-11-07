---
title: "Thermor Allure 4 — integration plan"
description: "Step-by-step plan to bring the Thermor Allure 4 towel rail (LPOM TD1W) into Home Assistant through the community Cozytouch integration, pinned by Ansible, with a Git-owned dashboard and a boost button."
---

Plan for the bathroom towel rail. Status: **not started**. Each phase ends
with an explicit *done when* so it can be ticked off on its own. Automations
are out of scope here, deliberately.

## The device

| Label field | Value | What it tells |
|---|---|---|
| Nom / Code | ALLURE 4 / 483271 | Thermor Allure 4, 750 W, left-hand, carbon finish |
| Type | `LPOM TD1W` | `TD1` = Atlantic product type for towel dryers (productId 53); `W` = built-in Wi-Fi |
| N° | 2517 0108 | Built 2025, week 17 |

## Decisions already taken

**Integration: [gduteil/cozytouch](https://github.com/gduteil/cozytouch), not
Overkiz.** Atlantic runs two clouds behind the Cozytouch brand. The
Wi-Fi-native devices (no Cozytouch bridge) live on the *Magellan* API
(`apis.groupe-atlantic.com`), which the core Overkiz integration does not
cover. The community integration talks to that API and maps `TD1` to a
towel rack: climate entity, room temperature, presets (boost included when
the device reports capability 100505), override (*dérogation*), weekly
program as a calendar, plus its own schedule card. Cloud only: there is no
local API, and Thermor says so publicly.

**Installation: pinned by Ansible, not HACS (recommended).** Everything in
this homelab is pinned by version and digest (`homeassistant_image`,
`ha_mcp_image`). HACS would be the one component that updates itself from
the UI, outside Git, and it needs a GitHub device login on top. The
integration has no Python requirements (`"requirements": []` in its
manifest), so the simplest pinned install is a `git` checkout at a commit SHA,
bind-mounted **read-only** into the container.

| | Option A — Ansible + bind-mount (recommended) | Option B — HACS |
|---|---|---|
| Pinning | Commit SHA in `group_vars`, reviewed in a PR | Whatever HACS installs; updates from the UI |
| Rebuild | Reproduced by the play | HACS itself must be reinstalled, then the repo re-added |
| Updates | Bump the SHA, redeploy | One click, with update notifications |
| Extra moving parts | `git` on the LXC | HACS + GitHub device auth + its own `.storage` |
| Fits the "Git owns how HA is installed" rule | yes | no |

Option B is documented in [an appendix](#appendix--option-b-hacs) in case
other community integrations pile up later and HACS becomes worth it.

## Phase 0 — prerequisites (15 min)

1. **The device works in the official app.** Thermor/Cozytouch app, towel rail
   paired, reachable from outside the home Wi-Fi (switch the phone to 4G and
   change the setpoint). The integration uses the **same account**:
   email + password, no MFA support.
2. **Home Assistant is recent enough.** `hacs.json` requires ≥ 2025.12.0;
   `homeassistant_version` is `2026.10.2`. OK.
3. **hassium reaches Atlantic's cloud.**
   ```bash
   ssh root@hassium.lan 'curl -sS -o /dev/null -w "%{http_code}\n" https://apis.groupe-atlantic.com/'
   ```
   Any HTTP code (even 404) is fine; a timeout or DNS error is not.
4. **Choose the version to pin.** On 2026-11-07 the repository has:

   | Ref | Commit | Notes |
   |---|---|---|
   | tag `1.4` | `0a91651` | Last stable. One config entry per device, no calendar or schedule card |
   | tag `2026.10.1b1` | `617c905` | Beta of the new CalVer line |
   | `main` | `1cdec93` | `manifest.json` says `2026.10.0`; untagged |

   Recommendation: take the newest **non-beta** CalVer tag if one exists by then;
   otherwise `2026.10.1b1`, the oldest ref that has the schedule card, the
   calendar and the single account entry. Avoid `1.4`: its config entry
   format is migrated by later versions (`migrate_1_4.py`), so starting there
   means doing a migration for nothing. Pin the **full** 40-character SHA (for an
   annotated tag, the commit it points to: `git ls-remote <url> 'refs/tags/<tag>^{}'`).

*Done when*: app works off-LAN, curl answers, SHA chosen.

## Phase 1 — install the integration (Option A)

All changes are in this public repository.

### 1.1 `group_vars/all/vars.yml`

Next to `homeassistant_version`:

```yaml
# Community Cozytouch integration (Atlantic Magellan API) — Thermor Allure 4
# towel rail. Pinned by full commit SHA: content-addressed, unlike a tag or a
# GitHub tarball. Bump = new SHA + redeploy. See docs/thermor-allure-4-plan.md.
cozytouch_repo: "https://github.com/gduteil/cozytouch.git"
cozytouch_version: "2026.10.1b1"          # for humans only
cozytouch_commit: "<full 40-char SHA>"
```

### 1.2 `roles/home-assistant/defaults/main.yml`

```yaml
# Pinned community integrations, checked out outside config/ and bind-mounted
# read-only into /config/custom_components (docker-compose.yml.j2).
homeassistant_vendor_dir: "{{ homeassistant_install_dir }}/vendor"
```

### 1.3 `roles/home-assistant/tasks/main.yml`

Insert **before** *Deploy Home Assistant docker-compose.yml* (the bind-mount
source must exist before `docker compose up`, otherwise Docker creates an empty
directory and HA logs *Integration cozytouch not found*):

```yaml
- name: Install git (pinned community integrations)
  ansible.builtin.apt:
    name: git
    state: present

# Checked out at a commit SHA: content-addressed, so what runs is exactly what
# was reviewed. force: true discards anything edited by hand on the LXC.
- name: Check out the Cozytouch integration at its pinned commit
  ansible.builtin.git:
    repo: "{{ cozytouch_repo }}"
    dest: "{{ homeassistant_vendor_dir }}/cozytouch"
    version: "{{ cozytouch_commit }}"
    depth: 1
    force: true
  register: cozytouch_checkout
  notify: Restart home assistant
```

> `depth: 1` combined with a SHA `version` works only when the SHA is the tip of
> a branch or a tag. If the module complains, drop `depth`: the repository is
> small.

### 1.4 `roles/home-assistant/templates/docker-compose.yml.j2`

Under `homeassistant.volumes`:

```yaml
      # Community integration pinned by commit (group_vars: cozytouch_commit),
      # read-only: neither HACS nor a hand edit can drift it. Python just skips
      # writing __pycache__ here. Adding the mount recreates the container once.
      - {{ homeassistant_vendor_dir }}/cozytouch/custom_components/cozytouch:/config/custom_components/cozytouch:ro
```

### 1.5 Deploy and check

```bash
ansible-playbook playbook.yml --limit adguard,hassium --check --diff   # review
ansible-playbook playbook.yml --limit adguard,hassium
ssh root@hassium.lan 'docker exec homeassistant ls /config/custom_components/cozytouch/manifest.json'
ssh root@hassium.lan 'docker logs homeassistant 2>&1 | grep -i "custom integration cozytouch"'
```

Expected: the *"We found a custom integration cozytouch which has not been
tested by Home Assistant"* warning, the standard notice for any custom
component, and nothing else about it.

*Done when*: HA restarted, the warning above is in the logs, no error.

## Phase 2 — configure (UI, ~10 min)

This lives in `.storage` (config entry, entity registry). Git cannot own it.

1. **Settings → Devices & services → Add integration → Atlantic Cozytouch**,
   log in with the Thermor app account, select the towel rail.
2. **Configure → poll interval: keep 60 s.** The integration's own README:
   the device reports to the cloud on its own schedule, so below a minute you
   buy nothing but load on Atlantic's API, and a reason for them to rate-limit
   the account the app uses too.
3. **Device page**: area *Salle de bain*; rename the device *Sèche-serviettes*.
4. **Stabilize the entity ids** (the dashboard references them). Rename to:

   | Entity | Target id |
   |---|---|
   | climate | `climate.seche_serviettes` |
   | heating calendar | `calendar.seche_serviettes_chauffage` |
   | boost switch (`powerful_mode`), if present | `switch.seche_serviettes_boost` |
   | override activation (`override_setpoint_activation`), if present | `switch.seche_serviettes_derogation` |
   | override duration (`override_total_time`), if present | `select.seche_serviettes_derogation_duree` |
   | override remaining (`override_remain_time`), if present | `sensor.seche_serviettes_derogation_restant` |

5. **Inventory what the device actually exposes.** Fill in this table; it
   decides the dashboard variant in phase 4:

   | Question | How to check | Answer |
   |---|---|---|
   | `boost` in the climate's `preset_modes`? | Developer tools → States → `climate.seche_serviettes` | |
   | `prog` / `basic` presets? | same | |
   | `hvac_modes` | same (expected: `off`, `heat`) | |
   | `current_temperature` populated? | same | |
   | Override entities present? | device page | |
   | Any *unnamed capability* repair issue? | Settings → Repairs | |

   ha-mcp can produce the same inventory in one go (*"list every entity of the
   Cozytouch device and the climate's attributes"*).
6. **Something missing or wrong?** Device page → ⋮ → *Download diagnostics*,
   then open an issue on `gduteil/cozytouch` with it. Check the file first: it
   should be redacted, but look for the account email or serial numbers before
   attaching it anywhere. **Never commit it**.

*Done when*: the device is in *Salle de bain*, the ids match the table, the
inventory table is filled in.

## Phase 3 — validate the three must-haves

Run each from HA, read back in the official app (and the reverse). Note the
delay: cloud polling means up to ~60 s, plus however long the device takes to
report.

| # | Need | Action in HA | Expected in the app | Observed / delay |
|---|---|---|---|---|
| 1 | Status | Read `current_temperature`, `hvac_action` | Same temperature (±0.5 °C) | |
| 2a | Read the program | Open `calendar.seche_serviettes_chauffage` | Same slots as the app | |
| 2b | Change the program | Move a slot with the schedule card (phase 4) or `cozytouch.set_schedule` | Slot moved in the app | |
| 2c | Program change from the app | Edit a slot in the app | Calendar updated after ≤ 1 poll | |
| 3a | Boost (start) | Boost button (phase 4) | App shows boost running | |
| 3b | Boost (stop) | Stop button | Boost stopped in the app | |
| 3c | Boost (end on its own) | Let it run out | HA goes back to `none` / `prog` | |
| 4 | Robustness | `docker restart homeassistant` while the program runs | Device keeps its program (it holds it itself) | |

`cozytouch.set_schedule` test call (Developer tools → Actions), **restore the
original afterwards**: first read it with `cozytouch.get_schedule`.

```yaml
action: cozytouch.set_schedule
target:
  entity_id: climate.seche_serviettes
data:
  program: heating
  days: [saturday]
  slots:
    - time: "00:00"
      temperature: 16
    - time: "07:00"
      temperature: 22
    - time: "09:00"
      temperature: 16
```

Rules from the integration: max 10 slots per day, the first at `00:00`,
whole degrees only.

*Done when*: rows 1 to 3 pass. Row 4 is informative.

## Phase 4 — dashboard with a boost button

Git-owned, like the automations: a **YAML-mode dashboard** in the private
repository `hassium-automation`, deployed by the existing copy → `check_config`
→ swap pipeline. The UI cannot edit it, which is the point.

### 4.1 One-time UI step: the schedule card resource

The integration serves its card at `/cozytouch/cozytouch-schedule-card.js`,
but Home Assistant must be told to load it: **Settings → Dashboards → ⋮ →
Resources → Add**, URL `/cozytouch/cozytouch-schedule-card.js`, type
*JavaScript module*. Then refresh the browser (Ctrl+F5); the HA companion app
needs *Settings → Companion app → Debugging → Reset frontend cache*.

That lives in `.storage`. Add it to the *UI-side choices to redo* table in
`docs/home-assistant.md`.

### 4.2 Private repo — `configuration.yaml`

```yaml
lovelace:
  dashboards:
    # The URL key needs a hyphen (HA rule), kebab-case anyway.
    salle-de-bain:
      mode: yaml
      filename: dashboard-salle-de-bain.yaml
      title: Salle de bain
      icon: mdi:shower
      show_in_sidebar: true
      require_admin: false
```

### 4.3 Private repo — `dashboard-salle-de-bain.yaml`

Flat at the root on purpose: the role copies files one by one into a staging
directory and does not create sub-directories.

**Variant 1: the climate exposes the `boost` preset** (most likely; the button
goes through `climate.set_preset_mode`):

```yaml
title: Salle de bain
views:
  - title: Sèche-serviettes
    path: seche-serviettes
    icon: mdi:radiator
    cards:
      # Status: room temperature, setpoint, mode, preset selector.
      - type: thermostat
        entity: climate.seche_serviettes
        name: Sèche-serviettes
        features:
          - type: climate-hvac-modes
            hvac_modes: ["off", "heat"]
          - type: climate-preset-modes
            style: dropdown

      # Exceptional run. Start is confirmed: 750 W for a while is not free.
      - type: horizontal-stack
        cards:
          - type: button
            name: Boost
            icon: mdi:fire
            show_state: false
            tap_action:
              action: perform-action
              perform_action: climate.set_preset_mode
              target:
                entity_id: climate.seche_serviettes
              data:
                preset_mode: boost
              confirmation:
                text: Lancer un boost du sèche-serviettes ?
          - type: button
            name: Stop
            icon: mdi:fire-off
            show_state: false
            tap_action:
              action: perform-action
              perform_action: climate.set_preset_mode
              target:
                entity_id: climate.seche_serviettes
              data:
                # "none" stops the boost; then the device's program applies.
                # If the inventory showed a "prog" preset, use it here instead
                # so the weekly program is resumed explicitly.
                preset_mode: none

      # Only shown while the boost runs.
      - type: conditional
        conditions:
          - condition: state
            entity: climate.seche_serviettes
            attribute: preset_mode
            state: boost
        card:
          type: markdown
          content: >-
            🔥 **Boost en cours**: consigne
            {{ state_attr('climate.seche_serviettes', 'temperature') }} °C

      # Weekly program, editable (cozytouch.set_schedule under the hood).
      - type: custom:cozytouch-schedule-card
        entity: climate.seche_serviettes
        program: heating
        title: Programmation

      - type: history-graph
        title: Dernières 24 h
        hours_to_show: 24
        entities:
          - entity: climate.seche_serviettes
```

**Variant 2: boost is a switch** (`switch.seche_serviettes_boost` exists,
no `boost` preset). Replace the `horizontal-stack` and the `conditional` with:

```yaml
      - type: tile
        entity: switch.seche_serviettes_boost
        name: Boost
        icon: mdi:fire
        tap_action:
          action: toggle
          confirmation:
            text: Basculer le boost du sèche-serviettes ?
```

**Variant 3: no boost at all, override only** (*dérogation*: hold a
setpoint for N hours, then return to the program). Use:

```yaml
      - type: entities
        title: Dérogation
        entities:
          - entity: select.seche_serviettes_derogation_duree
            name: Durée
          - entity: switch.seche_serviettes_derogation
            name: Activer
          - entity: sensor.seche_serviettes_derogation_restant
            name: Restant
```

If both a boost and an override exist, keep variant 1 or 2 **and** add the
variant 3 card: the app offers both.

### 4.4 This repo — `roles/home-assistant/defaults/main.yml`

```yaml
homeassistant_config_files:
  - configuration.yaml
  - automations-managed.yaml
  - dashboard-salle-de-bain.yaml
```

### 4.5 Order of operations

1. Private repo first: commit `configuration.yaml` + `dashboard-salle-de-bain.yaml`.
2. Then this repo: the `homeassistant_config_files` change. Deployed in the
   reverse order, the *Require the private config repo* assert stops the play.
   That is the safety net working, not a bug.
3. `ansible-playbook playbook.yml --limit adguard,hassium`.

**Know the limit of the gate**: `check_config` validates the `lovelace:` block
in `configuration.yaml`, **not** the content of the dashboard file. A typo in
the dashboard shows up as a red card in the UI, not as a failed play. So
after each deploy, open the dashboard and check it.

*Done when*: *Salle de bain* in the sidebar, the boost button starts and stops
a boost seen in the app, the schedule card shows the same week as the app.

## Phase 5 — documentation

- `docs/home-assistant.md`:
  - *Ownership split*: Ansible now also writes `custom_components/cozytouch`
    (read-only bind-mount), the one exception to "only
    `homeassistant_config_files`".
  - *UI-side choices to redo*: the Cozytouch config entry (account + poll
    interval), the entity renames, the schedule card resource.
- `docs/thermor-allure-4-plan.md`: mark the phases done, keep the filled
  inventory and validation tables as the record of what this device exposes.

## Updating the integration later

1. Read the release notes (`release_notes/` in the repo): look for entity
   renames, they break the dashboard silently.
2. Bump `cozytouch_commit` (+ `cozytouch_version`) in a PR.
3. Deploy; the checkout task notifies the HA restart.
4. Re-run phase 3, rows 1 and 3a.

Rollback: revert the PR and redeploy. The config entry survives a downgrade
**within** the CalVer line; never go back to `1.4`.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Atlantic changes its API | Entities `unavailable` | The device keeps its own program; the app still works; wait for an integration fix |
| Atlantic cloud outage | Same | Same: no local path exists. Fallback below |
| Account rate-limited | App and HA both blocked | Poll at 60 s, never lower |
| Single maintainer project (~100 open issues) | Slow fixes | Pinned SHA: nothing breaks by itself; diagnostics make issues actionable |

**Local fallback if the cloud becomes unbearable**: a fil pilote module
(Zigbee or Shelly), if the towel rail exposes the fil pilote wire (check the
manual). Comfort / eco / frost / off in 100 % local. You lose the boost, the
built-in program and the temperature reading (a Zigbee sensor in the bathroom
covers that last one).

## Appendix — Option B (HACS)

If HACS is chosen after all:

1. Download a **pinned** HACS release instead of `wget | bash`:
   `https://github.com/hacs/integration/releases/download/<version>/hacs.zip`,
   unzip into `config/custom_components/hacs`. That can be an Ansible
   `get_url` (with `checksum:`) + `unarchive`, same idea as phase 1.
2. Restart, *Add integration → HACS*, validate the GitHub device code.
3. HACS → ⋮ → *Custom repositories* → `https://github.com/gduteil/cozytouch`,
   type *Integration* → Download → restart.
4. Continue at phase 2.

Trade-off: HACS writes `custom_components/` and its own `.storage` from the UI.
The HA backup covers them, the Git repo does not.
