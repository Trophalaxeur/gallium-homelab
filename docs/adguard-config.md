---
title: "AdGuard Home Configuration"
description: "DNS filtering and ad-blocking setup for the homelab network."
---

# AdGuard Home Configuration Reference

## How Ansible applies this config

AdGuard Home rewrites `AdGuardHome.yaml` on every start, adding all its default keys
(`pprof`, `doh`, `trusted_proxies`, ...). A plain `template` task would therefore always
differ and restart AdGuard — a LAN-wide DNS blip — on every run. The `adguard-home` role
instead:

- **First install** (no file yet): writes the rendered template as-is.
- **Afterwards**: parses the live file, merges the rendered template into it
  (`combine(recursive=True, list_merge='replace')`), and writes + restarts **only** when the
  merged result differs from the live file. The comparison is on parsed data, not text;
  "nothing changed" shows as `skipping` on `Deploy AdGuard configuration`.

Write durations in AdGuard's canonical notation (`30d`, `90d`, `1d` — not `720h`), otherwise
the merge sees a difference on every run.

**Known limits**

- Removing a scalar or mapping key from the template does **not** remove it from the live
  file: it keeps its last value. Set the value explicitly instead, or edit it on the host.
- Lists are replaced as a whole, so removing a DNS rewrite or a filter does work.
- `schema_version` belongs to AdGuard once installed: the template value (`34`) is only used
  for the first install. After an AdGuard upgrade that migrates keys, update the template to
  the new layout, or the merge will keep re-adding the old keys.

## Web Interface

| Parameter | Value | Why |
|---|---|---|
| `http.address` | `0.0.0.0:3000` | Listens on all interfaces port 3000 (schema v34 unified field). Use `127.0.0.1:3000` to restrict to local only. |
| `http.session_ttl` | `30d` | Web UI session lifetime (30 days). |
| `auth_attempts` | `5` | Maximum failed login attempts before blocking the IP. Lower to `3` for stricter security. |
| `block_auth_min` | `15` | Duration in minutes an IP is blocked after exhausting auth attempts. |

---

## DNS — Listening & Resolution

| Parameter | Value | Why |
|---|---|---|
| `dns.bind_hosts` | `0.0.0.0` | DNS listens on all interfaces — required to serve the whole LAN. |
| `dns.port` | `53` | Standard DNS port — kept as default. AdGuard supports any port, but a non-53 choice means configuring every DNS client (router, OS resolvers) explicitly. |
| `upstream_dns` | Quad9 DoH + Cloudflare DoH | Encrypted DNS over HTTPS. Two providers for redundancy with different geographies. |
| `bootstrap_dns` | `9.9.9.9`, `1.1.1.1` | Plain DNS used at startup to resolve the DoH upstream URLs before the encrypted resolvers are reachable. |

### Upstream DNS alternatives

| Provider | DoH URL | Notes |
|---|---|---|
| **Quad9** *(current)* | `https://dns10.quad9.net/dns-query` | Switzerland-based, malware filtering, privacy-focused |
| **Cloudflare** *(current)* | `https://dns.cloudflare.com/dns-query` | Very fast, logs deleted within 24h |
| NextDNS | `https://dns.nextdns.io/<id>` | Highly configurable, detailed logs, freemium |
| DNS0.eu | `https://dns0.eu/` | European, GDPR-compliant, no-log |
| Google | `8.8.8.8` | Simple but unencrypted and logged by Google |

---

## Performance & Cache

| Parameter | Value | Why |
|---|---|---|
| `cache_size` | `4194304` (4 MB) | In-memory DNS cache. Sufficient for a homelab. Can be raised to 16 MB without notable impact. |
| `cache_optimistic` | `true` | Serves a cached response even after TTL expiry, then refreshes it in the background. Reduces perceived latency. |
| `ratelimit` | `0` (disabled) | Queries per second AdGuard handles per **/24** (`ratelimit_subnet_len_ipv4` defaults to `24`), so the default `20` is one bucket shared by the whole LAN; the excess is silently dropped, with no reply. Disabled because ports 53/853 are not forwarded on the Livebox: only LAN clients can query. |
| `refuse_any` | `true` | Rejects `ANY` query type, which is commonly abused for DNS amplification DDoS attacks. |

