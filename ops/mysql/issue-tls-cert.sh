#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Issues MySQL's TLS certificate (OWASP Database Security, secure connections:
# verify the server's certificate and its identity). A new CA signs a server
# certificate naming the hosts the services connect to (mysql, bcm-mysql), so
# the clients check both the chain and the name (sslMode=VERIFY_IDENTITY): a
# server holding any other certificate, a man in the middle included, is
# refused. The CA's private key exists only for the signature, in a temporary
# directory, and is deleted right after: nobody, not even a compromised MySQL,
# can sign another certificate it would trust. Renewing issues a new CA too.
#
# Writes, as Docker secrets (docker-compose.prod.yml):
#   MYSQL_SERVER_KEY, MYSQL_SERVER_CERT  for mysql;
#   MYSQL_CA_CERT                        for ml (PEM);
#   MYSQL_TRUSTSTORE                     for the backend and migrate (PKCS12;
#                                        its password, public-ca-only, protects
#                                        nothing: only the public CA is in it).
#
# Both certificates are valid for DAYS (default 730, two years);
# ops/mysql/check-privileges.sh fails 30 days before the server's expires.
# Run on the production VM, from this repository's root:
#   bash ops/mysql/issue-tls-cert.sh
# then recreate mysql and every service that connects to it, together:
#   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d mysql migrate backend ml
#
# Environment overrides (optional): DAYS, BACKEND_IMAGE.

set -euo pipefail
umask 077

# shellcheck source=../secrets/lib.sh
source "$(dirname "$0")/../secrets/lib.sh"
DAYS="${DAYS:-730}"
BACKEND_IMAGE="${BACKEND_IMAGE:-bcm-v2-docker-backend}"
STORE_PASSWORD="public-ca-only"
[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "ERROR: DAYS must be a number" >&2; exit 1; }
command -v openssl >/dev/null || { echo "ERROR: openssl is needed" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The CA: an EC P-256 key, a self-signed certificate allowed only to sign.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/ca.key" 2>/dev/null
openssl req -x509 -new -key "$work/ca.key" -sha256 -days "$DAYS" \
    -subj "/CN=BCM MySQL CA $(date -u +%Y-%m-%d)" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$work/ca.pem"

# The server: its own key, a certificate for TLS servers only, naming its hosts.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/server.key" 2>/dev/null
openssl req -new -key "$work/server.key" -subj "/CN=mysql" -out "$work/server.csr"
printf '%s\n' \
    "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" \
    "subjectAltName=DNS:mysql,DNS:bcm-mysql" > "$work/server.ext"
openssl x509 -req -in "$work/server.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" -CAcreateserial \
    -sha256 -days "$DAYS" -extfile "$work/server.ext" -out "$work/server.pem" 2>/dev/null

# The CA's key is not needed any more, and must not survive.
rm -f "$work/ca.key" "$work/ca.srl"
openssl verify -CAfile "$work/ca.pem" "$work/server.pem" >/dev/null \
    || { echo "ERROR: the server certificate does not verify against the new CA" >&2; exit 1; }

# The JVM's truststore, built by keytool from the backend's own image: the CA in
# on stdin, the store back on stdout, no file of this host mounted.
docker run --rm -i --entrypoint sh "$BACKEND_IMAGE" -c \
    "cat > /tmp/ca.pem && keytool -importcert -noprompt -alias mysql-ca -file /tmp/ca.pem \
     -keystore /tmp/store.p12 -storetype PKCS12 -storepass $STORE_PASSWORD >/dev/null 2>&1 && cat /tmp/store.p12" \
    < "$work/ca.pem" > "$work/store.p12"
[ -s "$work/store.p12" ] || { echo "ERROR: the truststore could not be built" >&2; exit 1; }

secret_write MYSQL_SERVER_KEY < "$work/server.key"
secret_write MYSQL_SERVER_CERT < "$work/server.pem"
secret_write MYSQL_CA_CERT < "$work/ca.pem"
secret_write MYSQL_TRUSTSTORE < "$work/store.p12"

echo "Issued MySQL's TLS certificate (the CA's key is already deleted):"
openssl x509 -in "$work/server.pem" -noout -subject -issuer -enddate -ext subjectAltName | sed 's/^/  /'
echo "Next: docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d mysql migrate backend ml"
