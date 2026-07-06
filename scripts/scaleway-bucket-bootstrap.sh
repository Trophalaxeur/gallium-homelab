#!/usr/bin/env bash
# One-time bootstrap for the Scaleway Object Storage backup bucket.
#
# Object Lock (Compliance mode) can only be enabled at bucket creation and can
# never be disabled afterward, nor can versioning ever be suspended once set
# — see docs/backup.md and ~/.claude/plans/backup-strategy.md. Re-running this
# script after the bucket exists is safe: create-bucket will just fail with
# BucketAlreadyOwnedByYou and the script stops there (set -e).
#
# Usage:
#   set -a; source scripts/.scaleway-credentials.env; set +a
#   ./scripts/scaleway-bucket-bootstrap.sh

set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?source scripts/.scaleway-credentials.env first}"
: "${AWS_SECRET_ACCESS_KEY:?source scripts/.scaleway-credentials.env first}"
: "${SCW_REGION:?source scripts/.scaleway-credentials.env first}"

BUCKET="homelab-photos-backup"
ENDPOINT="https://s3.${SCW_REGION}.scw.cloud"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

aws_s3api() {
  aws --endpoint-url "$ENDPOINT" --region "$SCW_REGION" s3api "$@"
}

echo "==> Creating bucket $BUCKET (Object Lock enabled)"
aws_s3api create-bucket --bucket "$BUCKET" --object-lock-enabled-for-bucket

echo "==> Setting default retention: COMPLIANCE, 90 days"
aws_s3api put-object-lock-configuration \
  --bucket "$BUCKET" \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Days":90}}}'

echo "==> Enabling SSE-ONE default encryption"
aws_s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "==> Applying lifecycle rule (expire db-backups/ at 90 days)"
aws_s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration "file://${SCRIPT_DIR}/scaleway-lifecycle-db-backups.json"

echo "==> Done. Verifying:"
aws_s3api get-object-lock-configuration --bucket "$BUCKET"
aws_s3api get-bucket-encryption --bucket "$BUCKET"
aws_s3api get-bucket-lifecycle-configuration --bucket "$BUCKET"
