#!/usr/bin/env sh
# Shows DB restore points, application tar files, and alert-log restore history.
# 1. When GRP was secured: DB restore points + application tar files.
# 2. When GRP was restored: parse alert log timings around "Flashback restore".

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [view_flashback] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/iriscommon/backup/tar}"
APP_HOST="${FLASHBACK_APP_HOST:-}"
SSH_USER="${FLASHBACK_SSH_USER:-$(whoami)}"
ORACLE_ENV="${FLASHBACK_ORACLE_ENV:-}"
ALERT_LOG="${FLASHBACK_ALERT_LOG:-}"

run_remote_or_local() {
    cmd="$1"
    if [ -n "$APP_HOST" ]; then
        ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$APP_HOST" "$cmd"
    else
        sh -c "$cmd"
    fi
}

source_oracle_env() {
    if [ -n "$ORACLE_ENV" ] && [ -f "$ORACLE_ENV" ]; then
        # shellcheck disable=SC1090
        . "$ORACLE_ENV"
    elif [ -n "$ORACLE_ENV" ]; then
        log "WARNING: Oracle env file not found: $ORACLE_ENV"
    fi
}

show_restore_points() {
    echo ""
    echo "=========================================="
    echo "1.1 DB Guaranteed Restore Points"
    echo "=========================================="
    sh "$(dirname "$0")/list_restore_points.sh"
}

show_app_tars() {
    echo ""
    echo "=========================================="
    echo "1.1 Application Tar Files"
    echo "=========================================="
    log "Listing: ${BACKUP_DIR}/${INSTANCE_ID}*.tar"
    if ! run_remote_or_local "ls -lrt '${BACKUP_DIR}/${INSTANCE_ID}'*.tar 2>/dev/null"; then
        log "No matching tar files found or app host is not reachable."
    fi
}

detect_alert_log() {
    if [ -n "$ALERT_LOG" ]; then
        echo "$ALERT_LOG"
        return
    fi

    if ! command -v sqlplus >/dev/null 2>&1; then
        return
    fi

    sqlplus -S "/ as sysdba" <<EOF 2>/dev/null | awk -F= '/^ALERT_LOG=/{print $2; exit}'
SET HEAD OFF FEED OFF PAGES 0 LINES 300 TRIMSPOOL ON
SELECT 'ALERT_LOG=' || value || '/alert_' || instance_name || '.log'
FROM v\$diag_info, v\$instance
WHERE name = 'Diag Trace';
EXIT;
EOF
}

show_restore_history() {
    echo ""
    echo "=========================================="
    echo "1.2 Flashback Restore History"
    echo "=========================================="

    source_oracle_env
    alert_file="$(detect_alert_log || true)"
    if [ -z "$alert_file" ]; then
        log "Alert log path not configured and could not be auto-detected."
        log "Set FLASHBACK_ALERT_LOG=/path/to/alert_DBNAME1.log"
        return
    fi

    log "Searching alert log: $alert_file"
    if [ ! -f "$alert_file" ]; then
        log "Alert log file not found: $alert_file"
        return
    fi

    matches=$(grep -iin -B1 "Flashback restore" "$alert_file" || true)
    if [ -z "$matches" ]; then
        log "No 'Flashback restore' entries found."
        return
    fi

    echo "Event                         Timing"
    echo "----------------------------  ----------------------------------------"
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        {
            line = trim($0)
            lower = tolower(line)
            if (line ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ ||
                line ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[[:space:]]+[A-Z][a-z][a-z][[:space:]]+/ ||
                line ~ /^[A-Z][a-z][a-z][[:space:]]+[A-Z][a-z][a-z][[:space:]]+[0-9][0-9]?[[:space:]]+/) {
                last_time = line
            }
            if (lower ~ /flashback restore start/) {
                printf "%-28s  %s\n", "Flashback Restore Start", (last_time ? last_time : "timestamp not found")
            }
            if (lower ~ /flashback restore complete/) {
                printf "%-28s  %s\n", "Flashback Restore Complete", (last_time ? last_time : "timestamp not found")
            }
        }
    ' "$alert_file"

    echo ""
    log "Raw matching alert log context:"
    echo "$matches"
}

show_restore_points
show_app_tars
show_restore_history
