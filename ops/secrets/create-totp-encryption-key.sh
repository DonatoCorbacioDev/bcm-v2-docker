#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Adds TOTP_ENCRYPTION_KEY to .env: the AES-256 key the backend encrypts the
# two-factor secrets with, of its own and never derived from JWT_SECRET
# (OWASP Secrets Management Cheat Sheet). At the next start the backend
# re-encrypts the secrets already stored under it (TotpKeyMigration).
#
# Run once, from the bcm-v2-docker root, before deploying the backend that
# requires it. Safe to run again: a key already in .env is kept, since
# replacing it would make every two-factor secret stored under it unreadable.
# The key is never printed and never passed on a command line.
#
# Environment override (optional): ENV_FILE.

set -euo pipefail
umask 077

ENV_FILE="${ENV_FILE:-.env}"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (run from the bcm-v2-docker root)" >&2; exit 1; }
command -v openssl >/dev/null || { echo "ERROR: openssl not found" >&2; exit 1; }

if grep -qE '^TOTP_ENCRYPTION_KEY=.+' "$ENV_FILE"; then
    echo "TOTP_ENCRYPTION_KEY already in $ENV_FILE: kept as it is"
    exit 0
fi

key="$(openssl rand -base64 32)"
{
    grep -vE '^TOTP_ENCRYPTION_KEY=' "$ENV_FILE" || true
    printf 'TOTP_ENCRYPTION_KEY=%s\n' "$key"
} > "$ENV_FILE.new"
unset key
chmod --reference="$ENV_FILE" "$ENV_FILE.new" 2>/dev/null || chmod 600 "$ENV_FILE.new"
mv "$ENV_FILE.new" "$ENV_FILE"
echo "Added TOTP_ENCRYPTION_KEY to $ENV_FILE (32 random bytes, Base64)"
