#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Gives the ML service its own MySQL account that can only READ the three
# tables it uses (contracts, counterparties, financial_values). The ML
# service never writes; with the backend's read-write account a bug or a
# compromise there could change or read anything, including users' password
# hashes and 2FA secrets. With this account it can do neither.
#
# Run once on the production VM, from this repository's root:
#   bash ops/mysql/create-ml-readonly-user.sh
# then recreate the ml container so it picks up the new credentials:
#   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-deps ml
#
# The password is the Docker secret secrets/ML_DB_PASSWORD, and the ml
# service reads it inside secrets/ML_DB_URL, its whole connection string;
# the user name goes to .env, it is not secret. Safe to run again: it reuses
# the password already there (re-syncing the account to it) instead of
# generating a new one, and re-applies the grants. To rotate it, delete
# secrets/ML_DB_PASSWORD first.
# The password is never printed and never passed on a command line (it
# reaches MySQL on stdin), so it does not show up in `ps` or shell history.
#
# Environment overrides (optional): ENV_FILE, MYSQL_CONTAINER, DB_NAME, ML_DB_USERNAME.

set -euo pipefail
umask 077

# shellcheck source=../secrets/lib.sh
source "$(dirname "$0")/../secrets/lib.sh"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
DB_NAME="${DB_NAME:-bcm}"
ML_USER="${ML_DB_USERNAME:-bcm_ml_ro}"
# Hosts the account accepts connections from: DB_ACCOUNT_HOST in .env
# (production: 172.19.%, the data network), any host otherwise.
ACCOUNT_HOST="$(env_value DB_ACCOUNT_HOST)"
ACCOUNT_HOST="${ACCOUNT_HOST:-%}"
[[ "$ACCOUNT_HOST" =~ ^[0-9.%]+$ ]] || { echo "ERROR: DB_ACCOUNT_HOST must be an IP pattern such as 172.19.%" >&2; exit 1; }
TABLES=(contracts counterparties financial_values)

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (run from the bcm-v2-docker root)" >&2; exit 1; }
[[ "$ML_USER" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ERROR: invalid user name" >&2; exit 1; }

existing="$(secret_read ML_DB_PASSWORD)"
if [ -n "$existing" ]; then
    password="$existing"
    echo "Reusing the existing ML_DB_PASSWORD"
else
    # Hex only: the password ends up inside the ml service's DB_URL, where
    # URL-special characters would need escaping.
    password="$(openssl rand -hex 24)"
fi

grants=""
for t in "${TABLES[@]}"; do
    grants+="GRANT SELECT ON \`${DB_NAME}\`.\`${t}\` TO '${ML_USER}'@'${ACCOUNT_HOST}';"$'\n'
done

# The root password stays inside the container (its Docker secret); the
# SQL, which contains the new password, goes through stdin.
docker exec -i "$MYSQL_CONTAINER" sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot --batch 2>/dev/null" <<SQL
CREATE USER IF NOT EXISTS '${ML_USER}'@'${ACCOUNT_HOST}' IDENTIFIED BY '${password}';
-- At most 60 connections (4 workers, 15 each at most): it cannot take the server's 151.
ALTER USER '${ML_USER}'@'${ACCOUNT_HOST}' IDENTIFIED BY '${password}' WITH MAX_USER_CONNECTIONS 60;
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${ML_USER}'@'${ACCOUNT_HOST}';
${grants}FLUSH PRIVILEGES;
SQL

printf '%s' "$password" | secret_write ML_DB_PASSWORD
printf 'mysql+pymysql://%s:%s@mysql:3306/%s' "$ML_USER" "$password" "$DB_NAME" | secret_write ML_DB_URL
env_set ML_DB_USERNAME "$ML_USER"
[ -n "$existing" ] || echo "Created $SECRETS_DIR/ML_DB_PASSWORD and $SECRETS_DIR/ML_DB_URL, set ML_DB_USERNAME in $ENV_FILE"
unset password existing

echo "Grants for ${ML_USER} (expected: USAGE plus SELECT on ${TABLES[*]}):"
docker exec -i "$MYSQL_CONTAINER" sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot --batch --skip-column-names 2>/dev/null" <<SQL
SHOW GRANTS FOR '${ML_USER}'@'${ACCOUNT_HOST}';
SQL
