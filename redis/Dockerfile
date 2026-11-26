# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.

# The official Redis 7.4 image with the base system's packages brought up to
# date. Redis rebuilds its image only now and then, so Alpine's fixes can wait
# there: the image scan found a fixed OpenSSL vulnerability (libssl3) in
# redis:7-alpine, on Alpine 3.22.8, on 2026-11-26. Rebuilt with every deploy
# and by every weekly image scan, it carries Alpine's fixes from the day they
# are published, as mysql/Dockerfile and clamav/Dockerfile do.
# Nothing else changes: same Redis, same entrypoint, which starts as root and
# runs redis-server as the redis user (docker-compose.yml).
FROM redis:7.4.12-alpine

RUN apk upgrade --no-cache
