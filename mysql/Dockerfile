# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.

# The official MySQL 8.4 LTS image (8.0 reached its end of life in April
# 2026 and gets no more fixes), minus two things the server never uses and
# that carried every known vulnerability left in it (Trivy, 2026-11-18):
# - MySQL Shell, a client tool with its own Python and libraries
#   (certifi, cryptography, pyOpenSSL);
# - gosu, which switches from root to the mysql user at start, built with an
#   old Go. docker-compose.yml starts the container as mysql (999) instead, so
#   the entrypoint never calls it, and the server needs no Linux capability.
FROM mysql:8.4.13

# The base system's packages brought up to date as well: Oracle publishes
# fixes before the official image is rebuilt (util-linux, Trivy, 2026-11-19).
RUN microdnf remove -y mysql-shell \
    && microdnf update -y \
    && microdnf clean all \
    && rm -f /usr/local/bin/gosu

# The healthcheck's own account, created with a new data volume.
COPY --chmod=644 healthcheck-account.sql /docker-entrypoint-initdb.d/10-healthcheck-account.sql

USER mysql
