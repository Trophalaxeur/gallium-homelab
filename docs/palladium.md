---
title: "palladium — the internet-facing gateway"
description: "LXC 108, the only host the Livebox forwards to: Caddy requires a client certificate (mTLS) for Home Assistant and Immich, and serves Immich share links through immich-public-proxy."
---

# palladium — the internet-facing gateway

LXC 108 on gallium. The Livebox forwards **port 443, and only 443, to this
LXC** — nothing else in the homelab is reachable from the internet. Caddy then
decides by name:

```
   phone on 4G       visitor with a link        scanner
        │                     │                    │
        └─────────────────────┼────────────────────┘
                              ▼
                   public IP, TCP 443 only
                              │
                           Livebox
                              │
                              ▼
┌─ palladium (.68) ───────────────────────────────────────┐
│  Caddy reads the requested name in the TLS handshake    │
│                                                         │
│  hassium ── client certificate? ── no ──→ refused       │
│  photos ─── client certificate? ── no ──→ refused       │
│  share ──── none asked ──→ immich-public-proxy          │
└─────┬─────────────────┬────────────────────┬────────────┘
      │ yes             │ yes                │ shared albums,
      ▼                 ▼                    ▼ read-only
 hassium (.66)     immich (.63)         immich (.63)
```

| Name | Goes to | Requires |
|---|---|---|
| `hassium.flefevre.fr` | hassium (`.66`), Home Assistant | a client certificate |
| `photos.flefevre.fr` | immich (`.63`) | a client certificate |
| `share.flefevre.fr` | immich-public-proxy, on palladium | the share password |

