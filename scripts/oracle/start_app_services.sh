#!/usr/bin/env sh
# Start Oracle EBS application services after flashback restore.

set -eu

log() {
    if [ "${FLASHBACK_LOG_TIMESTAMPS:-true}" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [start_app_services] $*"
    else
        echo "[start_app_services] $*"
    fi
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-/db800/app/oracle/r122${INSTANCE_ID}}"
APP_HOST="${FLASHBACK_APP_HOST:-}"
SSH_USER="${FLASHBACK_SSH_USER:-$(whoami)}"
APPS_USER="${FLASHBACK_APPS_USER:-apps}"
APPS_PASS="${FLASHBACK_APPS_PASS:-}"
WLS_PASS="${FLASHBACK_WLS_PASS:-}"
START_CMD="${FLASHBACK_START_CMD:-adstrtal.sh}"
FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"

run_app_cmd() {
    cmd="$1"
    if [ -n "$APP_HOST" ]; then
        ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$APP_HOST" "$cmd"
    else
        sh -c "$cmd"
    fi
}

count_app_processes() {
    if [ "$FLASHBACK_MODE" != "real" ]; then
        echo "${FLASHBACK_DRY_RUN_PROCESS_COUNT:-0}"
        return 0
    fi
    run_app_cmd "ps -ef | grep -E '(FNDLIBR|opmn|httpd|java.*oacore|java.*forms|adcmctl)' | grep -v grep | wc -l" 2>/dev/null | tr -d ' '
}

normalize_count() {
    raw_count="${1:-}"
    case "$raw_count" in
        ''|*[!0-9]*) echo "0" ;;
        *) echo "$raw_count" ;;
    esac
}

prompt_credentials() {
    if [ -z "$APPS_PASS" ]; then
        printf "Enter APPS username (default: %s): " "$APPS_USER"
        read -r entered_apps_user
        APPS_USER="${entered_apps_user:-$APPS_USER}"
        printf "Enter APPS password: "
        stty -echo 2>/dev/null || true
        read -r APPS_PASS
        stty echo 2>/dev/null || true
        echo ""
    fi

    if [ -z "$WLS_PASS" ]; then
        printf "Enter WebLogic password: "
        stty -echo 2>/dev/null || true
        read -r WLS_PASS
        stty echo 2>/dev/null || true
        echo ""
    fi
}

run_startup() {
    log "Searching for $START_CMD under $APP_BASE_DIR ..."
    start_path=$(run_app_cmd "command -v '$START_CMD' 2>/dev/null || find '$APP_BASE_DIR' -name '$START_CMD' 2>/dev/null | head -1" || true)
    if [ -z "$start_path" ]; then
        log "ERROR: $START_CMD not found on application host."
        return 1
    fi

    log "Starting application services using: $start_path"
    if [ -n "$APP_HOST" ]; then
        printf "%s\n%s\n%s\n" "$APPS_USER" "$APPS_PASS" "$WLS_PASS" |
            ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$APP_HOST" "sh '$start_path'"
    else
        printf "%s\n%s\n%s\n" "$APPS_USER" "$APPS_PASS" "$WLS_PASS" | sh "$start_path"
    fi
}

wait_for_processes_up() {
    tries=20
    while [ "$tries" -gt 0 ]; do
        running=$(normalize_count "$(count_app_processes || echo "0")")
        log "Application process count: $running"
        if [ "$running" -gt 0 ]; then
            log "Application services detected ($running processes)."
            return 0
        fi
        tries=$((tries - 1))
        sleep 15
    done
    log "WARNING: No application processes detected after startup. Verify manually."
    return 1
}

# --- Main ---

log "Instance: $INSTANCE_ID"

if [ "$FLASHBACK_MODE" != "real" ]; then
    log "DRY-RUN: Would run application startup using $START_CMD."
    log "DRY-RUN: Would wait for application processes to appear."
    exit 0
fi

prompt_credentials
run_startup

log "Waiting for application services to start..."
if ! wait_for_processes_up; then
    log "WARNING: Application startup may not have completed. Check manually."
    exit 1
fi

log "Application services started successfully."
exit 0
