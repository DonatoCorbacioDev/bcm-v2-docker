#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Keeps a copy of the backups OUTSIDE Oracle Cloud, on the owner's computer:
# the VM and the bucket share one cloud account, so losing that account (closed,
# suspended, taken over) would lose both at once. Run monthly, on the owner's
# computer (Git Bash on Windows), before the restore test:
#
#   bash ops/backup/fetch-copy.sh <dest-dir>
#
# Downloads the newest backup set (database, uploads, checksums) and the newest
# recovery bundle of the secrets into <dest-dir>/<stamp>/, checks every file
# against the VM's own SHA-256, and keeps the newest KEEP sets there. Every file
# is age-encrypted: useless without the private keys, which are kept apart.
# Then, from the same folder:
#   bash ops/backup/restore-test.sh --key <backup key> --db <dest>/<stamp>/bcm-db-*.age --uploads ...
#
# Environment overrides (optional): VM (default ubuntu@204.216.211.182),
# SSH_KEY (default ~/.ssh/bcm_prod_key), KEEP (default 3).

set -euo pipefail
umask 077
export LC_ALL=C

DEST="${1:?usage: fetch-copy.sh <dest-dir>}"
VM="${VM:-ubuntu@204.216.211.182}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/bcm_prod_key}"
KEEP="${KEEP:-3}"
SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes "$VM")

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || die "missing required command: sha256sum"

# The newest set and bundle, and their checksums, computed on the VM.
listing="$("${SSH[@]}" 'set -e
  db=$(ls -t ~/backups/bcm/daily/bcm-db-*.sql.gz.age | head -1)
  stamp=${db##*/bcm-db-}; stamp=${stamp%.sql.gz.age}
  rb=$(ls -t ~/backups/recovery/bcm-recovery-*.tar.gz.age | head -1)
  echo "$stamp"
  cd ~/backups/bcm/daily && sha256sum "bcm-db-$stamp.sql.gz.age" "bcm-uploads-$stamp.tar.gz.age"
  cd ~/backups/recovery && sha256sum "${rb##*/}"')" || die "could not read the backups on $VM"
stamp="$(printf '%s\n' "$listing" | head -1)"
[[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "unexpected backup name on the VM: $stamp"
sums="$(printf '%s\n' "$listing" | tail -n +2)"

out="$DEST/$stamp"
if [ -f "$out/SHA256SUMS" ] && (cd "$out" && sha256sum -c --quiet SHA256SUMS); then
  log "copy $stamp already here and intact: $out"
else
  mkdir -p "$out"
  while read -r _ file; do
    case "$file" in
      bcm-recovery-*) src="~/backups/recovery/$file" ;;
      *) src="~/backups/bcm/daily/$file" ;;
    esac
    scp -q -i "$SSH_KEY" -o BatchMode=yes "$VM:$src" "$out/$file" || die "download failed: $file"
  done <<< "$sums"
  printf '%s\n' "$sums" > "$out/SHA256SUMS"
  (cd "$out" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch in $out: download again"
  log "copy $stamp written and verified: $out"
fi
ls "$out" | sed 's/^/  /'

# Older copies: the newest KEEP stay.
find "$DEST" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{8}T[0-9]{6}Z' -printf '%f\n' \
  | sort -r | tail -n +"$((KEEP + 1))" | while read -r old; do rm -rf "${DEST:?}/$old"; log "removed old copy $old"; done