Without a valid client certificate, a scanner never sees a login page, so a
flaw in Home Assistant or Immich is not reachable from the internet. Visitors
only get the share links, served by
[immich-public-proxy](https://github.com/alangrainger/immich-public-proxy):
shared albums only, read-only, share password and expiry enforced, no API key.

The refusal happens before any HTTP, which is the whole point:

```
 client                                     palladium
   │ ── hello, I want hassium.flefevre.fr ───→ │
   │ ←── server certificate + "show yours" ─── │
   │ ── client certificate + proof of key ───→ │ signed by the CA?
   │                                           │ listed in the repo?
   │ ←── no: connection closed ─────────────── │ nothing else exposed
   │ ═══ yes: HTTP, proxied to the LXC ══════→ │
```

**At home, palladium is not in the path.** AdGuard resolves `hassium` and
`photos` to their own LXC, and every LAN device reaches them directly, with no
certificate. Only `share.flefevre.fr` resolves to palladium on the LAN, because
the proxy runs there.

The same name has two answers, depending on who resolves it:

```
hassium.flefevre.fr

 at home ─→ AdGuard ──→ 192.168.1.66 ───────────────────────→ hassium
                                                  no certificate

 away ────→ public DNS → public IP → Livebox → palladium ───→ hassium
                                                  client certificate
```

| Device | Resolved by | Path | Certificate |
|---|---|---|---|
| At home | AdGuard | direct | no |
| At home, NordVPN on, app excluded | AdGuard | direct | no |
| At home, NordVPN on, app not excluded | Nord | Nord → Livebox → palladium | yes |
| Away, mobile data | operator | Livebox → palladium | yes |
| Away, NordVPN on | Nord | Nord → Livebox → palladium | yes |

An excluded app on mobile data uses the operator's DNS, so it is the fourth row.

## Specs

| Parameter | Value |
|---|---|
| Hostname | `palladium.lan`, `palladium.flefevre.fr` |
| IP | `192.168.1.68` |
| VMID | 108 |
| RAM / disk / vCPU | 1 GB / 8 GB / 1 |
| OS | Debian 13, unprivileged LXC, `nesting=1` (Docker) |
| Backup | none — stateless, rebuilt by `terraform apply` + `--limit adguard,palladium` (adguard pushes the certificate) |
| Updates | `unattended-upgrades`, daily: Debian security + the Caddy repo. immich-public-proxy is a pinned image — watch its [releases](https://github.com/alangrainger/immich-public-proxy/releases) (GitHub → Watch → Custom → Releases) and bump `vars.yml` |

## How it is wired

There are two kinds of certificates. The **server** one proves to devices that
they reach palladium; it comes from Let's Encrypt. The **client** ones prove to
palladium that the device is allowed; they come from a private CA:

```
 thallium                               public repository
 ~/.local/share/gallium-mtls            ansible/roles/palladium/files
┌─────────────────────────┐            ┌───────────────────────────┐
│ client-ca.key           │── signs ──→│ client-ca.pem             │
│ also in LastPass        │            │ client-certs/<device>.pem │
├─────────────────────────┤            └─────────────┬─────────────┘
│ <device>.key + .p12     │                          │ Ansible
└────────────┬────────────┘                          ▼
             │ USB, once                 palladium, /etc/caddy/mtls
             ▼                           accepts: signed by the CA
           device                        AND listed
```

- **Server certificate**: one Let's Encrypt certificate for the three names,
  issued on the AdGuard LXC (acme.sh, DNS-01 through Online.net) and pushed over
  SSH by the `palladium-cert` role — the pattern of every other LXC. It is a
  separate certificate from the ones hassium and immich hold for their own
  names.
- **Client certificates**: signed by a private client CA created on thallium
  with [`scripts/mtls-client-cert.sh`](../scripts/mtls-client-cert.sh). The CA
  **key** lives in `~/.local/share/gallium-mtls` and LastPass, never in the
  repo and never on gallium. The repo only holds public halves:
  `ansible/roles/palladium/files/client-ca.pem` and one
  `files/client-certs/<device>.pem` per allowed device. Caddy accepts a client
  certificate only if it is signed by the CA **and** listed there, which is
  what makes revocation a file deletion.
- **Upstreams**: palladium reaches hassium and immich by IP, with the SNI and
  Host of the real name, so their own certificates still verify. The LXCs
  resolve through the Livebox, which knows only the public records — a lookup
  by name would loop back to palladium, which refuses it without a certificate.
  No other LXC needs these names today.
- **Client address**: palladium forwards the real address in
  `X-Forwarded-For`. The Caddy of hassium and immich trust palladium
  (`trusted_proxies`), and so must Home Assistant itself (step 5 below).
  Otherwise Home Assistant sees every remote request as coming from palladium,
  and five failed logins from anywhere ban the gateway — that is, every remote
  client.
- **Public DNS**: `hassium`, `photos` and `share` are A records at Online.net
  to the line's **fixed** IPv4 (free Orange Pro option, activated 2026-10-29),
  so there is no DynDNS client or third party to depend on. A CAA record per
  name (step 7) can restrict certificates to this acme.sh account, over DNS-01.
  If the fixed IP is ever lost, the fallback is the Orange Pro DynDNS name
  (*Réseau → DynDNS* on the Livebox): the three names become CNAMEs to it, and
  give up CAA, which a CNAME cannot carry.

## One-time setup

In this order. Steps 1–3 change nothing for the outside world; steps 6–8 are
the switch-over.

1. **Client CA and device certificates**, on thallium:

   ```bash
   ./scripts/mtls-client-cert.sh ca               # asks for the CA passphrase
   ./scripts/mtls-client-cert.sh issue pixel-8    # asks for it again, then an export password
   ./scripts/mtls-client-cert.sh issue thallium   # same prompts
   ```

   Save `~/.local/share/gallium-mtls/client-ca.key` and its passphrase in
   LastPass, as the secure note `gallium-mtls-client-ca`. Commit `client-ca.pem`
   and `client-certs/*.pem` — public halves only. The play refuses to run
   without them.

2. **Create the LXC**, from `terraform/`: `terraform plan -out palladium.tfplan`, review, then
   `terraform apply palladium.tfplan`. No bind-mount, so no root@pam step.

3. **Deploy**, from `ansible/`:

   ```bash
   ansible-playbook playbook.yml --limit adguard,palladium,hassium,immich --ask-vault-pass
   ```

   adguard for the DNS rewrites, the deploy keypair and the certificate;
   hassium and immich for their `trusted_proxies`.

4. **Immich**: Administration → Settings → Server → *External domain* =
   `https://share.flefevre.fr`. Share links now point to the proxy. Links
   already sent as `photos.flefevre.fr/share/<key>` stop working for visitors
   after step 8 (that name now requires a certificate): resend them with
   `share.flefevre.fr` — same `/share/<key>` path.

5. **Home Assistant**: Settings → System → Network → *Trusted proxies*: add
   `192.168.1.68` next to `127.0.0.1`. The save restarts HA and must be
   confirmed within 5 minutes ([home-assistant.md](home-assistant.md#network-settings--one-time-after-the-first-deploy)).

6. **Fixed IPv4**: the Orange Pro option *Adresse IP fixe* must be active
   (Espace Client Pro → services et contrats; confirmed by SMS/mail, then
   power-cycle the Livebox — otherwise the line can take up to 7 days to
   switch, and it does so unannounced). Read the address from thallium, with
   NordVPN disconnected:

   ```bash
   dig +short myip.opendns.com @resolver1.opendns.com
   ```

7. **Online.net DNS**:
   - `photos`, `hassium`, `share`: A records to that address, TTL 3600 (300
     while an address change is coming).
   - **Activate the zone version** once edited: Online.net publishes nothing
     until then. Check with `dig +short hassium.flefevre.fr @ns0.online.net`.
   - On each of the three names, if the zone editor offers the CAA type:

     ```
     0 issue "letsencrypt.org; validationmethods=dns-01; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/3299932925"
     ```

     The account is adguard's acme.sh one
     (`grep ACCOUNT_URL /root/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf`).
     Not on the apex: `flefevre.fr` is served by Vercel, which gets its own
     certificates from another account. Without CAA support, skip it — it is
     hardening, not a prerequisite.

   Test only once the version is active: a resolver that has already answered
   "no such name" keeps that answer for up to an hour (see
   [Troubleshooting](#troubleshooting)).

8. **Livebox, port forwarding**: forward TCP 443 to `192.168.1.68`, and delete
   the 80 and 443 rules to immich. Port 80 stays closed: certificates are
   validated over DNS.

9. **Devices**: install `pixel-8.p12` and `thallium.p12` as described in
   [Install the certificate on the device](#install-the-certificate-on-the-device).

## Checks

- On palladium, `unattended-upgrade --dry-run -d 2>&1 | grep -i 'allowed origins'`
  lists the Debian-Security origins and `cloudsmith/caddy/stable`. A Caddy
  upgrade that would prompt about the Ansible-managed `/etc/caddy/Caddyfile`
  is skipped, not forced — `/var/log/unattended-upgrades/` says so; upgrade it
  by hand (`apt install caddy`, keep the current file).
- From a phone hotspot on 4G, **without** a certificate:
  `curl -sv https://hassium.flefevre.fr` fails with `alert certificate
  required`, same for `photos`.
- On 4G, **with** the certificate: the Home Assistant and Immich apps work,
  including the Immich background backup.
- A share link opened in a private window asks for the share password and shows
  only that album.
- At home, NordVPN off: everything loads directly, palladium not involved.
- At home, NordVPN on with the apps excluded: same as off — excluded apps use
  the Wi-Fi and its DNS (AdGuard), so they reach the LXCs directly. Apps not
  excluded leave through Nord and come back through palladium, with the
  certificate.

Last remote run: 2026-10-30, on the Pixel over 5G.

## Devices

Allowed today: `pixel-8` (Android phone) and `thallium` (Firefox).

### Add a device

1. **Pick a name** for the physical device, kebab-case: the model
   (`pixel-8`), or the hostname for a computer (`thallium`). It becomes the
   certificate's CN, the `.pem` file name and the label Android shows when an
   app asks for a certificate. One certificate per device, so a loss revokes
   only that one.
2. **The CA key must be on the machine running the script.** On thallium it is
   already in `~/.local/share/gallium-mtls/`. Elsewhere, restore it from the
   LastPass note `gallium-mtls-client-ca`:

   ```bash
   mkdir -p ~/.local/share/gallium-mtls && chmod 700 ~/.local/share/gallium-mtls
   $EDITOR ~/.local/share/gallium-mtls/client-ca.key   # paste the PEM from LastPass
   chmod 600 ~/.local/share/gallium-mtls/client-ca.key
   ```

3. **Issue the certificate** from the repo root:

   ```bash
   ./scripts/mtls-client-cert.sh issue <device>
   ```

   It asks for the CA passphrase (LastPass), then an export password for the
   `.p12`: a throwaway, typed once at import. A wrong CA passphrase stops the
   script before anything reaches the repo: just run it again.
4. **Allow it on palladium**: commit
   `ansible/roles/palladium/files/client-certs/<device>.pem` (branch + PR),
   then once merged:

   ```bash
   ansible-playbook playbook.yml --limit palladium --ask-vault-pass
   ```

5. **Install** `~/.local/share/gallium-mtls/<device>.p12` on the device (next
   section), then delete the `.p12` from both places. If it is ever lost, issue
   a new one.

### Install the certificate on the device

- **Android**:
  1. Copy the `.p12` to the phone over USB, never through a cloud service: it
     holds the private key. Phone unlocked, USB mode *File transfer*:

     ```bash
     sudo pacman -S --needed gvfs-mtp
     dev=$(gio mount -li | sed -n 's/.*activation_root=\(mtp:\/\/[^ ]*\).*/\1/p' | head -1)
     gio mount "$dev"
     storage=$(gio list "$dev" | head -1)
     gio copy ~/.local/share/gallium-mtls/<device>.p12 "$dev$storage/Download/"
     ```

  2. Open *Settings → Security → Encryption & credentials → Install a
     certificate → VPN & app user certificate*.
  3. Pick the file and enter the export password.
  4. The Home Assistant app asks which certificate to use the first time it
     goes through palladium, so on mobile data: at home it never asks. Firefox
     (tested on 158) and Chrome use the same store and ask on the first visit.
  5. The Immich app imports the `.p12` itself, from its advanced settings.
  6. In NordVPN, exclude both apps (*Réglages → Exclure du VPN*). At home
     they then reach the LXCs directly, so they keep working without internet
     or palladium, and Immich backups stay on the LAN. If an excluded app
     cannot connect, check *Kill Switch Internet*, which is Android's *Block
     connections without VPN*.
- **Firefox on Linux**: Firefox keeps its own certificate store, per profile.
  From the command line (`pk12util` comes with the `nss` package):

  ```bash
  profile=$(sed -n 's/^Default=\(.*default-release\)$/\1/p' ~/.mozilla/firefox/profiles.ini)
  pk12util -i ~/.local/share/gallium-mtls/<device>.p12 -d "sql:$HOME/.mozilla/firefox/$profile"
  ```

  Restart Firefox. Or use the UI: *Settings → Privacy & Security → View
  Certificates → Your Certificates → Import*. Firefox asks which certificate
  to present on the first visit; tick *Remember this decision*.
- **Windows**: double-click the `.p12` and choose *Current user*. Edge and
  Chrome use that store. Firefox needs the UI import above.
- **Check**: from outside (4G, or NordVPN on), `https://hassium.flefevre.fr`
  loads. At home it always loads, with or without the certificate.

### Revoke, renew

- **Revoke** (lost phone, retired laptop): delete
  `ansible/roles/palladium/files/client-certs/<device>.pem`, commit, re-run
  `--limit palladium`. The certificate is refused from the next connection on.
- **Renew**: device certificates last 2 years
  (`openssl x509 -in <pem> -noout -enddate`); the first ones expire on
  2028-10-28. Follow [Add a device](#add-a-device) with the same name: the new
  `.pem` replaces the old one, and the new `.p12` must be installed on the
  device, because the key changes too.
- **CA**: valid 10 years. Rotating it means re-issuing every device.

## Troubleshooting

- **Name not found on mobile data** (`ERR_NAME_NOT_RESOLVED`, *Adresse
  introuvable*): nothing reaches palladium. Check that the record is published
  (`dig +short <name> @ns0.online.net`, then `@1.1.1.1`). If it is, the mobile
  operator's resolver is still serving a "no such name" answer cached before
  the record existed. That lasts up to an hour (SOA minimum TTL, 3600 s), and
  airplane mode does not clear it.
- **Remote access down, LAN fine**: compare the line's address with the DNS.
  They must match; if not, update the three A records (step 7).

  ```bash
  dig +short myip.opendns.com @resolver1.opendns.com   # NordVPN disconnected
  dig +short hassium.flefevre.fr @ns0.online.net
  ```
- **The app says the server is unreachable, at home**: check whether NordVPN is
  on and the app excluded from it. With NordVPN on and the app not excluded,
  traffic leaves through Nord, which is fine — but it then needs the
  certificate.
- **Handshake refused with a certificate installed**: the device's `.pem` is
  missing from `files/client-certs/`, or the play was not re-run after adding
  it. Caddy does not log refused handshakes at its default level, so check
  both ends instead. On palladium, list the allowed devices:

  ```bash
  openssl crl2pkcs7 -nocrl -certfile /etc/caddy/mtls/client-certs.pem \
    | openssl pkcs7 -print_certs -noout | grep subject
  ```

  From thallium, test a device's certificate (from 4G or NordVPN on, so the
  request reaches palladium):

  ```bash
  curl -sv --cert ansible/roles/palladium/files/client-certs/<device>.pem \
    --key ~/.local/share/gallium-mtls/<device>.key https://hassium.flefevre.fr -o /dev/null
  ```
- **HTTP 502**: the upstream LXC or its Caddy is down — palladium itself is
  fine.
- **acme.sh fails with `CAA record ... prevents issuance`** (hassium, photos or
  share): the CAA records pin adguard's Let's Encrypt account. A rebuilt
  adguard registers a new one — put its `ACCOUNT_URL` (step 7) in the three
  CAA records, then re-run the cert plays.
- **Share links point to `photos.flefevre.fr`**: the Immich *External domain*
  (step 4) is not set.
