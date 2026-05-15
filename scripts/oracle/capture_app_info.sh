#!/usr/bin/env sh
# Detect EBS application file systems and ensure application services are down
# before taking application tar backups.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FLASHBACK_LOG_FILE="${FLASHBACK_LOG_FILE:-$SCRIPT_DIR/../../logs/flashback_execution.log}"

log() {
    echo "$*"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[capture_app_info] %s\n' "$*" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

marker() {
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$1] $2 : $ts"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[capture_app_info] [%s] %s : %s\n' "$1" "$2" "$ts" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
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
VERIFY_DB_SESSIONS="${FLASHBACK_VERIFY_DB_SESSIONS:-true}"
APP_STOPPED_BY_TOOL=false

run_app_cmd() {
    cmd="$1"
    if [ -n "$APP_HOST" ]; then
        ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$APP_HOST" "$cmd"
    else
        sh -c "$cmd"
    fi
}

count_app_processes() {
    run_app_cmd "ps -ef | egrep \"FND|INV|frm|java|http|aporx\" | egrep -v \"bash|ssh|ps|grep\" | wc -l" 2>/dev/null | tr -d ' '
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
    echo ""
    log "Application File Systems"
    log "  RUN File System           : $RUN_FS"
    log "  PATCH File System         : $PATCH_FS"
    log "  Non-Editioned File System : $NE_FS"
    echo ""
    log "Backup target directory     : $BACKUP_DIR"
}

detect_file_system_roles() {
    RUN_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
    PATCH_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
    NE_FS="$APP_BASE_DIR/fs_ne"

    # --- Method 1: XML s_file_edition_type parsing ---
    log "Detecting RUN/PATCH filesystem roles (Method 1: context XML)..."
    role_output=$(run_app_cmd "for fs in fs1 fs2; do xml=\$(ls -1 \'$APP_BASE_DIR\'/\$fs/inst/apps/*/appl/admin/*.xml 2>/dev/null | head -1); if [ -n \"\$xml\" ]; then edition=\$(sed -n \'s/.*<[^>]*s_file_edition_type[^>]*>\([^<]*\)<.*/\1/p\' \"\$xml\" | head -1 | tr \'[:upper:]\' \'[:lower:]\'); echo \"\$fs=\$edition\"; fi; done" 2>/dev/null || true)

    fs1_role=""
    fs2_role=""
    while IFS='=' read -r fs role; do
        case "$fs:$role" in
            fs1:run) fs1_role="run" ;;
            fs1:patch) fs1_role="patch" ;;
            fs2:run) fs2_role="run" ;;
            fs2:patch) fs2_role="patch" ;;
        esac
    done <<EOF
