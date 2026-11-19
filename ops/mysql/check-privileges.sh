#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Checks MySQL's accounts and privileges against what they should be (OWASP
# Database Security: review the privileges periodically with SHOW GRANTS).
# Every account (user@host, plugin, locked, connection limit) and every
# SHOW GRANTS line is compared with ops/mysql/expected-privileges.txt; any
# difference, an account or a privilege added, removed or changed, is printed
# and fails the check. Prints names and privileges only, never a password or a
# hash, so its output is safe to paste.
#
# In the expected file the three account names are placeholders, filled from
# .env: {OWNER} (DB_USERNAME), {APP} (DB_APP_USERNAME), {ML} (ML_DB_USERNAME).
# After a deliberate change, update the file in the same commit.
#
# Runs weekly from cron on the production VM, and after every deploy:
#   0 6 * * MON HEALTHCHECK_URL=https://hc-ping.com/... /bin/bash /home/ubuntu/bcm-v2/bcm-v2-docker/ops/mysql/check-privileges.sh >> /home/ubuntu/backups/check-privileges.log 2>&1
# HEALTHCHECK_URL (optional) is pinged on success and, with /fail, on failure.
#
# Environment overrides (optional): ENV_FILE, MYSQL_CONTAINER, EXPECTED, HEALTHCHECK_URL.

set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
# shellcheck source=../secrets/lib.sh
source "ops/secrets/lib.sh"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
EXPECTED="${EXPECTED:-ops/mysql/expected-privileges.txt}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

finish() {
    local rc=$?
    if [ -n "$HEALTHCHECK_URL" ]; then
        if [ "$rc" -eq 0 ]; then
            curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
        else
            curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL/fail" >/dev/null 2>&1 || true
        fi
    fi
    exit "$rc"
}
trap finish EXIT

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

[ -f "$ENV_FILE" ] || { log "ERROR: $ENV_FILE not found"; exit 1; }
[ -f "$EXPECTED" ] || { log "ERROR: $EXPECTED not found"; exit 1; }
OWNER="$(env_value DB_USERNAME)"
APP="$(env_value DB_APP_USERNAME)"
ML="$(env_value ML_DB_USERNAME)"
for name in "$OWNER" "$APP" "$ML"; do
    [[ "$name" =~ ^[A-Za-z0-9_]+$ ]] || { log "ERROR: DB_USERNAME, DB_APP_USERNAME and ML_DB_USERNAME must be set in $ENV_FILE"; exit 1; }
done

mysql_root() {
    docker exec -i "$MYSQL_CONTAINER" sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot --batch --skip-column-names 2>/dev/null"
}

accounts="$(mysql_root <<'SQL'
SELECT CONCAT(user, '@', host) FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user, host;
SQL
)"
[ -n "$accounts" ] || { log "ERROR: no account read from $MYSQL_CONTAINER"; exit 1; }

query="SELECT CONCAT('ACCOUNT ', user, '@', host, ' plugin=', plugin, ' locked=', account_locked,
 ' max_user_connections=', max_user_connections) FROM mysql.user ORDER BY user, host;"$'\n'
while IFS= read -r account; do
    user="${account%@*}"
    host="${account##*@}"
    query+="SELECT 'GRANTS ${account}';"$'\n'"SHOW GRANTS FOR '${user}'@'${host}';"$'\n'
done <<< "$accounts"

# The real names replaced by their placeholders, then compared line by line.
actual="$(printf '%s' "$query" | mysql_root | sed -e "s/\b${OWNER}\b/{OWNER}/g" -e "s/\b${APP}\b/{APP}/g" -e "s/\b${ML}\b/{ML}/g")"
expected="$(grep -v '^#' "$EXPECTED" | sed '/^$/d')"

if diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") > /tmp/check-privileges.diff; then
    log "privileges OK: $(printf '%s\n' "$accounts" | wc -l | tr -d ' ') accounts as expected"
    rm -f /tmp/check-privileges.diff
else
    log "ERROR: privileges differ from $EXPECTED ('<' expected, '>' found):"
    cat /tmp/check-privileges.diff
    rm -f /tmp/check-privileges.diff
    exit 1
fi
