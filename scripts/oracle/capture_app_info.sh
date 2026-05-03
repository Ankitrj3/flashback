#!/usr/bin/env sh
# =============================================================================
# capture_app_info.sh — Detect file systems, check services, stop if needed
#
# USAGE   : sh capture_app_info.sh [--export]
#
# EXIT    : 0 = app info captured successfully
#           1 = check/stop failed
#           3 = operator cancelled
#
# HOW IT WORKS:
#   1. SSH into the application server.
#   2. Source EBSapps.env with 'run'   → captures $FILE_EDITION (=RUN base dir)
#   3. Source EBSapps.env with 'patch' → captures $FILE_EDITION (=PATCH base dir)
#   4. Derives NE dir from APP_BASE_DIR/fs_ne
#   5. Greps live EBS processes on the remote server and shows them.
#   6. Asks yes/no before stopping services via adstpall.sh.
#
# EXPORTS (when --export is used):
#   APP_RUN_FS, APP_PATCH_FS, APP_NE_FS,
#   APP_SERVICES_STOPPED, APP_PROCESS_COUNT
# =============================================================================

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [capture_app_info] $*" >&2
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-}"
APPS_USER="${FLASHBACK_APPS_USER:-apps}"
WLS_PASS="${FLASHBACK_WLS_PASS:-}"
OS_USER="${FLASHBACK_OS_USER:-$(whoami)}"
APP_HOST="${FLASHBACK_APP_HOST:-}"
APP_SSH_USER="${FLASHBACK_APP_USER:-}"
ENV_FILE="${FLASHBACK_APP_ENV_FILE:-}"
BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/tmp}"

EXPORT_MODE="false"
if [ "${1:-}" = "--export" ]; then
    EXPORT_MODE="true"
fi

DATE_TAG=$(date '+%d%b%y' | tr '[:upper:]' '[:lower:]')   # e.g. 09dec25

# =============================================================================
# STEP 1: Source EBSapps.env run → get RUN_FS
#         Source EBSapps.env patch → get PATCH_FS
# =============================================================================

RUN_FS=""
PATCH_FS=""
NE_FS=""

if [ -z "$APP_HOST" ] || [ -z "$APP_SSH_USER" ] || [ -z "$ENV_FILE" ]; then
    log "ERROR: FLASHBACK_APP_HOST, FLASHBACK_APP_USER, and FLASHBACK_APP_ENV_FILE must be set."
    exit 1
fi

log "Detecting File Systems on $APP_HOST..."
log ""

# Source with 'run' argument to get the RUN file system base directory
run_base=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$APP_SSH_USER@$APP_HOST" \
    "source ~/$ENV_FILE run >/dev/null 2>&1 && echo \"\$FILE_EDITION\"" 2>/dev/null || echo "")

# Source with 'patch' argument to get the PATCH file system base directory
patch_base=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$APP_SSH_USER@$APP_HOST" \
    "source ~/$ENV_FILE patch >/dev/null 2>&1 && echo \"\$FILE_EDITION\"" 2>/dev/null || echo "")

if [ -n "$run_base" ] && [ "$run_base" != "null" ]; then
    RUN_FS="${run_base}/EBSapps/appl"
fi

if [ -n "$patch_base" ] && [ "$patch_base" != "null" ]; then
    PATCH_FS="${patch_base}/EBSapps/appl"
fi

# Fallback: detect via FNDLIBR process if env sourcing failed
if [ -z "$RUN_FS" ] && [ -n "$APP_BASE_DIR" ]; then
    log "WARNING: Could not source env file. Detecting RUN fs via live FNDLIBR process..."
    run_proc=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$APP_SSH_USER@$APP_HOST" \
        "ps -ef | grep '[F]NDLIBR' | awk '{print \$8}' | head -1" 2>/dev/null || echo "")
    if echo "$run_proc" | grep -q "fs1"; then
        RUN_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
        PATCH_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
    else
        RUN_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
        PATCH_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
    fi
fi

# Derive NE filesystem from base dir
if [ -n "$APP_BASE_DIR" ]; then
    NE_FS="$APP_BASE_DIR/fs_ne"
fi

log "Application File Systems Detected:"
log "  RUN File System           : $RUN_FS"
log "  PATCH File System         : $PATCH_FS"
log "  Non-Editioned File System : $NE_FS"
log ""

# =============================================================================
# STEP 2: Grep live EBS processes on the application server
# =============================================================================

log "Checking active EBS processes on $APP_HOST for user '$APP_SSH_USER'..."
log ""

# Get list of meaningful EBS processes running on the remote server
PROC_LIST=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$APP_SSH_USER@$APP_HOST" \
    "ps -ef | grep -E '(FNDLIBR|FNDSM|apache|opmn|oacore|forms|WebLogic|WLS|java)' | grep -v grep | grep -v sshd" \
    2>/dev/null || echo "")

CONN_COUNT=0
if [ -n "$PROC_LIST" ]; then
    CONN_COUNT=$(echo "$PROC_LIST" | wc -l | tr -d ' ')
fi

if [ "$CONN_COUNT" -gt 0 ]; then
    log "Found $CONN_COUNT active EBS process(es):"
    log "-----------------------------------------------------------"
    echo "$PROC_LIST" | while IFS= read -r proc_line; do
        log "  $proc_line"
    done >&2
    log "-----------------------------------------------------------"
    log ""
else
    log "No active EBS processes found on $APP_HOST."
    log ""
fi

# =============================================================================
# STEP 3: Ask before stopping
# =============================================================================

APP_SERVICES_STOPPED="false"

if [ "$CONN_COUNT" -gt 0 ]; then
    printf "  Do you want to stop the application services? (yes/no): " >&2
    read -r stop_app

    if [ "$stop_app" = "yes" ]; then
        log "Stopping application via adstpall.sh on $APP_HOST..."

        # Find adstpall.sh on remote server
        ADSTPALL_PATH=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$APP_SSH_USER@$APP_HOST" \
            "find $APP_BASE_DIR -name adstpall.sh 2>/dev/null | head -1" 2>/dev/null || echo "")

        if [ -n "$ADSTPALL_PATH" ]; then
            log "Found adstpall.sh at $ADSTPALL_PATH"
            log "Running adstpall.sh interactively (enter APPS and WLS passwords when prompted)..."
            ssh -t "$APP_SSH_USER@$APP_HOST" "sh '$ADSTPALL_PATH'"
            if [ $? -eq 0 ]; then
                log "Application services stopped successfully."
                APP_SERVICES_STOPPED="true"
            else
                log "WARNING: adstpall.sh returned non-zero status. Please verify manually."
                APP_SERVICES_STOPPED="false"
            fi
        else
            log "ERROR: adstpall.sh not found under $APP_BASE_DIR on $APP_HOST."
            APP_SERVICES_STOPPED="false"
        fi
    else
        log "Skipping application shutdown."
        APP_SERVICES_STOPPED="false"
    fi
else
    # No processes running, consider it already stopped
    APP_SERVICES_STOPPED="true"
fi

# =============================================================================
# STEP 4: Export variables for the calling script
# =============================================================================

if [ "$EXPORT_MODE" = "true" ]; then
    echo "APP_RUN_FS=\"$RUN_FS\""
    echo "APP_PATCH_FS=\"$PATCH_FS\""
    echo "APP_NE_FS=\"$NE_FS\""
    echo "APP_PROCESS_COUNT=\"$CONN_COUNT\""
    echo "APP_SERVICES_STOPPED=\"$APP_SERVICES_STOPPED\""
else
    log "App info capture complete. Use: eval \$(sh capture_app_info.sh --export)"
fi

exit 0
