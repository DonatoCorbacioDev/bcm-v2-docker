#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# A copy of the VM's logs outside the VM (OWASP ASVS 16.4.3: logs kept on a
# separate system). The journal holds every container's log (journald driver)
# and the host's own: SSH sign-ins, sudo, Docker, the automatic updates. On the
# VM alone, whoever takes it could erase what they did; a copy taken every
# night, encrypted with the backups' age key and put in the backups bucket,
# where the VM may only add objects and none can be deleted for 7 days, stays.
#
# The last 25 hours (one of overlap, so a late run loses nothing), as JSON, one
# entry per line, gzip, age: logs/bcm-logs-<stamp>.json.gz.age, verified byte
# for byte after the upload as offsite.sh does. Nothing readable stays on disk.
# Read back off the VM with the backup key:
#   age -d -i bcm-backup-key.txt bcm-logs-<stamp>.json.gz.age | gunzip | jq -r '.MESSAGE'
#
# Cron on the VM, after the nightly backup (ops/host/crontab.example):
#   30 1 * * * /bin/bash /home/ubuntu/bcm-v2/bcm-v2-docker/ops/backup/logs-offsite.sh >> /home/ubuntu/backups/logs-offsite.log 2>&1
# ops/maintenance/check-config.sh fails when the last copy is older than 26 hours.
#
# Environment overrides (optional): RECIPIENT_FILE, OCI_BIN, OFFSITE_BUCKET, OFFSITE_AUTH, SINCE.

set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPIENT_FILE="${RECIPIENT_FILE:-$SCRIPT_DIR/backup-recipient.pub}"
OCI_BIN="${OCI_BIN:-$HOME/.oci-cli-venv/bin/oci}"
BUCKET="${OFFSITE_BUCKET:-bcm-backups}"
AUTH="${OFFSITE_AUTH:-instance_principal}"
SINCE="${SINCE:--25 hours}"

log() { printf '%s logs-offsite: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

for cmd in journalctl gzip age sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done
command -v "$OCI_BIN" >/dev/null 2>&1 || die "oci CLI not found at $OCI_BIN"
grep -q '^age1' "$RECIPIENT_FILE" 2>/dev/null || die "no age public key in $RECIPIENT_FILE"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
name="bcm-logs-$stamp.json.gz.age"

log "exporting the journal since '$SINCE'"
journalctl --since "$SINCE" --output=json --no-pager | gzip > "$tmp/logs.json.gz"
gzip -t "$tmp/logs.json.gz" || die "the export is not a valid gzip"
[ "$(gzip -dc "$tmp/logs.json.gz" | head -c 1)" = "{" ] || die "the journal export is empty: is ubuntu in the adm group?"

age -R "$RECIPIENT_FILE" -o "$tmp/$name" "$tmp/logs.json.gz"
rm -f "$tmp/logs.json.gz"
[ "$(head -c 21 "$tmp/$name")" = "age-encryption.org/v1" ] || die "$name is not an age file"

NAMESPACE="$("$OCI_BIN" os ns get --auth "$AUTH" --raw-output --query data 2>/dev/null)" \
    || die "could not resolve the Object Storage namespace (instance principal auth broken?)"
[ -n "$NAMESPACE" ] || die "empty namespace returned"

local_sum=$(sha256sum "$tmp/$name" | cut -d' ' -f1)
"$OCI_BIN" os object put --bucket-name "$BUCKET" --namespace "$NAMESPACE" \
    --file "$tmp/$name" --name "logs/$name" --auth "$AUTH" >/dev/null
"$OCI_BIN" os object get --bucket-name "$BUCKET" --namespace "$NAMESPACE" \
    --name "logs/$name" --file "$tmp/verify" --auth "$AUTH" >/dev/null
remote_sum=$(sha256sum "$tmp/verify" | cut -d' ' -f1)
[ "$local_sum" = "$remote_sum" ] || die "logs/$name: checksum mismatch after upload"

log "logs offsite OK: logs/$name ($(du -h "$tmp/$name" | cut -f1)), verified byte-for-byte"
