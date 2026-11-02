#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Nightly reset of the public demo organization (Nortiva Solutions S.r.l.,
# org id 3, used by visitors through the "demo" account). Undoes anything a
# visitor created, edited or deleted:
#   1. reseeds org 3 from bcm-v2-backend/sql/DML/seed-demo-org.sql
#      (contracts, costs and revenues, budgets, suppliers, Nortiva's IBAN)
#   2. resets the "demo" user's password and turns off any 2FA a visitor
#      enabled on it
#   3. attaches the purchase invoices (scripts/seed_demo_purchase_invoices.py):
#      one paid by SEPA, one waiting for confirmation, one with a changed IBAN
#      that the anti-fraud check blocks
#
# Runs on the production VM from cron:
#   15 4 * * * /home/ubuntu/bcm-v2/bcm-v2-docker/ops/demo/demo-reset.sh
#
# Secrets never live in this file or in its log:
#   - MySQL: the root password is read inside the container from its own
#     environment (same as ops/backup/backup.sh)
#   - "demo_admin", an internal ADMIN account used only by this script and
#     never published: its password is read from ~/.bcm_demo_admin_pw (chmod 600)
#   - "demo" is the public account; its password is printed on the login page
#     on purpose, so it is not a secret
#
# Idempotent and safe to re-run by hand. Scoped to org id 3 only.
set -euo pipefail

ORG_ID=3
DEMO_USERNAME="demo"
DEMO_PASSWORD="BcmDemo#2026"
ADMIN_USERNAME="demo_admin"
ADMIN_PW_FILE="${ADMIN_PW_FILE:-$HOME/.bcm_demo_admin_pw}"

BCM_DIR="${BCM_DIR:-$HOME/bcm-v2}"
BACKEND_DIR="$BCM_DIR/bcm-v2-backend"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8090/api/v1}"
LOG_FILE="${LOG_FILE:-$HOME/demo-reset.log}"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# SQL as root, authenticated inside the container: no password on this host.
mysql_root() {
  docker exec -i "$MYSQL_CONTAINER" sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N --default-character-set=utf8mb4 -u root bcm'
}

login() { # username password -> JWT on stdout
  curl -sS --fail -X POST "$BASE_URL/auth/login" -H "Content-Type: application/json" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": sys.argv[2]}))' "$1" "$2")" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

{
log "=== demo reset starting ==="
ADMIN_PW=$(cat "$ADMIN_PW_FILE")

# 1) Dataset
log "reseeding org $ORG_ID from seed-demo-org.sql..."
mysql_root < "$BACKEND_DIR/sql/DML/seed-demo-org.sql"

# 2) Demo user: 2FA off by SQL (there's no admin API to turn off someone
#    else's 2FA), password through the real API so it is hashed like any other.
echo "UPDATE users SET totp_enabled=0, totp_secret_encrypted=NULL WHERE username='${DEMO_USERNAME}' AND organization_id=${ORG_ID};" | mysql_root
ADMIN_TOKEN=$(login "$ADMIN_USERNAME" "$ADMIN_PW")
DEMO_USER_ID=$(echo "SELECT id FROM users WHERE username='${DEMO_USERNAME}' AND organization_id=${ORG_ID};" | mysql_root)
curl -sS -o /dev/null -w "reset demo password: HTTP %{http_code}\n" -X PATCH "$BASE_URL/users/${DEMO_USER_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"password": sys.argv[1]}))' "$DEMO_PASSWORD")"

# 3) Purchase invoices, on the two purchase contracts looked up by number
#    (their ids change every night).
contract_id() { echo "SELECT id FROM contracts WHERE contract_number='$1' AND organization_id=${ORG_ID};" | mysql_root; }
CLOUD_ID=$(contract_id NRT-2025-007)
ADVISORY_ID=$(contract_id NRT-2025-008)
log "attaching purchase invoices to contracts $CLOUD_ID (cloud) and $ADVISORY_ID (advisory)..."
BCM_DEMO_PASSWORD="$DEMO_PASSWORD" BCM_ADMIN_PASSWORD="$ADMIN_PW" \
  python3 "$BACKEND_DIR/scripts/seed_demo_purchase_invoices.py" --base-url "$BASE_URL" \
    --cloud-contract-id "$CLOUD_ID" --advisory-contract-id "$ADVISORY_ID" \
    --demo-username "$DEMO_USERNAME" --admin-username "$ADMIN_USERNAME" \
  || log "WARN: purchase invoices not attached as expected (see above)"

log "=== demo reset done ==="
} >> "$LOG_FILE" 2>&1
