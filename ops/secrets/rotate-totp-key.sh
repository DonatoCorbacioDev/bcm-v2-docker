#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Rotates TOTP_ENCRYPTION_KEY, the key two-factor secrets are encrypted with at
# rest (OWASP Database Security, key rotation), without anyone losing 2FA:
#
#   1. bash ops/secrets/rotate-totp-key.sh
#        the current key becomes TOTP_ENCRYPTION_KEY_PREVIOUS, a new random one
#        TOTP_ENCRYPTION_KEY (32 bytes, Base64; neither is printed);
#   2. docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-deps backend
#        the backend reads every secret with either key and re-encrypts, once,
#        those only the previous key opens (TotpKeyMigration, in its log);
#   3. bash ops/secrets/rotate-totp-key.sh --finish
#        checks nothing is left under the previous key, then empties it;
#   4. up -d --no-deps backend again, and back up: the database now needs the
#      new key, and the recovery bundle must hold it (ops/secrets/recovery-bundle.sh).
#
# Run from this repository's root, after a backup. Environment override
# (optional): BACKEND_CONTAINER.

set -euo pipefail
umask 077

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
BACKEND_CONTAINER="${BACKEND_CONTAINER:-bcm-backend}"

if [ "${1:-}" = "--finish" ]; then
    [ -s "$SECRETS_DIR/TOTP_ENCRYPTION_KEY_PREVIOUS" ] || { echo "No rotation in progress: TOTP_ENCRYPTION_KEY_PREVIOUS is empty"; exit 0; }
    # The backend logs the outcome at startup; a failure there means values it
    # could not open with either key, which emptying the previous key would lose.
    logs="$(docker logs "$BACKEND_CONTAINER" 2>&1)" \
        || { echo "ERROR: cannot read the logs of $BACKEND_CONTAINER: restart the backend first; the previous key stays" >&2; exit 1; }
    if printf '%s\n' "$logs" | grep -q "re-encrypted under TOTP_ENCRYPTION_KEY: [0-9]* done, [1-9][0-9]* failed"; then
        echo "ERROR: the backend could not re-encrypt some two-factor secrets (see its log): the previous key stays" >&2
        exit 1
    fi
    : | secret_write TOTP_ENCRYPTION_KEY_PREVIOUS
    echo "TOTP_ENCRYPTION_KEY_PREVIOUS emptied. Next: up -d --no-deps backend, a backup, ops/secrets/recovery-bundle.sh"
    exit 0
fi
[ -z "${1:-}" ] || { echo "Usage: $0 [--finish]" >&2; exit 1; }

current="$(secret_read TOTP_ENCRYPTION_KEY)"
[ -n "$current" ] || { echo "ERROR: no TOTP_ENCRYPTION_KEY to rotate (ops/secrets/create-totp-encryption-key.sh)" >&2; exit 1; }
[ ! -s "$SECRETS_DIR/TOTP_ENCRYPTION_KEY_PREVIOUS" ] \
    || { echo "ERROR: a rotation is already in progress: finish it first (--finish)" >&2; exit 1; }

printf '%s' "$current" | secret_write TOTP_ENCRYPTION_KEY_PREVIOUS
openssl rand -base64 32 | tr -d '\n' | secret_write TOTP_ENCRYPTION_KEY
unset current
echo "TOTP_ENCRYPTION_KEY rotated: the old one is now TOTP_ENCRYPTION_KEY_PREVIOUS (neither printed)."
echo "Next: docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-deps backend"
echo "Then: bash $0 --finish"
