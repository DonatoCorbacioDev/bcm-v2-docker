#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Brings the MySQL accounts of an existing database to their intended shape
# (OWASP Database Security, users and privileges; limit access to the server):
#   - root only from inside the container (the local socket the ops scripts
#     use), never over the network: drops root@'%', which
#     the MySQL image creates on a new volume unless MYSQL_ROOT_HOST says
#     otherwise (docker-compose.yml now does);
#   - a ceiling on each account's connections, so none can take all of the
#     server's 151 and lock the others out: the schema owner 5 (the migrate
#     container only), the backend's 60 (its pool holds 50), ml's 60 (4
#     workers, 15 each at most);
#   - the three application accounts accept connections only from the host
#     pattern DB_ACCOUNT_HOST in .env (production: 172.19.%, the data network,
#     fixed in docker-compose.prod.yml; unset: any host, '%'). RENAME USER
#     keeps each account's password and privileges.
#
# Safe to run again. Run on the production VM, from this repository's root:
#   bash ops/mysql/harden-accounts.sh
# then check the result with ops/mysql/check-privileges.sh.
#
# Environment overrides (optional): ENV_FILE, MYSQL_CONTAINER.

set -euo pipefail
umask 077

# shellcheck source=../secrets/lib.sh
source "$(dirname "$0")/../secrets/lib.sh"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (run from the bcm-v2-docker root)" >&2; exit 1; }
OWNER="$(env_value DB_USERNAME)"
APP="$(env_value DB_APP_USERNAME)"
ML="$(env_value ML_DB_USERNAME)"
HOST="$(env_value DB_ACCOUNT_HOST)"
HOST="${HOST:-%}"
for name in "$OWNER" "$APP" "$ML"; do
    [[ "$name" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ERROR: DB_USERNAME, DB_APP_USERNAME and ML_DB_USERNAME must be set in $ENV_FILE" >&2; exit 1; }
done
[[ "$HOST" =~ ^[0-9.%]+$ ]] || { echo "ERROR: DB_ACCOUNT_HOST must be an IP pattern such as 172.19.%" >&2; exit 1; }

mysql_root() {
    docker exec -i "$MYSQL_CONTAINER" sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot --batch --skip-column-names 2>/dev/null"
}

# Each account moved to HOST, from whatever host it has now (once, then a no-op).
for name in "$OWNER" "$APP" "$ML"; do
    current="$(printf "SELECT host FROM mysql.user WHERE user = '%s';" "$name" | mysql_root)"
    [ -n "$current" ] || { echo "ERROR: no MySQL account $name" >&2; exit 1; }
    [ "$(printf '%s' "$current" | grep -c '')" -eq 1 ] || { echo "ERROR: $name has more than one host: fix it by hand" >&2; exit 1; }
    if [ "$current" != "$HOST" ]; then
        printf "RENAME USER '%s'@'%s' TO '%s'@'%s';" "$name" "$current" "$name" "$HOST" | mysql_root
        echo "$name: host $current -> $HOST"
    fi
done

# Through stdin, root's password read inside the container (ops/secrets/lib.sh).
mysql_root <<SQL
DROP USER IF EXISTS 'root'@'%';
ALTER USER '${OWNER}'@'${HOST}' WITH MAX_USER_CONNECTIONS 5;
ALTER USER '${APP}'@'${HOST}' WITH MAX_USER_CONNECTIONS 60;
ALTER USER '${ML}'@'${HOST}' WITH MAX_USER_CONNECTIONS 60;
SQL

echo "Accounts now (user@host, connection limit):"
mysql_root <<'SQL'
SELECT CONCAT(user, '@', host, ' max_user_connections=', max_user_connections)
FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user, host;
SQL
