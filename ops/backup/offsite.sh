#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Uploads one backup set to OCI Object Storage, so backups survive losing
# this VM entirely -- backup.sh alone only protects against losing the
# DATA, not the machine it runs on. Called automatically by backup.sh as:
#   offsite.sh <daily-dir> <stamp> <is_weekly:yes|no>
#
# Authenticates as the VM's own OCI identity (Instance Principal): no
# access keys are stored anywhere on this host, so there is nothing here
# for an attacker to steal that would work from a different machine. The
# dynamic group + policy granting that identity write access to ONLY this
# bucket's objects (never bucket settings, never anything else in the
# tenancy) must already exist -- see the setup notes in backup.sh.
#
# Every object is re-downloaded right after upload and checksummed against
# the local file, catching silent corruption in transit instead of trusting
# a 200 OK. Uploads under "daily/"; also uploads a second copy under
# "weekly/" when is_weekly=yes, so the two prefixes can carry different
# lifecycle (auto-delete) rules in the bucket -- configure those once in
# the OCI console (Object Storage retention, not this script's job: the
# policy deliberately does not grant permission to change bucket settings).
#
# Env overrides: OCI_BIN (path to the oci CLI venv binary), OFFSITE_BUCKET
# (default bcm-backups), OFFSITE_AUTH (default instance_principal, override
# only for local testing off the VM).

set -euo pipefail
umask 077
export LC_ALL=C

DAILY_DIR="${1:?usage: offsite.sh <daily-dir> <stamp> <is_weekly:yes|no>}"
STAMP="${2:?usage: offsite.sh <daily-dir> <stamp> <is_weekly:yes|no>}"
IS_WEEKLY="${3:-no}"

OCI_BIN="${OCI_BIN:-$HOME/.oci-cli-venv/bin/oci}"
BUCKET="${OFFSITE_BUCKET:-bcm-backups}"
AUTH="${OFFSITE_AUTH:-instance_principal}"

log() { printf '%s offsite: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

command -v "$OCI_BIN" >/dev/null 2>&1 || die "oci CLI not found at $OCI_BIN"
command -v sha256sum >/dev/null 2>&1 || die "missing required command: sha256sum"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

NAMESPACE="$("$OCI_BIN" os ns get --auth "$AUTH" --raw-output --query data 2>/dev/null)" \
  || die "could not resolve the Object Storage namespace (instance principal auth broken?)"
[ -n "$NAMESPACE" ] || die "empty namespace returned"

# Uploads $1 as object $2, then immediately downloads it back and compares
# a sha256 of the two copies -- proof the bytes that landed in the bucket
# are the same ones that left this host, not just that the API said OK.
upload_and_verify() {
  local src=$1 name=$2 local_sum remote_sum
  local_sum=$(sha256sum "$src" | cut -d' ' -f1)
  log "uploading $name"
  "$OCI_BIN" os object put --bucket-name "$BUCKET" --namespace "$NAMESPACE" \
    --file "$src" --name "$name" --auth "$AUTH" --force >/dev/null
  "$OCI_BIN" os object get --bucket-name "$BUCKET" --namespace "$NAMESPACE" \
    --name "$name" --file "$tmp/verify" --auth "$AUTH" >/dev/null
  remote_sum=$(sha256sum "$tmp/verify" | cut -d' ' -f1)
  rm -f "$tmp/verify"
  [ "$local_sum" = "$remote_sum" ] \
    || die "$name: checksum mismatch after upload (local=$local_sum remote=$remote_sum)"
}

for f in "bcm-db-$STAMP.sql.gz.age" "bcm-uploads-$STAMP.tar.gz.age" "bcm-$STAMP.sha256"; do
  [ -f "$DAILY_DIR/$f" ] || die "expected file missing: $DAILY_DIR/$f"
  upload_and_verify "$DAILY_DIR/$f" "daily/$f"
  if [ "$IS_WEEKLY" = "yes" ]; then
    upload_and_verify "$DAILY_DIR/$f" "weekly/$f"
  fi
done

extra=""
[ "$IS_WEEKLY" = "yes" ] && extra=" and weekly/"
log "offsite copy OK (bcm-*-$STAMP.* in daily/$extra), verified byte-for-byte"
