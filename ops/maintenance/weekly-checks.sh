#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# The weekly security checks, under one dead-man's switch: MySQL accounts,
# privileges and TLS certificate (ops/mysql/check-privileges.sh), encryption
# at rest and the keys (ops/maintenance/check-encryption.sh), then the
# configuration, the connections, the logs, the updates and the offsite copy
# (ops/maintenance/check-config.sh). All always run; HEALTHCHECK_URL
# (optional) is pinged on success and, with /fail, when any fails. Cron on the VM:
#   0 6 * * 1 HEALTHCHECK_URL=https://hc-ping.com/... /bin/bash /home/ubuntu/bcm-v2/bcm-v2-docker/ops/maintenance/weekly-checks.sh >> /home/ubuntu/backups/check-privileges.log 2>&1

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="${HEALTHCHECK_URL:-}"

status=0
HEALTHCHECK_URL="" bash "$HERE/../mysql/check-privileges.sh" || status=1
HEALTHCHECK_URL="" bash "$HERE/check-encryption.sh" || status=1
bash "$HERE/check-config.sh" || status=1

if [ -n "$URL" ]; then
    if [ "$status" -eq 0 ]; then
        curl -fsS -m 10 --retry 3 "$URL" >/dev/null 2>&1 || true
    else
        curl -fsS -m 10 --retry 3 "$URL/fail" >/dev/null 2>&1 || true
    fi
fi
exit "$status"
