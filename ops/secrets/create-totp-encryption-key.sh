#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Creates the Docker secret TOTP_ENCRYPTION_KEY (secrets/TOTP_ENCRYPTION_KEY):
# the AES-256 key the backend encrypts the two-factor secrets with, of its
# own and never derived from JWT_SECRET (OWASP Secrets Management Cheat
# Sheet). At the next start the backend re-encrypts the secrets already
# stored under it (TotpKeyMigration).
#
# Run from the bcm-v2-docker root. Safe to run again: a key already there
# (in its file, or still in .env before ops/secrets/move-secrets-from-env.sh)
# is kept, since replacing it would make every two-factor secret stored
# under it unreadable. The key is never printed and never passed on a
# command line.
#
# Environment overrides (optional): ENV_FILE, SECRETS_DIR.

set -euo pipefail
umask 077

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

command -v openssl >/dev/null || { echo "ERROR: openssl not found" >&2; exit 1; }

if [ -n "$(secret_read TOTP_ENCRYPTION_KEY)" ]; then
    echo "TOTP_ENCRYPTION_KEY already exists: kept as it is"
    exit 0
fi

openssl rand -base64 32 | tr -d '\n' | secret_write TOTP_ENCRYPTION_KEY
echo "Created $SECRETS_DIR/TOTP_ENCRYPTION_KEY (32 random bytes, Base64)"
