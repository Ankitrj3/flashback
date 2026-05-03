#!/usr/bin/env sh
# =============================================================================
# create_backup.sh — Detached parallel nohup tar backup of EBS filesystems
#
# USAGE   : sh create_backup.sh
# EXIT    : 0 = all nohup tar jobs launched successfully
#           1 = launch failed
#           3 = configuration error
#
# HOW IT WORKS:
#   Runs nohup tar FULLY DETACHED (background) on the application server via SSH.
#   Because EBS filesystems can be 100-400GB, backups take 4-5 hours.
#   The script launches all 3 backups in parallel and IMMEDIATELY returns.
#   Progress can be tracked via log files on the application server.
#
# REQUIRED ENVIRONMENT VARIABLES:
#   FLASHBACK_INSTANCE_ID     — e.g. RXEDV05
#   FLASHBACK_APP_BASE_DIR    — e.g. /db6000/app/oracle/r122rxedv05
#   FLASHBACK_APP_HOST        — Application server hostname
#   FLASHBACK_APP_USER        — SSH username for app server
#   FLASHBACK_BACKUP_DIR      — Destination for .tar files
#   FLASHBACK_APP_RUN_FS      — Full path to RUN appl dir (from capture_app_info)
#   FLASHBACK_APP_PATCH_FS    — Full path to PATCH appl dir (from capture_app_info)
# =============================================================================

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [create_backup] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-}"
APP_HOST="${FLASHBACK_APP_HOST:-}"
SSH_USER="${FLASHBACK_APP_USER:-}"
SSH_KEY="${FLASHBACK_SSH_KEY:-}"
BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/tmp}"

# Dynamically received from capture_app_info.sh export
# APP_RUN_BASE = raw $FILE_EDITION from 'source EBSapps.env run'   (e.g. /db6000/.../fs2)
# APP_PATCH_BASE = raw $FILE_EDITION from 'source EBSapps.env patch' (e.g. /db6000/.../fs1)
APP_RUN_BASE="${FLASHBACK_APP_RUN_BASE:-}"
APP_PATCH_BASE="${FLASHBACK_APP_PATCH_BASE:-}"

DATE_TAG=$(date '+%d%b%y' | tr '[:lower:]' '[:upper:]')   # e.g. 23APR26

# =============================================================================
# VALIDATION
# =============================================================================

if [ -z "$INSTANCE_ID" ]; then
    log "ERROR: FLASHBACK_INSTANCE_ID is not set."
    exit 3
fi
if [ -z "$APP_HOST" ] || [ -z "$SSH_USER" ]; then
    log "ERROR: FLASHBACK_APP_HOST and FLASHBACK_APP_USER must be set."
    exit 3
fi
if [ -z "$APP_BASE_DIR" ]; then
    log "ERROR: FLASHBACK_APP_BASE_DIR is not set."
    exit 3
fi

# =============================================================================
# DYNAMICALLY DETERMINE FS DIRS USING basename ON RAW FILE_EDITION PATHS
# Works for any folder name — fs1, fs2, EBS_RUN, appl_r1, etc.
# =============================================================================

RUN_FS_DIR=""
PATCH_FS_DIR=""

# SSH options must be defined before any SSH calls
SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"
[ -n "$SSH_KEY" ] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

if [ -n "$APP_RUN_BASE" ]; then
    # basename extracts just the folder name from the full path given by EBSapps.env
    RUN_FS_DIR=$(basename "$APP_RUN_BASE")
fi

if [ -n "$APP_PATCH_BASE" ]; then
    PATCH_FS_DIR=$(basename "$APP_PATCH_BASE")
fi