---

## Filtering & Security

| Parameter | Value | Why |
|---|---|---|
| `filtering_enabled` | `true` | Core AdGuard feature — blocks ads and trackers via blocklists. |
| `filters_update_interval` | `24` (hours) | How often blocklists are refreshed. `12`h for more reactivity, `24`h is a reasonable default. |
| `blocking_mode` | `default` | Returns `0.0.0.0` for blocked domains. Alternatives: `nxdomain` (domain not found) or a custom IP pointing to a block page. |
| `enable_dnssec` | `false` | DNSSEC validates DNS response signatures. Disabled here to avoid latency and compatibility issues with domains that don't support it. Can be enabled for extra security. |

### Active blocklists

| List | Content |
|---|---|
| AdGuard DNS filter | Ads, trackers, malware — broad general-purpose list |
| AdAway Default Blocklist | Mobile ads and trackers — Android-oriented |

### Other popular blocklists

- **OISD** — very comprehensive, low false-positive rate
- **HaGeZi** — multiple aggression levels (light → ultimate)
- **Steven Black Hosts** — ads + fake news

---

## Logging & Statistics

| Parameter | Value | Why |
|---|---|---|
| `querylog.enabled` | `true` | Logs every DNS query. Useful for diagnostics and monitoring client behavior. |
| `querylog.interval` | `90d` | Retention period for query logs. Reduce to `7d` if disk space is limited. |
| `querylog.file_enabled` | `true` | Persist query log to disk (not just memory). |
| `statistics.enabled` | `true` | Enable dashboard statistics. |
| `statistics.interval` | `1d` | Time range displayed in the dashboard statistics. |

---

## Local DNS Rewrites

Rewrites allow AdGuard to resolve custom local hostnames without a full DNS server.

| Domain | Resolves to | Purpose |
|---|---|---|
| `proxmox.lan` / `proxmox.flefevre.fr` | `192.168.1.32` | Proxmox web UI |
| `adguard.lan` / `adguard.flefevre.fr` | `192.168.1.53` | AdGuard Home web UI |
| `thallium.lan` | `192.168.1.20` | Dev machine |
| `neon.lan` / `neon.flefevre.fr` | `192.168.1.60` | Neon agents LXC (multica daemon + JeanMiPO — kanban on multica.ai) |

The `.lan` suffix is a convention for non-routable local domains.
Alternatives: `.home`, `.internal`.
Avoid `.local` — it is reserved for mDNS (Bonjour/Avahi) and can cause conflicts.

---

## Disabled Features

| Parameter | Value | Notes |
|---|---|---|
| `dhcp.enabled` | `false` | DHCP is handled by the Livebox 6. Enable only if you want AdGuard to replace it. |
| `parental_enabled` | `false` | Parental controls — not needed here. |
| `safebrowsing_enabled` | `false` | Google Safe Browsing integration — adds latency, disabled by default. |

---

## TLS / HTTPS

TLS is **enabled** with a Let's Encrypt certificate issued via acme.sh (DNS-01 challenge through Online.net).

| Parameter | Value | Why |
|---|---|---|
| `tls.enabled` | `true` | HTTPS for the web UI and DoT/DoQ for DNS. |
| `tls.server_name` | `adguard.flefevre.fr` | Must match the cert's Common Name. |
| `tls.port_https` | `443` | Standard HTTPS port for the web UI. |
| `tls.port_dns_over_tls` | `853` | DoT — encrypted DNS over TLS for compatible clients. |
| `tls.port_dns_over_quic` | `853` | DoQ — encrypted DNS over QUIC (UDP). |
| `tls.certificate_path` | `/opt/AdGuardHome/cert/cert.pem` | Provisioned by acme.sh. |
| `tls.private_key_path` | `/opt/AdGuardHome/cert/key.pem` | Provisioned by acme.sh. |
