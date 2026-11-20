#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Keeps a recovery copy of the keys (OWASP Database Security, key management):
# without secrets/ a restored backup is a database whose two-factor secrets no
# one can read, and a stack that does not start. This archives secrets/ and
# .env, encrypts them with age to ops/secrets/recovery-recipient.pub -- a key
# pair of its own, NOT the backups' one, its private half kept off this host
# by the owner -- and uploads the result to the backups bucket under recovery/,
# checked byte-for-byte after the upload, as offsite.sh does.
#
# The backups and this bundle are protected separately: the backup key opens
# the data and nothing else, the recovery key the keys and nothing else.
#
# Run from this repository's root after any secret changes (a rotation, a new
# secret) and in the monthly maintenance; ops/maintenance/check-encryption.sh
# fails while a secret is newer than the latest bundle.
#
# Restore, on a new host, with the recovery private key:
#   age -d -i KEY bcm-recovery-<stamp>.tar.gz.age | tar -xz -C bcm-v2-docker
#
# Environment overrides (optional): RECOVERY_DIR, KEEP_LOCAL, OCI_BIN,
# OFFSITE_BUCKET, OFFSITE_AUTH; OFFSITE=no keeps the bundle local only.

set -euo pipefail
umask 077
export LC_ALL=C

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
RECIPIENT="ops/secrets/recovery-recipient.pub"
RECOVERY_DIR="${RECOVERY_DIR:-$HOME/backups/recovery}"
KEEP_LOCAL="${KEEP_LOCAL:-3}"
OCI_BIN="${OCI_BIN:-$HOME/.oci-cli-venv/bin/oci}"
BUCKET="${OFFSITE_BUCKET:-bcm-backups}"
AUTH="${OFFSITE_AUTH:-instance_principal}"
OFFSITE="${OFFSITE:-yes}"

log() { printf '%s recovery: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

command -v age >/dev/null 2>&1 || die "age not installed"
[ -f "$RECIPIENT" ] || die "$RECIPIENT not found: put the recovery PUBLIC key there"
grep -q '^age1' "$RECIPIENT" && ! grep -q 'AGE-SECRET-KEY' "$RECIPIENT" \
    || die "$RECIPIENT must hold one public age key (age1...), never a private one"
cmp -s "$RECIPIENT" ops/backup/backup-recipient.pub \
    && die "the recovery key must not be the backup key: generate a pair of its own"
[ -d "$SECRETS_DIR" ] || die "$SECRETS_DIR not found"
[ -f .env ] || die ".env not found (run from the repository root)"

mkdir -p "$RECOVERY_DIR"
chmod 700 "$RECOVERY_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$RECOVERY_DIR/bcm-recovery-$stamp.tar.gz.age"

# Straight from tar to age: the archive in clear never touches the disk.
tar -czf - --exclude='.tmp.*' "$SECRETS_DIR" .env | age -R "$RECIPIENT" -o "$out.partial"
mv -f "$out.partial" "$out"
log "bundle written: ${out##*/} ($(du -h "$out" | cut -f1))"

if [ "$OFFSITE" = "yes" ]; then
    command -v "$OCI_BIN" >/dev/null 2>&1 || die "oci CLI not found at $OCI_BIN"
    ns="$("$OCI_BIN" os ns get --auth "$AUTH" --raw-output --query data 2>/dev/null)" \
        || die "could not resolve the Object Storage namespace"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    "$OCI_BIN" os object put --bucket-name "$BUCKET" --namespace "$ns" --auth "$AUTH" \
        --file "$out" --name "recovery/${out##*/}" >/dev/null
    "$OCI_BIN" os object get --bucket-name "$BUCKET" --namespace "$ns" --auth "$AUTH" \
        --name "recovery/${out##*/}" --file "$tmp/verify" >/dev/null
    [ "$(sha256sum < "$out")" = "$(sha256sum < "$tmp/verify")" ] || die "checksum mismatch after upload"
    log "offsite copy OK (recovery/${out##*/}), verified byte-for-byte"
fi

# Older local bundles: only the newest few are kept here; the bucket keeps its own.
find "$RECOVERY_DIR" -maxdepth 1 -name 'bcm-recovery-*.tar.gz.age' -printf '%T@ %p\n' \
    | sort -rn | tail -n +"$((KEEP_LOCAL + 1))" | cut -d' ' -f2- | xargs -r rm -f
