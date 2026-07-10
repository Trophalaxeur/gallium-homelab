#!/usr/bin/env bash
# Applies the two-statement bucket policy on the homelab-photos-backup bucket:
#   1. OwnerFullAccess     — the bootstrap/admin principal (OWNER_PRINCIPAL),
#      full s3:* so the owner keeps control. ⚠️ Scaleway makes a bucket policy
#      AUTHORITATIVE (unlike AWS, where the root account is never locked out):
#      any principal NOT listed is denied, including the admin key that set it —
#      hence this explicit owner statement, or `s3 ls` breaks for the admin.
#   2. BackupReadWriteRetainOnly — the backup LXC's scoped IAM application,
#      ONLY list + get/put objects + get/put object retention (weekly Object
#      Lock renewal). Delete*, versioning and lock-config stay implicitly denied
#      (default-deny) — the Scénario 6 ransomware isolation.
#
# Idempotent: re-running just re-puts the same policy. Reversible: the owner can
# `delete-bucket-policy` at any time (policy management is always allowed to the
# bucket owner, even under a restrictive policy).
#
# Usage:
#   export OWNER_PRINCIPAL="user_id:<uuid>"        # or application_id:<uuid>
#   export SCOPED_APPLICATION_ID=<uuid of the backup-lxc IAM application>
#   set -a; source scripts/.scaleway-credentials.env; set +a
#   ./scripts/scaleway-apply-bucket-policy.sh
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?source scripts/.scaleway-credentials.env first}"
: "${AWS_SECRET_ACCESS_KEY:?source scripts/.scaleway-credentials.env first}"
: "${SCW_REGION:?source scripts/.scaleway-credentials.env first}"
: "${OWNER_PRINCIPAL:?set OWNER_PRINCIPAL to the bucket owner, e.g. user_id:<uuid>}"
: "${SCOPED_APPLICATION_ID:?set SCOPED_APPLICATION_ID to the backup-lxc IAM application UUID}"

BUCKET="homelab-photos-backup"
ENDPOINT="https://s3.${SCW_REGION}.scw.cloud"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$(sed -e "s/__OWNER_PRINCIPAL__/${OWNER_PRINCIPAL}/" \
              -e "s/__SCOPED_APPLICATION_ID__/${SCOPED_APPLICATION_ID}/" \
              "${SCRIPT_DIR}/scaleway-bucket-policy.json")"

aws_s3api() { aws --endpoint-url "$ENDPOINT" --region "$SCW_REGION" s3api "$@"; }

echo "==> Applying scoped bucket policy to $BUCKET (application_id:${SCOPED_APPLICATION_ID})"
aws_s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY"

echo "==> Verifying:"
aws_s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text | python3 -m json.tool
