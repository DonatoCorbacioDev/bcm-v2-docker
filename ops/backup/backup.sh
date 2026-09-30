#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Nightly backup of BCM's production data: a MySQL dump plus the uploaded
# files (invoice XMLs, contract documents). Each is encrypted with `age` to a
# PUBLIC key before landing in its final location, so the private key never
# has to exist on this machine: whoever steals the VM or the backup files
# cannot read them, and a compromised VM cannot read old backups either.
#
# Runs on the production VM from cron, against the running containers:
#   15 3 * * * /home/ubuntu/bcm-v2/bcm-v2-docker/ops/backup/backup.sh >> /home/ubuntu/backups/bcm/backup.log 2>&1
#
# One-time setup, on YOUR computer (not the VM):
#   age-keygen -o bcm-backup-key.txt     # SECRET: password manager + an offline copy
#   put the "age1..." public key from that file into ops/backup/backup-recipient.pub
#   and commit it (a public key is safe to publish).
# Lose the private key and every backup becomes unreadable -- there is no recovery.
#
# Restoring (and proving a backup works) is done by restore-test.sh.
#
# Environment overrides (all optional): BACKUP_DIR, MYSQL_CONTAINER,
# BACKEND_CONTAINER, UPLOADS_PATH, DB_NAME, RECIPIENT_FILE, KEEP_DAILY,
# KEEP_WEEKLY, WEEKLY_DAY, HEALTHCHECK_URL (a dead-man's-switch URL pinged on success and,
# with /fail appended, on failure; unset = no third party involved).

set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/bcm}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
BACKEND_CONTAINER="${BACKEND_CONTAINER:-bcm-backend}"
UPLOADS_PATH="${UPLOADS_PATH:-/app/uploads}"
DB_NAME="${DB_NAME:-bcm}"
RECIPIENT_FILE="${RECIPIENT_FILE:-$SCRIPT_DIR/backup-recipient.pub}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
WEEKLY_DAY="${WEEKLY_DAY:-7}"   # ISO weekday that also gets a weekly copy (7 = Sunday)
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

tmp=""

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

finish() {
  local rc=$?
  if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
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

# Keeps the newest $2 backup sets in directory $1 and deletes the rest.
# A "set" is the db archive, the uploads archive and the checksum file that
# share one timestamp. Names sort chronologically under LC_ALL=C.
prune() {
  local dir=$1 keep=$2 f s
  local files=()
  shopt -s nullglob
  files=("$dir"/bcm-db-*.age)
  shopt -u nullglob
  local n=${#files[@]}
  if (( n <= keep )); then return 0; fi
  for f in "${files[@]:0:n-keep}"; do
    s=${f##*/bcm-db-}
    s=${s%.sql.gz.age}
    log "pruning old set $s from $dir"
    rm -f "$dir/bcm-db-$s.sql.gz.age" "$dir/bcm-uploads-$s.tar.gz.age" "$dir/bcm-$s.sha256"
  done
}

for cmd in docker age gzip tar sha256sum flock; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done
grep -q '^age1' "$RECIPIENT_FILE" 2>/dev/null \
  || die "no age public key found in $RECIPIENT_FILE (see the setup notes at the top of this script)"
for c in "$MYSQL_CONTAINER" "$BACKEND_CONTAINER"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] \
    || die "container $c is not running"
done

mkdir -p "$BACKUP_DIR/daily" "$BACKUP_DIR/weekly"
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || die "another backup is already running"

# Same filesystem as the destination so the final mv is atomic: a crash can
# never leave a half-written backup looking like a complete one.
tmp="$(mktemp -d "$BACKUP_DIR/.tmp.XXXXXX")"

log "dumping database '$DB_NAME' from $MYSQL_CONTAINER"
# The root password is read from the container's own environment inside the
# container, so it never appears on this host's command line or in this script.
docker exec "$MYSQL_CONTAINER" sh -c '
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump --user=root \
    --single-transaction --quick --routines --triggers --events --hex-blob \
    --default-character-set=utf8mb4 --set-gtid-purged=OFF --databases "$1"' \
  sh "$DB_NAME" | gzip -9 > "$tmp/db.sql.gz"
# mysqldump ends a complete dump with a "-- Dump completed" line; it also
# forces a full read of the gzip stream, so this doubles as an integrity check.
gzip -dc "$tmp/db.sql.gz" | tail -n 1 | grep -q '^-- Dump completed' \
  || die "database dump looks truncated"

log "archiving uploaded files from $BACKEND_CONTAINER:$UPLOADS_PATH"
docker cp "$BACKEND_CONTAINER:$UPLOADS_PATH/." - | gzip -9 > "$tmp/uploads.tar.gz"
tar -tzf "$tmp/uploads.tar.gz" >/dev/null || die "uploads archive is not a valid tar.gz"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
db_out="bcm-db-$stamp.sql.gz.age"
up_out="bcm-uploads-$stamp.tar.gz.age"

log "encrypting"
age -R "$RECIPIENT_FILE" -o "$tmp/$db_out" "$tmp/db.sql.gz"
age -R "$RECIPIENT_FILE" -o "$tmp/$up_out" "$tmp/uploads.tar.gz"
rm -f "$tmp/db.sql.gz" "$tmp/uploads.tar.gz"
for f in "$tmp/$db_out" "$tmp/$up_out"; do
  [ "$(head -c 21 "$f")" = "age-encryption.org/v1" ] || die "$f is not an age file"
done
(cd "$tmp" && sha256sum "$db_out" "$up_out" > "bcm-$stamp.sha256")

mv "$tmp/$db_out" "$tmp/$up_out" "$tmp/bcm-$stamp.sha256" "$BACKUP_DIR/daily/"
is_weekly="no"
if [ "$(date -u +%u)" = "$WEEKLY_DAY" ]; then
  is_weekly="yes"
  ln -f "$BACKUP_DIR/daily/$db_out" "$BACKUP_DIR/daily/$up_out" "$BACKUP_DIR/daily/bcm-$stamp.sha256" "$BACKUP_DIR/weekly/"
fi
prune "$BACKUP_DIR/daily" "$KEEP_DAILY"
prune "$BACKUP_DIR/weekly" "$KEEP_WEEKLY"

log "backup OK: $db_out ($(du -h "$BACKUP_DIR/daily/$db_out" | cut -f1)), $up_out ($(du -h "$BACKUP_DIR/daily/$up_out" | cut -f1))"

# Off-site copy hook. Until offsite.sh exists the data lives ONLY on this VM,
# which does not protect against losing the VM -- the very risk backups are for.
if [ -f "$SCRIPT_DIR/offsite.sh" ]; then
  bash "$SCRIPT_DIR/offsite.sh" "$BACKUP_DIR/daily" "$stamp" "$is_weekly"
else
  log "WARNING: no offsite.sh configured -> this backup exists only on this VM"
fi
