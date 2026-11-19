#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Rotates the password of one MySQL account (OWASP Database Security, credential
# rotation): a new random one (48 hex characters) set in MySQL and written to
# its Docker secret, never printed and never on a command line (it reaches
# MySQL on stdin). Rotate each yearly, and at once when it may have leaked;
# ops/mysql/check-privileges.sh reports the ones older than a year.
#
#   bash ops/mysql/rotate-password.sh app     # the backend's (DB_APP_PASSWORD)
#   bash ops/mysql/rotate-password.sh ml      # ml's (ML_DB_PASSWORD, ML_DB_URL)
#   bash ops/mysql/rotate-password.sh owner   # the schema owner's (DB_PASSWORD)
#   bash ops/mysql/rotate-password.sh root    # root's (DB_ROOT_PASSWORD)
#
# app and ml without downtime, with MySQL's dual passwords: the new one is
# added while the old one keeps working (RETAIN CURRENT PASSWORD); recreate the
# service so it reads the new secret, then drop the old one:
#   bash ops/mysql/rotate-password.sh app --discard-old
# owner: used only by the migrate container, which reads it at the next deploy.
# root: recreate mysql afterwards (up -d mysql), so the ops scripts, which read
# its secret file inside that container, see the new one.
#
# Take a backup first. Run from this repository's root.
# Environment overrides (optional): ENV_FILE, MYSQL_CONTAINER.

set -euo pipefail
umask 077

# shellcheck source=../secrets/lib.sh
source "$(dirname "$0")/../secrets/lib.sh"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
which="${1:-}"
discard="${2:-}"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (run from the bcm-v2-docker root)" >&2; exit 1; }
HOST="$(env_value DB_ACCOUNT_HOST)"
HOST="${HOST:-%}"
case "$which" in
    app)   user="$(env_value DB_APP_USERNAME)"; secret=DB_APP_PASSWORD; dual=1; host="$HOST"; then="up -d --no-deps backend" ;;
    ml)    user="$(env_value ML_DB_USERNAME)";  secret=ML_DB_PASSWORD;  dual=1; host="$HOST"; then="up -d --no-deps ml" ;;
    owner) user="$(env_value DB_USERNAME)";     secret=DB_PASSWORD;     dual=0; host="$HOST"; then="nothing: migrate reads it at the next deploy" ;;
    root)  user=root;                           secret=DB_ROOT_PASSWORD; dual=0; host=localhost; then="up -d mysql" ;;
    *) echo "Usage: $0 app|ml|owner|root [--discard-old]" >&2; exit 1 ;;
esac
[[ "$user" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ERROR: the account name for $which is not set in $ENV_FILE" >&2; exit 1; }
[[ "$host" =~ ^[0-9.%a-z]+$ ]] || { echo "ERROR: invalid host" >&2; exit 1; }

mysql_root() {
    docker exec -i "$MYSQL_CONTAINER" sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot --batch 2>/dev/null"
}

if [ "$discard" = "--discard-old" ]; then
    [ "$dual" -eq 1 ] || { echo "ERROR: only app and ml keep an old password" >&2; exit 1; }
    printf "ALTER USER '%s'@'%s' DISCARD OLD PASSWORD;" "$user" "$host" | mysql_root
    echo "The old password of $user is no longer accepted."
    exit 0
fi
[ -z "$discard" ] || { echo "Usage: $0 app|ml|owner|root [--discard-old]" >&2; exit 1; }

password="$(openssl rand -hex 24)"
if [ "$dual" -eq 1 ]; then
    retain=" RETAIN CURRENT PASSWORD"
else
    retain=""
fi
# Set in MySQL first: if this fails, the secret still holds the working password.
mysql_root <<SQL
ALTER USER '${user}'@'${host}' IDENTIFIED BY '${password}'${retain};
SQL
printf '%s' "$password" | secret_write "$secret"
if [ "$which" = ml ]; then
    printf 'mysql+pymysql://%s:%s@mysql:3306/%s' "$user" "$password" "bcm" | secret_write ML_DB_URL
fi
unset password

echo "New password of $user set in MySQL and written to $SECRETS_DIR/$secret."
echo "Next: $then"
if [ "$dual" -eq 1 ]; then
    echo "Then, once it is up: bash $0 $which --discard-old"
fi
