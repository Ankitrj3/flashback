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
APP_RUN_FS="${FLASHBACK_APP_RUN_FS:-}"
APP_PATCH_FS="${FLASHBACK_APP_PATCH_FS:-}"

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
# DYNAMICALLY DETERMINE FS DIRS FROM FULL PATHS
# =============================================================================

# Extract which is fs1 and which is fs2 dynamically from the full paths
if [ -n "$APP_RUN_FS" ]; then
    RUN_FS_DIR=$(echo "$APP_RUN_FS" | grep -oE 'fs[12]' | head -1)
else
    # Fallback: check FNDLIBR process on remote to determine which is RUN
    log "WARNING: FLASHBACK_APP_RUN_FS not set. Detecting via live process..."
    run_proc=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$APP_HOST" \
        "ps -ef | grep '[F]NDLIBR' | awk '{print \$8}' | head -1" 2>/dev/null || echo "")
    if echo "$run_proc" | grep -q "fs1"; then
        RUN_FS_DIR="fs1"
    else
        RUN_FS_DIR="fs2"
    fi
fi

if [ -n "$APP_PATCH_FS" ]; then
    PATCH_FS_DIR=$(echo "$APP_PATCH_FS" | grep -oE 'fs[12]' | head -1)
else
    # Patch is whichever fs is NOT the run dir
    if [ "$RUN_FS_DIR" = "fs1" ]; then
        PATCH_FS_DIR="fs2"
    else
        PATCH_FS_DIR="fs1"
    fi
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

# =============================================================================
# BUILD BACKUP COMMANDS
# =============================================================================

ARCHIVE_NE="${BACKUP_DIR}/${INSTANCE_ID}_fs_ne_backup_${DATE_TAG}.tar"
ARCHIVE_RUN="${BACKUP_DIR}/${INSTANCE_ID}_${RUN_FS_DIR}_Run_backup_${DATE_TAG}.tar"
ARCHIVE_PATCH="${BACKUP_DIR}/${INSTANCE_ID}_${PATCH_FS_DIR}_Patch_backup_${DATE_TAG}.tar"

LOG_NE="${BACKUP_DIR}/${INSTANCE_ID}_fs_ne_backup_${DATE_TAG}.log"
LOG_RUN="${BACKUP_DIR}/${INSTANCE_ID}_${RUN_FS_DIR}_Run_backup_${DATE_TAG}.log"
LOG_PATCH="${BACKUP_DIR}/${INSTANCE_ID}_${PATCH_FS_DIR}_Patch_backup_${DATE_TAG}.log"

SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"
[ -n "$SSH_KEY" ] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

# =============================================================================
# LAUNCH DETACHED BACKUPS — ALL 3 IN PARALLEL
# Each one is fully detached via nohup + & + disown inside SSH
# The SSH connection closes immediately after launching each job
# Backups continue running on the server independently
# =============================================================================

log "Launching detached backup: fs_ne"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$SSH_USER@$APP_HOST" \
    "nohup sh -c 'cd \"$APP_BASE_DIR\" && tar -cvf \"$ARCHIVE_NE\" fs_ne > \"$LOG_NE\" 2>&1' </dev/null >/dev/null 2>&1 &"
log "  → Launched. Log: $APP_HOST:$LOG_NE"

log "Launching detached backup: $RUN_FS_DIR (RUN)"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$SSH_USER@$APP_HOST" \
    "nohup sh -c 'cd \"$APP_BASE_DIR\" && tar -cvf \"$ARCHIVE_RUN\" $RUN_FS_DIR > \"$LOG_RUN\" 2>&1' </dev/null >/dev/null 2>&1 &"
log "  → Launched. Log: $APP_HOST:$LOG_RUN"

log "Launching detached backup: $PATCH_FS_DIR (PATCH)"
# shellcheck disable=SC2086
ssh $SSH_OPTS "$SSH_USER@$APP_HOST" \
    "nohup sh -c 'cd \"$APP_BASE_DIR\" && tar -cvf \"$ARCHIVE_PATCH\" $PATCH_FS_DIR > \"$LOG_PATCH\" 2>&1' </dev/null >/dev/null 2>&1 &"
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
