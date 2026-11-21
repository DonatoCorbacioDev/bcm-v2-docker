-- Copyright (c) 2025 Donato Corbacio. All rights reserved.
-- Licensed under the terms of the LICENSE file at the repository root.
--
-- The account the container's healthcheck signs in with (docker-compose.yml).
-- A ping that fails to authenticate counted as a failed connection every 10
-- seconds, burying a real failed sign-in among thousands (Aborted_connects).
-- This one authenticates by who the process is, not by a password
-- (auth_socket): only the mysql OS user, on the local socket, so there is no
-- secret to store and nothing to steal over the network. It has no privilege
-- at all, not even on a table. In ops/mysql/expected-privileges.txt.
--
-- Run by the image's entrypoint when the data volume is created (the
-- Dockerfile copies it to /docker-entrypoint-initdb.d); on an existing volume,
-- ops/mysql/create-healthcheck-user.sh. The plugin is installed once and stays
-- (mysql.plugin), across restarts.
INSTALL PLUGIN auth_socket SONAME 'auth_socket.so';
CREATE USER IF NOT EXISTS 'bcm_health'@'localhost' IDENTIFIED WITH auth_socket AS 'mysql'
    WITH MAX_USER_CONNECTIONS 2;
