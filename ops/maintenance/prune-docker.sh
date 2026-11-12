#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Frees the disk Docker fills on every deploy (OWASP API4): `up --build`
# rebuilds the images from source and keeps every old layer in the build
# cache, which had grown to 66 GB of a 96 GB disk by 2026-11-12. Removes only
# build cache older than three days and images no container uses: the running
# stack, its volumes (the database) and the last deploy's cache stay.
#
#   bash ops/maintenance/prune-docker.sh            # after a deploy, or weekly from cron:
#   0 5 * * SUN  /bin/bash ~/bcm-v2/bcm-v2-docker/ops/maintenance/prune-docker.sh >> ~/prune-docker.log 2>&1
set -euo pipefail

echo "[$(date -u +%FT%TZ)] disk before: $(df -h / | awk 'NR==2 {print $5 " used, " $4 " free"}')"
docker builder prune --force --filter "until=72h" > /dev/null
docker image prune --force > /dev/null
echo "[$(date -u +%FT%TZ)] disk after:  $(df -h / | awk 'NR==2 {print $5 " used, " $4 " free"}')"
