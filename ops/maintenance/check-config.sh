#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Checks that the hardening done once is still in place, and watches the
# connections (OWASP Database Security: review configuration, monitor
# connections and errors). Prints settings and counts only, never a value
# of the data, so its output is safe to paste:
#   - MySQL as started (docker-compose.yml): TLS 1.3 required, no binary log,
#     no file read or written by SQL, no X Protocol, no scheduled events,
#     refused sign-ins logged (log_error_verbosity 3), the healthcheck's
#     account plugin loaded, the audit log's append-only trigger (V60);
#   - the connections since MySQL started: failed ones per day (the healthcheck
#     signs in, so they should be next to none), refusals for lack of
#     connections, the peak against the maximum;
#   - the logs: every container's to the journal, the journal's limits installed;
#   - the host: security updates applied in the last two days, no reboot
#     pending for more than three, the metadata service still blocked;
#   - the backups: the last offsite copy less than 26 hours old.
# Any failure exits 1. Run weekly from ops/maintenance/weekly-checks.sh, and by hand.
#
# Environment overrides (optional): MYSQL_CONTAINER, BACKUP_LOG.

set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
# shellcheck source=../secrets/lib.sh
source "ops/secrets/lib.sh"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-bcm-mysql}"
BACKUP_LOG="${BACKUP_LOG:-$HOME/backups/bcm/backup.log}"
# Failed connections per day above which something is knocking.
MAX_ABORTED_PER_DAY=50

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
failures=0
fail() { log "ERROR: $*"; failures=$((failures + 1)); }

mysql_root() {
    docker exec -i "$MYSQL_CONTAINER" sh -c "MYSQL_PWD=$ROOT_PWD_IN_MYSQL exec mysql -uroot --batch --skip-column-names 2>/dev/null"
}

# --- MySQL settings: "name expected actual" per line --------------------------
settings="$(mysql_root <<'SQL'
SELECT 'require_secure_transport', '1', @@require_secure_transport;
SELECT 'tls_version', 'TLSv1.3', @@tls_version;
SELECT 'log_bin', '0', @@log_bin;
SELECT 'local_infile', '0', @@local_infile;
SELECT 'secure_file_priv', 'NULL', IFNULL(@@secure_file_priv, 'NULL');
SELECT 'event_scheduler', 'OFF', @@event_scheduler;
SELECT 'log_error_verbosity', '3', @@log_error_verbosity;
SELECT 'mysqlx', 'off', IF(COUNT(*) = 0, 'off', 'ACTIVE') FROM information_schema.PLUGINS
 WHERE PLUGIN_NAME = 'mysqlx' AND PLUGIN_STATUS = 'ACTIVE';
SELECT 'auth_socket', 'ACTIVE', IFNULL(MAX(PLUGIN_STATUS), 'missing') FROM information_schema.PLUGINS
 WHERE PLUGIN_NAME = 'auth_socket';
SELECT 'audit_logs_no_update', '1', COUNT(*) FROM information_schema.TRIGGERS
 WHERE TRIGGER_SCHEMA = 'bcm' AND TRIGGER_NAME = 'audit_logs_no_update';
SQL
)" || true
[ -n "$settings" ] || { fail "no setting read from $MYSQL_CONTAINER"; settings=""; }
while IFS=$'\t' read -r name expected actual; do
    [ -n "$name" ] || continue
    if [ "$actual" = "$expected" ]; then
        log "OK: mysql $name = $actual"
    else
        fail "mysql $name is '$actual', expected '$expected'"
    fi
done <<< "$settings"

