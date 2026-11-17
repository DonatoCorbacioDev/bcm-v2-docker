# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Sourced by the ops scripts that create or read production secrets. In
# production each secret is a file, ./secrets/<NAME> (directory 700, files
# 444), mounted by docker-compose.prod.yml at /run/secrets/<NAME> in the
# containers that need it (OWASP Secrets Management Cheat Sheet). A value is
# never printed, never passed as a command argument (ps would show it) and
# never written anywhere else.

SECRETS_DIR="${SECRETS_DIR:-secrets}"
ENV_FILE="${ENV_FILE:-.env}"

# The value of NAME in .env, without a trailing CR or surrounding quotes;
# empty when the line is missing. Printed on stdout, for a pipe or $(...).
env_value() {
    local line value
    line="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 || true)"
    value="${line#*=}"
    [ -n "$line" ] || value=""
    value="${value%$'\r'}"
    if [ "${#value}" -ge 2 ]; then
        case "$value" in
            \"*\") value="${value:1:${#value}-2}" ;;
            \'*\') value="${value:1:${#value}-2}" ;;
        esac
    fi
    printf '%s' "$value"
}

# Secret NAME: its file, or .env before the move to files. Empty if neither.
secret_read() {
    if [ -f "$SECRETS_DIR/$1" ]; then
        cat "$SECRETS_DIR/$1"
    else
        env_value "$1"
    fi
}

# Writes secret NAME from stdin, replacing the file at once (a reader never
# sees half a value). Usage: printf '%s' "$value" | secret_write NAME
secret_write() {
    local name="$1" tmp
    [[ "$name" =~ ^[A-Z0-9_]+$ ]] || { echo "ERROR: invalid secret name" >&2; return 1; }
    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"
    tmp="$(mktemp "$SECRETS_DIR/.tmp.XXXXXX")"
    cat > "$tmp"
    # Readable inside the containers, which run as their own users; the
    # directory, 700, keeps every other account of the host out.
    chmod 444 "$tmp"
    mv -f "$tmp" "$SECRETS_DIR/$name"
}

# Sets NAME=value in .env for a setting that is not secret (a user name).
env_set() {
    local name="$1" value="$2"
    {
        grep -vE "^${name}=" "$ENV_FILE" || true
        printf '%s=%s\n' "$name" "$value"
    } > "$ENV_FILE.new"
    chmod --reference="$ENV_FILE" "$ENV_FILE.new" 2>/dev/null || chmod 600 "$ENV_FILE.new"
    mv "$ENV_FILE.new" "$ENV_FILE"
}

# Shell code for `docker exec bcm-mysql sh -c '...'`: the root password,
# read inside the container from its Docker secret (from the variable on a
# laptop), so it never crosses this host's command line.
# Usage: docker exec -i bcm-mysql sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot ..."
# shellcheck disable=SC2016
ROOT_PWD_IN_MYSQL='"$(cat /run/secrets/DB_ROOT_PASSWORD 2>/dev/null || printf %s "$MYSQL_ROOT_PASSWORD")"'
