#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Checks that what should be encrypted, hashed or locked away still is (OWASP
# Database Security, encryption at rest: verify it periodically). Prints counts
# and formats only, never a value, so its output is safe to paste:
#   - in the database: every two-factor secret encrypted with the dedicated key
#     ("v2:"), every password a BCrypt hash, every refresh, reset and invitation
#     token a SHA-256 (64 hex characters), never the token itself;
#   - the backups: the newest set less than 26 hours old, both archives age files;
#   - the keys: the backup recipient is a public key (the private one is never
#     on this host), the secrets directory 700 and its files 444, and a
#     recovery bundle of the secrets newer than every secret
#     (ops/secrets/recovery-bundle.sh).
# Any failure exits 1. Run weekly from ops/maintenance/weekly-checks.sh, and by hand.
#
# Environment overrides (optional): MYSQL_CONTAINER, BACKUP_DIR, RECOVERY_DIR.

set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
# shellcheck source=../secrets/lib.sh
source "ops/secrets/lib.sh"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/bcm}"
RECOVERY_DIR="${RECOVERY_DIR:-$HOME/backups/recovery}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
failures=0
fail() { log "ERROR: $*"; failures=$((failures + 1)); }

mysql_root() {
    docker exec -i "$MYSQL_CONTAINER" sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot bcm --batch --skip-column-names 2>/dev/null"
}

# --- the database: anything stored in clear that should not be
while IFS=$'\t' read -r what bad total; do
    if [ "$bad" != "0" ]; then
        fail "$what: $bad of $total not protected"
    else
        log "$what: $total, all protected"
    fi
done < <(mysql_root <<'SQL'
SELECT 'two-factor secrets (v2: encryption)', COALESCE(SUM(totp_secret_encrypted NOT LIKE 'v2:%'), 0), COUNT(*)
  FROM users WHERE totp_secret_encrypted IS NOT NULL;
SELECT 'passwords (BCrypt)', COALESCE(SUM(password_hash NOT REGEXP '^[$]2[aby][$][0-9]{2}[$]'), 0), COUNT(*) FROM users;
SELECT 'refresh tokens (SHA-256)', COALESCE(SUM(token NOT REGEXP '^[0-9a-f]{64}$'), 0), COUNT(*) FROM refresh_tokens;
SELECT 'reset links (SHA-256)', COALESCE(SUM(token NOT REGEXP '^[0-9a-f]{64}$'), 0), COUNT(*) FROM password_reset_token;
SELECT 'invitations (SHA-256)', COALESCE(SUM(token NOT REGEXP '^[0-9a-f]{64}$'), 0), COUNT(*) FROM invite_token;
SQL
)

# --- the backups
newest="$(find "$BACKUP_DIR/daily" -maxdepth 1 -name 'bcm-db-*.sql.gz.age' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2- || true)"
if [ -z "$newest" ]; then
    fail "no backup in $BACKUP_DIR/daily"
else
    age_hours=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 3600 ))
    stamp="${newest##*/bcm-db-}"; stamp="${stamp%.sql.gz.age}"
    [ "$age_hours" -lt 26 ] && log "newest backup $stamp: $age_hours hours old" || fail "newest backup $stamp is $age_hours hours old"
    before=$failures
    for f in "$newest" "$BACKUP_DIR/daily/bcm-uploads-$stamp.tar.gz.age"; do
        [ "$(head -c 21 "$f" 2>/dev/null)" = "age-encryption.org/v1" ] || fail "${f##*/} is not an age file"
    done
    [ "$failures" -eq "$before" ] && log "backup $stamp: both archives encrypted (age)"
fi
grep -q '^age1' ops/backup/backup-recipient.pub && ! grep -q 'AGE-SECRET-KEY' ops/backup/backup-recipient.pub \
    && log "backup key: public recipient only on this host" || fail "ops/backup/backup-recipient.pub is not a public key alone"

# --- the keys
[ "$(stat -c %a "$SECRETS_DIR")" = "700" ] && log "secrets directory: 700" || fail "$SECRETS_DIR is not 700"
loose="$(find "$SECRETS_DIR" -maxdepth 1 -type f ! -name '.*' ! -perm 444 -printf '%f ' )"
[ -z "$loose" ] && log "secret files: all 444" || fail "secret files not 444: $loose"
bundle="$(find "$RECOVERY_DIR" -maxdepth 1 -name 'bcm-recovery-*.tar.gz.age' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2- || true)"
if [ -z "$bundle" ]; then
    fail "no recovery bundle of the secrets: run ops/secrets/recovery-bundle.sh"
else
    newer="$(find "$SECRETS_DIR" -maxdepth 1 -type f ! -name '.*' -newer "$bundle" -printf '%f ')"
    [ -z "$newer" ] && log "recovery bundle ${bundle##*/}: holds every current secret" \
        || fail "secrets changed after the recovery bundle (${newer}): run ops/secrets/recovery-bundle.sh"
fi

if [ "$failures" -gt 0 ]; then
    log "encryption check: $failures problem(s)"
    exit 1
fi
log "encryption check OK"
