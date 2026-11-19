#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Hands the services the certificate to check MySQL's against (OWASP Database
# Security, TLS): MySQL generated its own CA on the data volume (ca.pem, valid
# ten years) and signed the server's certificate with it. This copies that CA
# certificate, which is public, to secrets/MYSQL_CA_CERT (PEM, for ml) and
# secrets/MYSQL_TRUSTSTORE (PKCS12, for the backend and migrate: the JVM's
# driver reads only a keystore; its password, public-ca-only in the JDBC URL,
# protects nothing, the store holding only the public certificate). With them
# the connections are TLS with sslMode=VERIFY_CA: a server without the key of
# that CA, a man in the middle, is refused.
#
# The CA's private key never leaves the data volume. Run once, and again only if
# the data volume, and so the CA, is replaced. From this repository's root:
#   bash ops/mysql/export-ca.sh
# then recreate the services that connect: up -d migrate backend ml
#
# Environment overrides (optional): MYSQL_CONTAINER, BACKEND_IMAGE.

set -euo pipefail
umask 077

# shellcheck source=../secrets/lib.sh
source "$(dirname "$0")/../secrets/lib.sh"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
BACKEND_IMAGE="${BACKEND_IMAGE:-bcm-v2-docker-backend}"
STORE_PASSWORD="public-ca-only"

ca="$(mktemp)"
store="$(mktemp)"
trap 'rm -f "$ca" "$store"' EXIT
docker exec "$MYSQL_CONTAINER" cat /var/lib/mysql/ca.pem > "$ca"
head -1 "$ca" | grep -q -- "-----BEGIN CERTIFICATE-----" \
    || { echo "ERROR: no CA certificate read from $MYSQL_CONTAINER:/var/lib/mysql/ca.pem" >&2; exit 1; }
secret_write MYSQL_CA_CERT < "$ca"

# keytool from the backend's own image (the JRE the store is for); the CA goes
# in on stdin, the store comes back on stdout: no file of this host is mounted.
docker run --rm -i --entrypoint sh "$BACKEND_IMAGE" -c \
    "cat > /tmp/ca.pem && keytool -importcert -noprompt -alias mysql-ca -file /tmp/ca.pem \
     -keystore /tmp/store.p12 -storetype PKCS12 -storepass $STORE_PASSWORD >/dev/null 2>&1 && cat /tmp/store.p12" \
    < "$ca" > "$store"
[ -s "$store" ] || { echo "ERROR: the truststore could not be built" >&2; exit 1; }
secret_write MYSQL_TRUSTSTORE < "$store"

echo "Wrote $SECRETS_DIR/MYSQL_CA_CERT and $SECRETS_DIR/MYSQL_TRUSTSTORE from MySQL's CA:"
docker run --rm -i --entrypoint sh "$BACKEND_IMAGE" -c "cat > /tmp/ca.pem && keytool -printcert -file /tmp/ca.pem" \
    < "$ca" | grep -E "^(Owner|Valid|SHA256):" || true
