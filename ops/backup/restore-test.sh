#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Restores a BCM backup into a THROWAWAY MySQL container and checks the result.
# It never touches the real database: the container has no published ports,
# no persistent volume, and is destroyed when the script ends. A backup that
# has never been restored is not a verified backup -- run this after setting
# backups up, and again from time to time.
#
# Run it where the PRIVATE key lives (your own computer), not on the VM:
#   scp the .age files from the VM, then
#   ./restore-test.sh --key bcm-backup-key.txt \
#       --db bcm-db-<stamp>.sql.gz.age --uploads bcm-uploads-<stamp>.tar.gz.age
#
# Optional, to compare against a live source (exact only if nothing changed
# since the backup; on a busy database expect small differences in tables like
# audit_logs and notifications):
#   --compare-mysql <container>      row counts per table
#   --compare-backend <container>    number of files and total bytes in uploads
#
# DISASTER RECOVERY (real restore on a fresh host): start the stack with
# docker compose so MySQL creates the application user from .env, then run
# the same decrypt pipeline into the real container instead of the throwaway:
#   age -d -i KEY bcm-db-<stamp>.sql.gz.age | gunzip | docker exec -i bcm-mysql mysql -uroot -p
#   age -d -i KEY bcm-uploads-<stamp>.tar.gz.age | tar -xz -C <dir>  (then copy into the uploads volume)
# The dump contains only the application database, not MySQL accounts.
#
# Needs: docker, age, gunzip, tar, diff. Environment: DB_NAME (default bcm),
# READY_TIMEOUT (seconds to wait for the throwaway MySQL, default 180),
# MYSQL_IMAGE (default mysql:8.0, keep it equal to production's).

set -euo pipefail
umask 077
export LC_ALL=C

DB_NAME="${DB_NAME:-bcm}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
KEY="" DB="" UPLOADS="" COMPARE_MYSQL="" COMPARE_BACKEND=""
name="bcm-restore-test-$$"
tmp=""

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
usage() {
  sed -n '6,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY="${2:-}"; shift 2 ;;
    --db) DB="${2:-}"; shift 2 ;;
    --uploads) UPLOADS="${2:-}"; shift 2 ;;
    --compare-mysql) COMPARE_MYSQL="${2:-}"; shift 2 ;;
    --compare-backend) COMPARE_BACKEND="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$KEY" ] && [ -n "$DB" ] || usage
for f in "$KEY" "$DB"; do [ -f "$f" ] || die "file not found: $f"; done
if [ -n "$UPLOADS" ]; then [ -f "$UPLOADS" ] || die "file not found: $UPLOADS"; fi
for cmd in docker age gunzip tar diff; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

tmp="$(mktemp -d)"

# Row count of every base table of database $2 in container $1, as
# "table<TAB>rows". The loop runs inside the container so nothing about the
# credentials passes through this script.
table_counts() {
  docker exec "$1" sh -c '
    export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
    for t in $(mysql -uroot -N -B -e "SELECT table_name FROM information_schema.tables WHERE table_schema=\"$0\" AND table_type=\"BASE TABLE\""); do
      printf "%s\t%s\n" "$t" "$(mysql -uroot -N -B -e "SELECT COUNT(*) FROM \`$0\`.\`$t\`")"
    done' "$2" | sort
}

# Number of files and total bytes under directory $1 inside container $2.
uploads_summary() {
  docker exec "$1" sh -c '
    printf "files\t%s\n" "$(find "$0" -type f | wc -l | tr -d " ")"
    printf "bytes\t%s\n" "$(find "$0" -type f -exec cat {} + | wc -c | tr -d " ")"' "$2"
}

log "starting throwaway $MYSQL_IMAGE container $name"
docker run -d --rm --name "$name" -e MYSQL_ALLOW_EMPTY_PASSWORD=yes "$MYSQL_IMAGE" \
  --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci >/dev/null
ready=""
deadline=$((SECONDS + READY_TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  # Over TCP on purpose: the image's temporary init server has networking off,
  # so a TCP ping only succeeds once the real server is up.
  if docker exec "$name" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
if [ -z "$ready" ]; then
  docker logs --tail 15 "$name" >&2 || true
  die "throwaway MySQL did not become ready within ${READY_TIMEOUT}s (slow or overloaded host? raise READY_TIMEOUT)"
fi

log "decrypting and loading the database dump (no plaintext is written to disk)"
age -d -i "$KEY" "$DB" | gunzip | docker exec -i "$name" mysql -uroot --default-character-set=utf8mb4

table_counts "$name" "$DB_NAME" > "$tmp/counts.restored"
tables=$(wc -l < "$tmp/counts.restored" | tr -d ' ')
rows=$(awk -F'\t' '{s+=$2} END{print s+0}' "$tmp/counts.restored")
[ "$tables" -gt 0 ] || die "restore produced no tables in database '$DB_NAME'"
log "restored $tables tables, $rows rows in total"
docker exec "$name" mysql -uroot -N -B -e \
  "SELECT CONCAT('latest Flyway migration: V', MAX(CAST(version AS UNSIGNED)), ' (', COUNT(*), ' applied)') FROM \`$DB_NAME\`.flyway_schema_history WHERE success = 1" \
  | while read -r line; do log "$line"; done

if [ -n "$COMPARE_MYSQL" ]; then
  table_counts "$COMPARE_MYSQL" "$DB_NAME" > "$tmp/counts.source"
  diff -u "$tmp/counts.source" "$tmp/counts.restored" || die "row counts differ from $COMPARE_MYSQL"
  log "row counts identical to $COMPARE_MYSQL"
fi

if [ -n "$UPLOADS" ]; then
  log "decrypting and unpacking the uploaded files"
  mkdir -p "$tmp/uploads"
  age -d -i "$KEY" "$UPLOADS" | tar -xz -C "$tmp/uploads"
  files=$(find "$tmp/uploads" -type f | wc -l | tr -d ' ')
  bytes=$(find "$tmp/uploads" -type f -exec cat {} + | wc -c | tr -d ' ')
  log "restored $files files, $bytes bytes"
  if [ -n "$COMPARE_BACKEND" ]; then
    printf 'files\t%s\nbytes\t%s\n' "$files" "$bytes" > "$tmp/uploads.restored"
    uploads_summary "$COMPARE_BACKEND" /app/uploads > "$tmp/uploads.source"
    diff -u "$tmp/uploads.source" "$tmp/uploads.restored" || die "uploads differ from $COMPARE_BACKEND"
    log "uploads identical to $COMPARE_BACKEND"
  fi
fi

log "RESTORE OK"
