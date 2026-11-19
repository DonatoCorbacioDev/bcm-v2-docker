#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Gives Redis users and permissions (OWASP Database Security, authentication
# and least privilege; it held only rate-limit counters, open to every
# container on the data network). Writes two Docker secrets:
#   REDIS_PASSWORD  the backend's password (48 hex characters, never printed);
#   REDIS_ACL       Redis's ACL file, which holds only its SHA-256, not the
#                   password itself.
# The rules (the backend's RedisAclIT tests the same ones; keep them in step):
#   default  what any client gets before logging in: PING alone (the
#            healthcheck), no key read or written;
#   bcm      the backend's rate limiter: reading, writing and scripts (Bucket4j
#            runs a Lua script), never a dangerous command (FLUSHALL, CONFIG,
#            KEYS, DEBUG, SHUTDOWN...).
#
# Run once, and again to rotate the password. From this repository's root:
#   bash ops/redis/create-acl.sh
# then recreate Redis and the backend together:
#   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d redis backend

set -euo pipefail
umask 077

# shellcheck source=../secrets/lib.sh
source "$(dirname "$0")/../secrets/lib.sh"
USER_NAME="bcm"

password="$(openssl rand -hex 24)"
hash="$(printf '%s' "$password" | sha256sum | cut -d' ' -f1)"
printf '%s' "$password" | secret_write REDIS_PASSWORD
unset password
printf '%s\n' \
    "user default on nopass -@all +ping" \
    "user ${USER_NAME} on #${hash} ~* +@read +@write +@scripting +@connection -@dangerous" \
    | secret_write REDIS_ACL

echo "Wrote $SECRETS_DIR/REDIS_PASSWORD and $SECRETS_DIR/REDIS_ACL (user ${USER_NAME}, password not shown)."
echo "Next: docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d redis backend"
