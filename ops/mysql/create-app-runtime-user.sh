#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Gives the backend its own MySQL account for running (OWASP SQL Injection
# Prevention Cheat Sheet, least privilege): it can read and write rows of the
# bcm database (SELECT, INSERT, UPDATE, DELETE) and nothing else. No DROP,
# ALTER, CREATE, GRANT or FILE: an injection that got through could not drop
# or change a table, grant itself more, or read or write a file on the server.
#
# The account already in .env (DB_USERNAME, created by the MySQL image with
# every privilege on bcm) stays as it is and is used by the migrate container
# alone, to apply the migrations; the backend never holds its password.
#
# Run once on the production VM, from this repository's root:
#   bash ops/mysql/create-app-runtime-user.sh
# then recreate the backend container so it picks up the new credentials:
#   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-deps backend
#
# The password is the Docker secret secrets/DB_APP_PASSWORD (the user name
# goes to .env, it is not secret). Safe to run again: it reuses the password
# already there (re-syncing the account to it) instead of generating a new
# one, and re-applies the grants. To rotate it, delete the file first.
# The password is never printed and never passed on a command line (it
# reaches MySQL on stdin), so it does not show up in `ps` or shell history.
#
# Environment overrides (optional): ENV_FILE, MYSQL_CONTAINER, DB_NAME, DB_APP_USERNAME.

set -euo pipefail
umask 077

# shellcheck source=../secrets/lib.sh
source "$(dirname "$0")/../secrets/lib.sh"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
DB_NAME="${DB_NAME:-bcm}"
APP_USER="${DB_APP_USERNAME:-bcm_app}"
# Hosts the account accepts connections from: DB_ACCOUNT_HOST in .env
# (production: 172.19.%, the data network), any host otherwise.
ACCOUNT_HOST="$(env_value DB_ACCOUNT_HOST)"
ACCOUNT_HOST="${ACCOUNT_HOST:-%}"
[[ "$ACCOUNT_HOST" =~ ^[0-9.%]+$ ]] || { echo "ERROR: DB_ACCOUNT_HOST must be an IP pattern such as 172.19.%" >&2; exit 1; }
# Must match APP_PRIVILEGES in the backend's AbstractMySQLIntegrationTest,
# where every integration test runs with exactly these privileges.
PRIVILEGES="SELECT, INSERT, UPDATE, DELETE"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (run from the bcm-v2-docker root)" >&2; exit 1; }
[[ "$APP_USER" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ERROR: invalid user name" >&2; exit 1; }
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ERROR: invalid database name" >&2; exit 1; }

existing="$(secret_read DB_APP_PASSWORD)"
if [ -n "$existing" ]; then
    password="$existing"
    echo "Reusing the existing DB_APP_PASSWORD"
else
    # Hex only: nothing in it needs escaping in a JDBC property.
    password="$(openssl rand -hex 24)"
fi

# The root password stays inside the container (its Docker secret); the
# SQL, which contains the new password, goes through stdin.
docker exec -i "$MYSQL_CONTAINER" sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot --batch 2>/dev/null" <<SQL
CREATE USER IF NOT EXISTS '${APP_USER}'@'${ACCOUNT_HOST}' IDENTIFIED BY '${password}';
-- At most 60 connections (the pool holds 50): it cannot take the server's 151.
ALTER USER '${APP_USER}'@'${ACCOUNT_HOST}' IDENTIFIED BY '${password}' WITH MAX_USER_CONNECTIONS 60;
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${APP_USER}'@'${ACCOUNT_HOST}';
GRANT ${PRIVILEGES} ON \`${DB_NAME}\`.* TO '${APP_USER}'@'${ACCOUNT_HOST}';
FLUSH PRIVILEGES;
SQL

printf '%s' "$password" | secret_write DB_APP_PASSWORD
env_set DB_APP_USERNAME "$APP_USER"
[ -n "$existing" ] || echo "Created $SECRETS_DIR/DB_APP_PASSWORD and set DB_APP_USERNAME in $ENV_FILE"
unset password existing

echo "Grants for ${APP_USER} (expected: USAGE plus ${PRIVILEGES} on ${DB_NAME}.*):"
docker exec -i "$MYSQL_CONTAINER" sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot --batch --skip-column-names 2>/dev/null" <<SQL
SHOW GRANTS FOR '${APP_USER}'@'${ACCOUNT_HOST}';
SQL
