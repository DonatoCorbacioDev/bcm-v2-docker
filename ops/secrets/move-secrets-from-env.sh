#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Moves the production secrets out of .env into Docker secrets: one file
# each in ./secrets (directory 700, files 444), which docker-compose.prod.yml
# mounts at /run/secrets/<NAME> (OWASP Secrets Management Cheat Sheet). Names
# and settings that are not secret (DB_USERNAME, MAIL_HOST...) stay in .env.
# ML_DB_URL, the ml service's whole connection string, is built here from
# ML_DB_USERNAME and ML_DB_PASSWORD.
#
# Run once on the production VM, from the bcm-v2-docker root, before the first
# deploy with docker secrets:
#   bash ops/secrets/move-secrets-from-env.sh
# A copy of .env as it was is kept in secrets/.env.before-move (600): delete
# it once the deploy is verified.
#
# Nothing is written until every required secret is found. Safe to run again:
# a secret already in its file is kept; the same name still in .env with a
# different value stops the script. Prints names and lengths, never a value.
#
# Environment overrides (optional): ENV_FILE, SECRETS_DIR.

set -euo pipefail
umask 077

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

REQUIRED=(DB_ROOT_PASSWORD DB_PASSWORD DB_APP_PASSWORD ML_DB_PASSWORD JWT_SECRET
          TOTP_ENCRYPTION_KEY ML_INTERNAL_API_KEY ML_CLAIMS_PRIVATE_KEY)
# Empty files when unset: docker-compose.prod.yml mounts them all.
OPTIONAL=(JWT_SECRET_PREVIOUS TOTP_ENCRYPTION_KEY_PREVIOUS MAIL_PASSWORD INTERNAL_ADMIN_API_KEY STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET)

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (run from the bcm-v2-docker root)" >&2; exit 1; }

# 1. Check everything before writing anything.
missing=()
for name in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
    from_env="$(env_value "$name")"
    if [ -f "$SECRETS_DIR/$name" ]; then
        if [ -n "$from_env" ] && [ "$from_env" != "$(cat "$SECRETS_DIR/$name")" ]; then
            echo "ERROR: $name is in $SECRETS_DIR/ and, with a different value, in $ENV_FILE: decide which one is right" >&2
            exit 1
        fi
    elif [ -z "$from_env" ] && [[ " ${REQUIRED[*]} " == *" $name "* ]]; then
        missing+=("$name")
    fi
done
ml_user="$(env_value ML_DB_USERNAME)"
[ -n "$ml_user" ] || missing+=("ML_DB_USERNAME")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: not found in $ENV_FILE nor in $SECRETS_DIR/: ${missing[*]} (nothing was changed)" >&2
    exit 1
fi
[[ "$ml_user" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ERROR: invalid ML_DB_USERNAME" >&2; exit 1; }

# 2. A copy of .env as it was, inside the 700 directory.
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
if [ ! -f "$SECRETS_DIR/.env.before-move" ]; then
    cp "$ENV_FILE" "$SECRETS_DIR/.env.before-move"
    chmod 600 "$SECRETS_DIR/.env.before-move"
fi

# 3. One file per secret (kept if already there).
for name in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
    [ -f "$SECRETS_DIR/$name" ] || env_value "$name" | secret_write "$name"
done
if [ ! -f "$SECRETS_DIR/ML_DB_URL" ]; then
    # Hex-only password (create-ml-readonly-user.sh): nothing to escape in the URL.
    { printf 'mysql+pymysql://%s:' "$ml_user"; cat "$SECRETS_DIR/ML_DB_PASSWORD"; printf '@mysql:3306/bcm'; } \
        | secret_write ML_DB_URL
fi

# 4. Out of .env.
pattern="^($(IFS='|'; echo "${REQUIRED[*]}|${OPTIONAL[*]}"))="
grep -vE "$pattern" "$ENV_FILE" > "$ENV_FILE.new" || true
chmod --reference="$ENV_FILE" "$ENV_FILE.new" 2>/dev/null || chmod 600 "$ENV_FILE.new"
mv "$ENV_FILE.new" "$ENV_FILE"

echo "Docker secrets in $SECRETS_DIR/ (name: length in characters):"
for name in "${REQUIRED[@]}" "${OPTIONAL[@]}" ML_DB_URL; do
    printf '  %s: %s\n' "$name" "$(wc -c < "$SECRETS_DIR/$name" | tr -d ' ')"
done
left="$(grep -cE "$pattern" "$ENV_FILE" || true)"
echo "Secret lines left in $ENV_FILE: ${left:-0}"
echo "Copy of the old $ENV_FILE: $SECRETS_DIR/.env.before-move (delete it once the deploy is verified)"