# Fallback if base paths were not passed: detect via FNDLIBR process on server
if [ -z "$RUN_FS_DIR" ] && [ -n "$APP_BASE_DIR" ]; then
    log "WARNING: APP_RUN_BASE not set. Detecting via live FNDLIBR process..."
    # shellcheck disable=SC2086
    run_proc=$(ssh $SSH_OPTS "$SSH_USER@$APP_HOST" \
        "ps -ef | grep '[F]NDLIBR' | awk '{print \$8}' | head -1" 2>/dev/null || echo "")
    # Extract the folder name right after APP_BASE_DIR in the process path
    RUN_FS_DIR=$(echo "$run_proc" | sed "s|^${APP_BASE_DIR}/||" | cut -d'/' -f1)
    if [ -z "$RUN_FS_DIR" ]; then
        log "ERROR: Could not determine RUN filesystem directory. Cannot proceed."
        exit 3
    fi
    # Determine PATCH by listing dirs under APP_BASE_DIR excluding RUN and fs_ne
    # shellcheck disable=SC2086
    PATCH_FS_DIR=$(ssh $SSH_OPTS "$SSH_USER@$APP_HOST" \
        "ls -d '$APP_BASE_DIR'/fs* 2>/dev/null | grep -v '/$RUN_FS_DIR$' | grep -v 'fs_ne' | head -1 | xargs basename" \
        2>/dev/null || echo "")
    # Build full paths from discovered dirs
    APP_RUN_BASE="$APP_BASE_DIR/$RUN_FS_DIR"
    APP_PATCH_BASE="$APP_BASE_DIR/$PATCH_FS_DIR"
fi

log "Starting detached parallel filesystem backups."
log "Instance      : $INSTANCE_ID"
log "App server    : $APP_HOST"
log "Base dir      : $APP_BASE_DIR"
log "Backup dir    : $BACKUP_DIR"
log "RUN fs        : $RUN_FS_DIR"
log "PATCH fs      : $PATCH_FS_DIR"
log "Date tag      : $DATE_TAG"
log ""

# Full absolute paths — no cd needed
NE_FULL_PATH="${APP_BASE_DIR}/fs_ne"
RUN_FULL_PATH="${APP_RUN_BASE}"
PATCH_FULL_PATH="${APP_PATCH_BASE}"

ARCHIVE_NE="${BACKUP_DIR}/${INSTANCE_ID}_fs_ne_backup_${DATE_TAG}.tar"
ARCHIVE_RUN="${BACKUP_DIR}/${INSTANCE_ID}_${RUN_FS_DIR}_Run_backup_${DATE_TAG}.tar"
ARCHIVE_PATCH="${BACKUP_DIR}/${INSTANCE_ID}_${PATCH_FS_DIR}_Patch_backup_${DATE_TAG}.tar"

LOG_NE="${BACKUP_DIR}/${INSTANCE_ID}_fs_ne_backup_${DATE_TAG}.log"
LOG_RUN="${BACKUP_DIR}/${INSTANCE_ID}_${RUN_FS_DIR}_Run_backup_${DATE_TAG}.log"
LOG_PATCH="${BACKUP_DIR}/${INSTANCE_ID}_${PATCH_FS_DIR}_Patch_backup_${DATE_TAG}.log"


# =============================================================================
# LAUNCH DETACHED BACKUPS — ALL 3 IN PARALLEL
# Each one is fully detached via nohup + & + disown inside SSH
# The SSH connection closes immediately after launching each job
# Backups continue running on the server independently
# =============================================================================

log "Launching detached backup: fs_ne"
log "  nohup tar -cvf $ARCHIVE_NE $NE_FULL_PATH"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$SSH_USER@$APP_HOST" \
    "nohup tar -cvf '$ARCHIVE_NE' '$NE_FULL_PATH' > '$LOG_NE' 2>&1 </dev/null &"
log "  → Launched. Log: $APP_HOST:$LOG_NE"

log "Launching detached backup: $RUN_FS_DIR (RUN)"
log "  nohup tar -cvf $ARCHIVE_RUN $RUN_FULL_PATH"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$SSH_USER@$APP_HOST" \
    "nohup tar -cvf '$ARCHIVE_RUN' '$RUN_FULL_PATH' > '$LOG_RUN' 2>&1 </dev/null &"
log "  → Launched. Log: $APP_HOST:$LOG_RUN"

log "Launching detached backup: $PATCH_FS_DIR (PATCH)"
log "  nohup tar -cvf $ARCHIVE_PATCH $PATCH_FULL_PATH"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$SSH_USER@$APP_HOST" \
    "nohup tar -cvf '$ARCHIVE_PATCH' '$PATCH_FULL_PATH' > '$LOG_PATCH' 2>&1 </dev/null &"
log "  → Launched. Log: $APP_HOST:$LOG_PATCH"

log ""
log "All 3 backup jobs launched in detached mode on $APP_HOST."
log "Backups are running independently in the background (4-5 hours expected)."
log ""
log "To monitor progress, SSH into $APP_HOST and run:"
log "  tail -f $LOG_NE"
log "  tail -f $LOG_RUN"
log "  tail -f $LOG_PATCH"
log ""

exit 0
