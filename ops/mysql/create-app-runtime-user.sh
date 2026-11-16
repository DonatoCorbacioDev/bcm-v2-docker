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
# every privilege on bcm) stays as it is and is used by Flyway alone, at the
# backend's startup, to apply the migrations.
#
# Run once on the production VM, from this repository's root:
#   bash ops/mysql/create-app-runtime-user.sh
# then recreate the backend container so it picks up the new credentials:
#   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-deps backend
#
# Safe to run again: it reuses the password already in .env (re-syncing the
# account to it) instead of generating a new one, and re-applies the grants.
# The password is never printed and never passed on a command line (it
# reaches MySQL on stdin), so it does not show up in `ps` or shell history.
#
# Environment overrides (optional): ENV_FILE, MYSQL_CONTAINER, DB_NAME, DB_APP_USERNAME.

set -euo pipefail
umask 077

ENV_FILE="${ENV_FILE:-.env}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
DB_NAME="${DB_NAME:-bcm}"
APP_USER="${DB_APP_USERNAME:-bcm_app}"
# Must match APP_PRIVILEGES in the backend's AbstractMySQLIntegrationTest,
# where every integration test runs with exactly these privileges.
PRIVILEGES="SELECT, INSERT, UPDATE, DELETE"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (run from the bcm-v2-docker root)" >&2; exit 1; }
[[ "$APP_USER" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ERROR: invalid user name" >&2; exit 1; }
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ERROR: invalid database name" >&2; exit 1; }

existing="$(grep -E '^DB_APP_PASSWORD=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
if [ -n "$existing" ]; then
    password="$existing"
    echo "Reusing the DB_APP_PASSWORD already in $ENV_FILE"
else
    # Hex only: nothing in it needs escaping in .env or in a JDBC property.
    password="$(openssl rand -hex 24)"
fi

# The root password stays inside the container ($MYSQL_ROOT_PASSWORD); the
# SQL, which contains the new password, goes through stdin.
docker exec -i "$MYSQL_CONTAINER" sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --batch 2>/dev/null' <<SQL
CREATE USER IF NOT EXISTS '${APP_USER}'@'%' IDENTIFIED BY '${password}';
ALTER USER '${APP_USER}'@'%' IDENTIFIED BY '${password}';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${APP_USER}'@'%';
GRANT ${PRIVILEGES} ON \`${DB_NAME}\`.* TO '${APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL

if [ -z "$existing" ]; then
    grep -vE '^DB_APP_(USERNAME|PASSWORD)=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
    {
        cat "$ENV_FILE.tmp"
        echo "DB_APP_USERNAME=${APP_USER}"
        echo "DB_APP_PASSWORD=${password}"
    } > "$ENV_FILE.new"
    chmod --reference="$ENV_FILE" "$ENV_FILE.new" 2>/dev/null || true
    mv "$ENV_FILE.new" "$ENV_FILE"
    rm -f "$ENV_FILE.tmp"
    echo "Added DB_APP_USERNAME/DB_APP_PASSWORD to $ENV_FILE"
fi
unset password existing

echo "Grants for ${APP_USER} (expected: USAGE plus ${PRIVILEGES} on ${DB_NAME}.*):"
docker exec -i "$MYSQL_CONTAINER" sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --batch --skip-column-names 2>/dev/null' <<SQL
SHOW GRANTS FOR '${APP_USER}'@'%';
SQL
