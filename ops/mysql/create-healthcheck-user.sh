#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Creates the healthcheck's account (mysql/healthcheck-account.sql) on a data
# volume that already exists: a new one gets it from the image's entrypoint.
# Run on the production VM, from this repository's root, BEFORE the mysql
# container is recreated with the healthcheck that signs in with it:
#   bash ops/mysql/create-healthcheck-user.sh
# Safe to run again. No password: the account authenticates by OS user.
#
# Environment overrides (optional): MYSQL_CONTAINER.

set -euo pipefail
umask 077

# shellcheck source=../secrets/lib.sh
source "$(dirname "$0")/../secrets/lib.sh"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
SQL_FILE="$(dirname "$0")/../../mysql/healthcheck-account.sql"

mysql_root() {
    docker exec -i "$MYSQL_CONTAINER" sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot --batch --skip-column-names"
}

installed="$(echo "SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'auth_socket';" | mysql_root)"
if [ "$installed" = 0 ]; then
    # The file as the entrypoint runs it.
    grep -v '^--' "$SQL_FILE" | mysql_root
else
    # Plugin already there: only the account (INSTALL PLUGIN would fail).
    grep -v '^--' "$SQL_FILE" | grep -v '^INSTALL PLUGIN' | mysql_root
fi

echo "Healthcheck account (expected: bcm_health@localhost auth_socket, USAGE only):"
mysql_root <<'SQL'
SELECT CONCAT(user, '@', host, ' ', plugin) FROM mysql.user WHERE user = 'bcm_health';
SHOW GRANTS FOR 'bcm_health'@'localhost';
SQL
echo "Sign-in as the healthcheck does (expected 0 once the server listens):"
docker exec "$MYSQL_CONTAINER" mysql --protocol=socket -ubcm_health --batch --skip-column-names -e 'SELECT @@skip_networking'
