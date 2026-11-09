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
# Safe to run again: it reuses the password already in .env (re-syncing the
# account to it) instead of generating a new one, and re-applies the grants.
# The password is never printed and never passed on a command line (it
# reaches MySQL on stdin), so it does not show up in `ps` or shell history.
#
# Environment overrides (optional): ENV_FILE, MYSQL_CONTAINER, DB_NAME, ML_DB_USERNAME.

set -euo pipefail
umask 077

ENV_FILE="${ENV_FILE:-.env}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
DB_NAME="${DB_NAME:-bcm}"
ML_USER="${ML_DB_USERNAME:-bcm_ml_ro}"
TABLES=(contracts counterparties financial_values)

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (run from the bcm-v2-docker root)" >&2; exit 1; }
[[ "$ML_USER" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ERROR: invalid user name" >&2; exit 1; }

existing="$(grep -E '^ML_DB_PASSWORD=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
if [ -n "$existing" ]; then
    password="$existing"
    echo "Reusing the ML_DB_PASSWORD already in $ENV_FILE"
else
    # Hex only: the password ends up inside the ml service's DB_URL, where
    # URL-special characters would need escaping.
    password="$(openssl rand -hex 24)"
fi

grants=""
for t in "${TABLES[@]}"; do
    grants+="GRANT SELECT ON \`${DB_NAME}\`.\`${t}\` TO '${ML_USER}'@'%';"$'\n'
done

# The root password stays inside the container ($MYSQL_ROOT_PASSWORD); the
# SQL, which contains the new password, goes through stdin.
docker exec -i "$MYSQL_CONTAINER" sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --batch 2>/dev/null' <<SQL
CREATE USER IF NOT EXISTS '${ML_USER}'@'%' IDENTIFIED BY '${password}';
ALTER USER '${ML_USER}'@'%' IDENTIFIED BY '${password}';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${ML_USER}'@'%';
${grants}FLUSH PRIVILEGES;
SQL

if [ -z "$existing" ]; then
    grep -vE '^ML_DB_(USERNAME|PASSWORD)=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
    {
        cat "$ENV_FILE.tmp"
        echo "ML_DB_USERNAME=${ML_USER}"
        echo "ML_DB_PASSWORD=${password}"
    } > "$ENV_FILE.new"
    chmod --reference="$ENV_FILE" "$ENV_FILE.new" 2>/dev/null || true
    mv "$ENV_FILE.new" "$ENV_FILE"
    rm -f "$ENV_FILE.tmp"
    echo "Added ML_DB_USERNAME/ML_DB_PASSWORD to $ENV_FILE"
fi
unset password existing

echo "Grants for ${ML_USER} (expected: USAGE plus SELECT on ${TABLES[*]}):"
docker exec -i "$MYSQL_CONTAINER" sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --batch --skip-column-names 2>/dev/null' <<SQL
SHOW GRANTS FOR '${ML_USER}'@'%';
SQL
