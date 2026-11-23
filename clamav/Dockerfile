# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.

# The official ClamAV 1.5 image with the base system's packages brought up to
# date. ClamAV rebuilds its image only with a new release of its own, so Debian's
# fixes can wait weeks there: the image scan found 14 Kerberos vulnerabilities
# (krb5, fixed in Debian 13.8) in 1.5.4 on 2026-11-23. Rebuilt with every deploy
# and by every weekly image scan, it carries Debian's fixes from the day they
# are published, as mysql/Dockerfile does for MySQL.
# Nothing else changes: same ClamAV, same init, which starts as root and runs
# clamd and freshclam as the clamav user (docker-compose.yml).
FROM clamav/clamav:1.5.5-debian

RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
