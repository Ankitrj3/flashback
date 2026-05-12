#!/usr/bin/env sh
# Stop Oracle EBS application services and wait for process shutdown.
# Reusable across Make Flashback Request and Restore Flashback workflows.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FLASHBACK_LOG_FILE="${FLASHBACK_LOG_FILE:-$SCRIPT_DIR/../../logs/flashback_execution.log}"

log() {
    echo "$*"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[%s] [stop_app_services] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-/db800/app/oracle/r122${INSTANCE_ID}}"
APP_HOST="${FLASHBACK_APP_HOST:-}"
SSH_USER="${FLASHBACK_SSH_USER:-$(whoami)}"
APPS_USER="${FLASHBACK_APPS_USER:-apps}"
APPS_PASS="${FLASHBACK_APPS_PASS:-}"
WLS_PASS="${FLASHBACK_WLS_PASS:-}"
STOP_CMD="${FLASHBACK_STOP_CMD:-adstpall.sh}"
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
    run_app_cmd "ps -ef | egrep \"FND|INV|frm|java|http|aporx\" | egrep -v \"bash|ssh|ps|grep\" | wc -l" 2>/dev/null | tr -d ' '
}

normalize_count() {
    raw_count="${1:-}"
    case "$raw_count" in
        ''|*[!0-9]*) echo "999" ;;
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

run_shutdown() {
    log "Searching for $STOP_CMD under $APP_BASE_DIR ..."
    stop_path=$(run_app_cmd "command -v '$STOP_CMD' 2>/dev/null || find '$APP_BASE_DIR' -name '$STOP_CMD' 2>/dev/null | head -1" || true)
    if [ -z "$stop_path" ]; then
        log "ERROR: $STOP_CMD not found on application host."
        return 1
    fi

    log "Stopping application services using: $stop_path"
    if [ -n "$APP_HOST" ]; then
        printf "%s\n%s\n%s\n" "$APPS_USER" "$APPS_PASS" "$WLS_PASS" |
            ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$APP_HOST" "sh '$stop_path'"
    else
        printf "%s\n%s\n%s\n" "$APPS_USER" "$APPS_PASS" "$WLS_PASS" | sh "$stop_path"
    fi
}

wait_for_processes_down() {
    tries=10
    while [ "$tries" -gt 0 ]; do
        remaining=$(normalize_count "$(count_app_processes || echo "999")")
        log "Remaining application process count: $remaining"
        if [ "$remaining" -eq 0 ]; then
            return 0
        fi
        tries=$((tries - 1))
        sleep 15
    done
    return 1
}

# --- Main ---

proc_count=$(normalize_count "$(count_app_processes || echo "999")")
log "Application process count: $proc_count"

if [ "$proc_count" -eq 0 ]; then
    log "No application services running. Nothing to stop."
    exit 0
fi

log "Application services are running ($proc_count processes)."

if [ "$FLASHBACK_MODE" != "real" ]; then
    log "DRY-RUN: Would run application shutdown using $STOP_CMD."
    log "DRY-RUN: Would wait until application process count becomes zero."
    exit 0
fi

prompt_credentials
run_shutdown

if ! wait_for_processes_down; then
    log "ERROR: Application processes are still running after shutdown attempt."
    exit 1
fi

log "Application services stopped successfully."
exit 0
