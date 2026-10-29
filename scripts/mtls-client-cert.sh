#!/usr/bin/env bash
# Client certificates for palladium's mTLS gateway (docs/palladium.md).
#
# Usage, on thallium — never on gallium:
#   ./scripts/mtls-client-cert.sh ca              # once: create the client CA
#   ./scripts/mtls-client-cert.sh issue <device>  # once per device (pixel-8, thallium…)
#
# Private material stays in $MTLS_DIR (default ~/.local/share/gallium-mtls),
# never in this repo: the CA key, protected by a passphrase — store both in
# LastPass — and each device's key and .p12. Only PUBLIC certificates are
# written into the repo, where the palladium role picks them up.

set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
files_dir="$repo_dir/ansible/roles/palladium/files"
mtls_dir=${MTLS_DIR:-$HOME/.local/share/gallium-mtls}
ca_key="$mtls_dir/client-ca.key"
ca_cert="$files_dir/client-ca.pem"

umask 077
mkdir -p "$mtls_dir"

case "${1:-}" in
  ca)
    if [[ -e $ca_key ]]; then
      echo "A client CA already exists: $ca_key" >&2
      exit 1
    fi
    # Prompts for the CA key passphrase. 10 years: rotating the CA means
    # re-issuing every device certificate.
    openssl req -x509 -new -newkey rsa:3072 -sha256 -days 3650 \
      -keyout "$ca_key" -out "$ca_cert" \
      -subj "/CN=gallium client CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign"
    chmod 644 "$ca_cert"
    echo "CA key:  $ca_key  → save it and its passphrase in LastPass"
    echo "CA cert: $ca_cert → commit it"
    ;;

  issue)
    device=${2:?usage: $0 issue <device>}
    if [[ ! $device =~ ^[a-z0-9-]+$ ]]; then
      echo "Device name must be kebab-case: $device" >&2
      exit 1
    fi
    key="$mtls_dir/$device.key"
    csr="$mtls_dir/$device.csr"
    p12="$mtls_dir/$device.p12"
    cert="$files_dir/client-certs/$device.pem"
    # Signed here first, moved into the repo only once everything succeeded:
    # a wrong passphrase must not leave an empty .pem for `git add` to pick up.
    cert_tmp="$mtls_dir/$device.pem"
    mkdir -p "$files_dir/client-certs"

    # RSA rather than EC: the widest client support (Android KeyChain, the
    # Immich app's own import, browsers).
    openssl req -new -newkey rsa:3072 -noenc -keyout "$key" -out "$csr" \
      -subj "/CN=$device"
    # Prompts for the CA key passphrase. 2 years, then re-issue.
    openssl x509 -req -in "$csr" -CA "$ca_cert" -CAkey "$ca_key" \
      -set_serial "0x$(openssl rand -hex 16)" -days 730 -sha256 -out "$cert_tmp" \
      -extfile <(printf '%s\n' \
        "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature" \
        "extendedKeyUsage=clientAuth")
    rm -f "$csr"
    # -legacy: Android rejects the AES-based PKCS#12 OpenSSL 3 writes by
    # default. Prompts for an export password — keep it simple, it is typed
    # once on the phone.
    openssl pkcs12 -export -legacy -inkey "$key" -in "$cert_tmp" -certfile "$ca_cert" \
      -name "$device" -out "$p12"
    mv "$cert_tmp" "$cert"
    chmod 644 "$cert"
    openssl x509 -in "$cert" -noout -subject -enddate
    echo "Install on the device: $p12 (delete it once installed)"
    echo "Commit:                $cert"
    ;;

  *)
    echo "usage: $0 ca | issue <device>" >&2
    exit 1
    ;;
esac