# --- Connections since MySQL started -----------------------------------------
status="$(mysql_root <<'SQL'
SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime', 'Aborted_connects', 'Connection_errors_max_connections', 'Max_used_connections');
SELECT 'max_connections', @@max_connections;
SQL
)" || true
value() { printf '%s\n' "$status" | awk -v n="$1" '$1 == n {print $2}'; }
uptime="$(value Uptime)"; aborted="$(value Aborted_connects)"; refused="$(value Connection_errors_max_connections)"
peak="$(value Max_used_connections)"; max="$(value max_connections)"
if [ -z "$uptime" ] || [ -z "$aborted" ] || [ -z "$peak" ] || [ -z "$max" ]; then
    fail "connection counters not read from $MYSQL_CONTAINER"
else
    # Over at least a day: a server just restarted does not turn three failures into a rate.
    span=$(( uptime > 86400 ? uptime : 86400 ))
    per_day=$(( aborted * 86400 / span ))
    if [ "$per_day" -gt "$MAX_ABORTED_PER_DAY" ]; then
        fail "$aborted failed connections in $(( uptime / 3600 )) hours ($per_day a day): see 'Access denied' in docker logs $MYSQL_CONTAINER"
    else
        log "OK: $aborted failed connections in $(( uptime / 3600 )) hours"
    fi
    [ "${refused:-0}" = 0 ] && log "OK: no connection refused for lack of slots" \
        || fail "$refused connections refused: max_connections ($max) reached"
    if [ $(( peak * 100 )) -ge $(( max * 80 )) ]; then
        fail "connections peaked at $peak of $max"
    else
        log "OK: connections peaked at $peak of $max"
    fi
fi

# --- Logs ----------------------------------------------------------------------
not_journal=0
for container in $(docker ps --format '{{.Names}}' | grep '^bcm-' | sort); do
    driver="$(docker inspect --format '{{.HostConfig.LogConfig.Type}}' "$container")"
    if [ "$driver" != journald ]; then
        fail "$container logs to $driver, not the journal (docker-compose.prod.yml)"
        not_journal=$((not_journal + 1))
    fi
done
[ "$not_journal" -gt 0 ] || log "OK: every container logs to the journal"
if cmp -s ops/host/journald-bcm.conf /etc/systemd/journald.conf.d/bcm.conf; then
    log "OK: journal limits installed ($(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1) used)"
else
    fail "journal limits not installed: run ops/host/apply-host-hardening.sh"
fi

# --- Host ----------------------------------------------------------------------
stamp=/var/lib/apt/periodic/unattended-upgrades-stamp
if systemctl is-active --quiet unattended-upgrades && [ -f "$stamp" ] \
        && [ $(( $(date +%s) - $(stat -c %Y "$stamp") )) -lt $(( 2 * 86400 )) ]; then
    log "OK: security updates applied automatically, last run $(date -u -r "$stamp" +%F)"
else
    fail "automatic security updates not running (unattended-upgrades)"
fi
if [ -f /var/run/reboot-required ] \
        && [ $(( $(date +%s) - $(stat -c %Y /var/run/reboot-required) )) -gt $(( 3 * 86400 )) ]; then
    fail "a reboot has been pending for more than three days (the 02:30 automatic one did not happen)"
else
    log "OK: no reboot overdue"
fi
systemctl is-active --quiet bcm-block-metadata.service && log "OK: metadata service blocked from containers" \
    || fail "bcm-block-metadata.service not active: run ops/host/apply-host-hardening.sh"

# --- Backups ---------------------------------------------------------------------
last_offsite="$(grep -h 'offsite copy OK' "$BACKUP_LOG" 2>/dev/null | tail -1 | cut -d' ' -f1 || true)"
if [ -n "$last_offsite" ] && [ $(( $(date +%s) - $(date -d "$last_offsite" +%s) )) -lt $(( 26 * 3600 )) ]; then
    log "OK: last offsite copy $last_offsite"
else
    fail "no offsite copy in the last 26 hours (last: ${last_offsite:-none}; $BACKUP_LOG)"
fi

if [ "$failures" -gt 0 ]; then
    log "configuration check FAILED: $failures problem(s)"
    exit 1
fi
log "configuration check OK"