$role_output
EOF

    if [ -n "$fs1_role" ] || [ -n "$fs2_role" ]; then
        log "FS role detection method      : XML (s_file_edition_type)"
    else
        # --- Method 2: EBSapps.env symlink ---
        log "Method 1 (XML) could not detect FS roles. Trying Method 2 (EBSapps.env symlink)..."
        symlink_target=$(run_app_cmd "readlink '$APP_BASE_DIR/EBSapps.env' 2>/dev/null || true" 2>/dev/null || true)
        case "$symlink_target" in
            */fs1/*)
                fs1_role="run"
                fs2_role="patch"
                log "FS role detection method      : EBSapps.env symlink -> fs1"
                ;;
            */fs2/*)
                fs2_role="run"
                fs1_role="patch"
                log "FS role detection method      : EBSapps.env symlink -> fs2"
                ;;
        esac
    fi

    if [ -n "$fs1_role" ] || [ -n "$fs2_role" ]; then
        # Apply detected roles
        if [ "$fs1_role" = "run" ]; then
            RUN_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
            PATCH_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
        elif [ "$fs2_role" = "run" ]; then
            RUN_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
            PATCH_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
        elif [ "$fs1_role" = "patch" ]; then
            RUN_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
            PATCH_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
        elif [ "$fs2_role" = "patch" ]; then
            RUN_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
            PATCH_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
        fi
        log "  fs1 detected role          : ${fs1_role:-unknown}"
        log "  fs2 detected role          : ${fs2_role:-unknown}"
    else
        # --- Method 3: Interactive operator fallback ---
        echo ""
        echo "=========================================="
        echo "  WARNING: Could not automatically detect RUN/PATCH filesystem roles."
        echo "  Tried: XML (s_file_edition_type), EBSapps.env symlink"
        echo "  APP_BASE_DIR : $APP_BASE_DIR"
        echo ""
        echo "  Please confirm manually:"
        echo "    1. fs1 = RUN,  fs2 = PATCH  (enter: 1)"
        echo "    2. fs2 = RUN,  fs1 = PATCH  (enter: 2)  <-- default"
        echo "=========================================="
        printf "  Your choice [1/2, default 2]: "
        read -r fs_choice
        case "$fs_choice" in
            1)
                RUN_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
                PATCH_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
                fs1_role="run"; fs2_role="patch"
                log "FS role detection method      : Operator confirmed (fs1=RUN, fs2=PATCH)"
                ;;
            *)
                RUN_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
                PATCH_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
                fs1_role="patch"; fs2_role="run"
                log "FS role detection method      : Operator confirmed / default (fs2=RUN, fs1=PATCH)"
                ;;
        esac
    fi

    echo ""
    echo "  FS Role Detection Result:"
    printf "    fs1 = %-7s --> %s/fs1\n" "${fs1_role:-unknown}" "$APP_BASE_DIR"
    printf "    fs2 = %-7s --> %s/fs2\n" "${fs2_role:-unknown}" "$APP_BASE_DIR"
    echo "    RUN   FS : $RUN_FS"
    echo "    PATCH FS : $PATCH_FS"
    echo "    NE    FS : $NE_FS"
    echo ""
}

write_app_info_file() {
    # Persist captured app-node paths for later workflow steps. A child shell
    # cannot export variables back to the menu, so the menu sources this file.
    {
        printf 'export FLASHBACK_RUN_FS=%s\n' "'$RUN_FS'"
        printf 'export FLASHBACK_PATCH_FS=%s\n' "'$PATCH_FS'"
        printf 'export FLASHBACK_NE_FS=%s\n' "'$NE_FS'"
        printf 'export FLASHBACK_APP_STOPPED_BY_TOOL=%s\n' "'$APP_STOPPED_BY_TOOL'"
    } > "$APP_INFO_FILE"
    chmod 600 "$APP_INFO_FILE"
}

verify_file_systems() {
    # The flashback request must be anchored to the actual app node paths.
    # Fail early if any expected EBS filesystem cannot be reached.
    if ! run_app_cmd "test -d '$RUN_FS' && test -d '$PATCH_FS' && test -d '$NE_FS'"; then
        log "ERROR: One or more application filesystem paths are missing on the app server."
        return 1
    fi
    log "Verified application filesystem paths on app server."
}

run_stop_app_services() {
    sh "$SCRIPT_DIR/stop_app_services.sh"
}

check_db_app_sessions() {
    if [ "$VERIFY_DB_SESSIONS" != "true" ]; then
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

if [ -n "$APP_HOST" ]; then
    log "Application host             : $SSH_USER@$APP_HOST"
else
    log "Application host             : local"
fi

marker "START" "Application process count check"
proc_count=$(normalize_count "$(count_app_processes || echo "999")")
log "Application process count    : $proc_count"
marker "END" "Application process count check"

# When the menu has already handled the service-state decision and optionally
# already stopped services, skip the interactive prompt entirely.
SKIP_SERVICE_PROMPT="${FLASHBACK_SKIP_SERVICE_PROMPT:-false}"

if [ "$SKIP_SERVICE_PROMPT" = "true" ]; then
    log "Service prompt skipped (handled by calling workflow)."
elif [ "$proc_count" -gt 2 ]; then
    echo ""
    printf "%s application-related processes are still running. Do you want to continue backup while services are running? (yes/no): " "$proc_count"
    read -r continue_choice
    if [ "$continue_choice" = "yes" ]; then
        log "Operator approved backup while application services are running."
    else
        printf "Do you want to stop application services first? (yes/no): "
        read -r shutdown_choice
        if [ "$shutdown_choice" != "yes" ]; then
            log "Cancelled. Operator did not approve running backup or shutdown."
            exit 3
        fi

        if ! run_stop_app_services; then
            log "ERROR: Application processes are still running after shutdown attempt."
            exit 1
        else
            APP_STOPPED_BY_TOOL=true
            log "Application services are down. Backup can proceed."
        fi
    fi
else
    log "Application process count is within threshold. Backup can proceed."
fi

marker "START" "RUN/PATCH filesystem role detection"
detect_file_system_roles
marker "END" "RUN/PATCH filesystem role detection"
print_file_systems
marker "START" "Application filesystem path verification"
verify_file_systems
marker "END" "Application filesystem path verification"
write_app_info_file
marker "START" "DB application session check"
check_db_app_sessions
marker "END" "DB application session check"

exit 0
