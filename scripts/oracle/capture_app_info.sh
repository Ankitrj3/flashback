#!/usr/bin/env sh
# Detect EBS application file systems and ensure application services are down
# before taking application tar backups.

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [capture_app_info] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-/db800/app/oracle/r122${INSTANCE_ID}}"
APP_HOST="${FLASHBACK_APP_HOST:-}"
SSH_USER="${FLASHBACK_SSH_USER:-$(whoami)}"
APPS_USER="${FLASHBACK_APPS_USER:-apps}"
APPS_PASS="${FLASHBACK_APPS_PASS:-}"
WLS_PASS="${FLASHBACK_WLS_PASS:-}"
BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/iriscommon/backup/tar}"
APP_INFO_FILE="${FLASHBACK_APP_INFO_FILE:-$HOME/.flashback_app_info}"
STOP_CMD="${FLASHBACK_STOP_CMD:-adstpall.sh}"
FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"
VERIFY_DB_SESSIONS="${FLASHBACK_VERIFY_DB_SESSIONS:-true}"

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
    # Process checks may include SSH banners or command warnings on hardened
    # hosts. Treat non-numeric output as a blocking unknown instead of letting
    # test(1) fail open or crash the workflow.
    raw_count="${1:-}"
    case "$raw_count" in
        ''|*[!0-9]*) echo "999" ;;
        *) echo "$raw_count" ;;
    esac
}

print_file_systems() {
    RUN_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
    PATCH_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
    NE_FS="$APP_BASE_DIR/fs_ne"

    echo ""
    log "Application File Systems"
    log "  RUN File System           : $RUN_FS"
    log "  PATCH File System         : $PATCH_FS"
    log "  Non-Editioned File System : $NE_FS"
    echo ""
    log "Backup target directory     : $BACKUP_DIR"
}

write_app_info_file() {
    # Persist captured app-node paths for later workflow steps. A child shell
    # cannot export variables back to the menu, so the menu sources this file.
    {
        printf 'export FLASHBACK_RUN_FS=%s\n' "'$RUN_FS'"
        printf 'export FLASHBACK_PATCH_FS=%s\n' "'$PATCH_FS'"
        printf 'export FLASHBACK_NE_FS=%s\n' "'$NE_FS'"
    } > "$APP_INFO_FILE"
    chmod 600 "$APP_INFO_FILE"
}

verify_file_systems() {
    RUN_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
    PATCH_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
    NE_FS="$APP_BASE_DIR/fs_ne"

    if [ "$FLASHBACK_MODE" != "real" ]; then
        log "DRY-RUN: Would verify application paths on app server:"
        log "DRY-RUN:   test -d '$RUN_FS'"
        log "DRY-RUN:   test -d '$PATCH_FS'"
        log "DRY-RUN:   test -d '$NE_FS'"
        return 0
    fi

    # The flashback request must be anchored to the actual app node paths.
    # Fail early if any expected EBS filesystem cannot be reached.
    if ! run_app_cmd "test -d '$RUN_FS' && test -d '$PATCH_FS' && test -d '$NE_FS'"; then
        log "ERROR: One or more application filesystem paths are missing on the app server."
        return 1
    fi
    log "Verified application filesystem paths on app server."
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

run_stop_app_services() {
    sh "$SCRIPT_DIR/stop_app_services.sh"
}

check_db_app_sessions() {
    if [ "$VERIFY_DB_SESSIONS" != "true" ]; then
        return 0
    fi

    if [ "$FLASHBACK_MODE" != "real" ]; then
        log "DRY-RUN: Would check DB active application sessions from v\$session."
        return 0
    fi

    if ! command -v sqlplus >/dev/null 2>&1; then
        log "WARNING: sqlplus not found; skipping DB-level session check."
        return 0
    fi

    db_sessions=$(sqlplus -S "/ as sysdba" <<'EOF' 2>/dev/null | awk -F= '/^APP_SESSION_COUNT=/{print $2; exit}'
SET HEAD OFF FEED OFF PAGES 0 LINES 200 TRIMSPOOL ON
SELECT 'APP_SESSION_COUNT=' || COUNT(*)
FROM v$session
WHERE username IS NOT NULL
  AND username NOT IN ('SYS','SYSTEM','DBSNMP','RMAN');
EXIT;
EOF
) || db_sessions=""
    db_sessions="${db_sessions:-0}"
    case "$db_sessions" in
        *[!0-9]*|"") db_sessions=0 ;;
    esac
    log "DB non-system session count : $db_sessions"
    if [ "$db_sessions" -gt 0 ]; then
        log "WARNING: DB still shows non-system sessions. Confirm this is expected before continuing."
    fi
}

print_file_systems
verify_file_systems
write_app_info_file

if [ -n "$APP_HOST" ]; then
    log "Application host             : $SSH_USER@$APP_HOST"
else
    log "Application host             : local"
fi

proc_count=$(normalize_count "$(count_app_processes || echo "999")")
log "Application process count    : $proc_count"

if [ "$proc_count" -gt 0 ]; then
    echo ""
    echo "Application services are running."
    printf "Continue and take application backup while services are running? (yes/no): "
    read -r continue_choice
    if [ "$continue_choice" = "yes" ]; then
        log "Operator approved backup while application services are running."
        check_db_app_sessions
        exit 0
    fi

    printf "Shutdown application services before backup? (yes/no): "
    read -r shutdown_choice
    if [ "$shutdown_choice" != "yes" ]; then
        log "Cancelled. Operator did not approve running backup or shutdown."
        exit 3
    fi

    if [ "$FLASHBACK_MODE" != "real" ]; then
        log "DRY-RUN: Would run application shutdown using $STOP_CMD."
        log "DRY-RUN: Would wait until application process count becomes zero."
        check_db_app_sessions
        exit 0
    fi

    if ! run_stop_app_services; then
        log "ERROR: Application processes are still running after shutdown attempt."
        exit 1
    fi
    check_db_app_sessions
    log "Application services are down. Backup can proceed."
else
    log "No application services detected. Backup can proceed."
    check_db_app_sessions
fi

exit 0
