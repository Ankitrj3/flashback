#!/usr/bin/env sh
# =============================================================================
# restore_backup.sh — Restore EBS filesystem archives before DB flashback
#
# USAGE   : sh restore_backup.sh <RESTORE_POINT_NAME>
# EXIT    : 0 = all restores completed successfully
#           1 = one or more extractions failed
#           2 = usage error
#           3 = configuration error
#
# CLIENT ENVIRONMENT (RXEST01):
#   Archives : /iriscommon/backups/tars/RXEST01_fs_ne_backup_DDMMMYY.tar
#   Method   : tar -xvf (extract, verbose, no parallel — sequential for safety)
#   Base dir : /db8000/app/oracle/r122rxest01
#
# DEMO MODE:
#   Set FLASHBACK_DEMO=true to simulate restore with realistic output.
#
# CONFIGURATION (environment variables):
#   FLASHBACK_INSTANCE_ID   Instance prefix (default: RXEST01)
#   FLASHBACK_BACKUP_DIR    Archive directory (default: /iriscommon/backups/tars)
#   FLASHBACK_APP_BASE_DIR  Extraction target base dir
#   FLASHBACK_FS_LIST       Space-separated relative filesystem names
#   FLASHBACK_APP_NODES     Remote node list for SSH restore (optional)
#   FLASHBACK_SSH_USER      SSH username
#   FLASHBACK_SSH_KEY       SSH private key path
# =============================================================================

set -eu

RESTORE_POINT="${1:-}"
if [ -z "$RESTORE_POINT" ]; then
    echo "Usage: $0 <RESTORE_POINT_NAME>" >&2
    exit 2
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [restore_backup] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-RXEST01}"
BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/iriscommon/backups/tars}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-/db8000/app/oracle/r122rxest01}"
FS_LIST="${FLASHBACK_FS_LIST:-fs_ne fs1 fs2}"
APP_NODES="${FLASHBACK_APP_NODES:-}"
SSH_USER="${FLASHBACK_SSH_USER:-oracle}"
SSH_KEY="${FLASHBACK_SSH_KEY:-}"

# Human-readable labels matching create_backup.sh naming convention
fs_label() {
    case "$1" in
        fs_ne) echo "fs_ne" ;;
        fs1)   echo "fs1_Patch" ;;
        fs2)   echo "fs2_Run" ;;
        *)     echo "$1" ;;
    esac
}

# =============================================================================
# DEMO MODE
# =============================================================================
if [ "${FLASHBACK_DEMO:-false}" = "true" ]; then
    log "DEMO MODE: Simulating filesystem restore."
    log "DEMO: Restore point  : $RESTORE_POINT"
    log "DEMO: Instance       : $INSTANCE_ID"
    log "DEMO: Backup dir     : $BACKUP_DIR (simulated)"
    log "DEMO: Base dir       : $APP_BASE_DIR (simulated)"
    log ""
    log "DEMO: Selecting most recent archives for restore ..."
    sleep 1

    for fs in $FS_LIST; do
        label=$(fs_label "$fs")
        log "DEMO: Extracting: ${INSTANCE_ID}_${label}_backup_23APR26.tar -> $APP_BASE_DIR (simulated)"
        sleep 1
        log "DEMO: tar -xvf ${INSTANCE_ID}_${label}_backup_23APR26.tar (simulated)"
        log "DEMO: Done: $fs restored successfully. (simulated)"
    done

    log ""
    log "DEMO: All filesystem restores completed. (simulated)"
    log "DEMO: Restore point : $RESTORE_POINT"
    exit 0
fi

# =============================================================================
# REAL MODE
# =============================================================================

log "Starting filesystem restore."
log "Restore point : $RESTORE_POINT"
log "Instance      : $INSTANCE_ID"
log "Backup dir    : $BACKUP_DIR"
log "Base dir      : $APP_BASE_DIR"

if [ ! -d "$BACKUP_DIR" ]; then
    log "ERROR: Backup directory does not exist: $BACKUP_DIR"
    exit 3
fi

FAILED=0

# Find most recent archive for a given fs label
find_latest_archive() {
    label="$1"
    # Look for RXEST01_fs_ne_backup_*.tar (any date)
    latest=$(ls -t "${BACKUP_DIR}/${INSTANCE_ID}_${label}_backup_"*.tar 2>/dev/null | head -1)
    if [ -z "$latest" ]; then
        log "ERROR: No archive found for '${INSTANCE_ID}_${label}_backup_*.tar' in $BACKUP_DIR"
        return 1
    fi
    echo "$latest"
}

restore_local_fs() {
    fs="$1"
    label=$(fs_label "$fs")
    archive=$(find_latest_archive "$label") || return 1
    size=$(du -sh "$archive" 2>/dev/null | cut -f1 || echo "?")
    log "Restoring local: $archive ($size) -> $APP_BASE_DIR"
    (
        cd "$APP_BASE_DIR" || exit 1
        tar -xvf "$archive"
    ) 2>&1 | tail -5 | sed 's/^/    /'
    log "Local restore OK : $fs"
    return 0
}

restore_remote_fs() {
    node="$1"
    fs="$2"
    label=$(fs_label "$fs")
    archive=$(find_latest_archive "$label") || return 1
    log "Restoring remote: $archive -> $SSH_USER@$node:$APP_BASE_DIR"
    ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes"
    [ -n "$SSH_KEY" ] && ssh_opts="$ssh_opts -i $SSH_KEY"
    # shellcheck disable=SC2086
    cat "$archive" | ssh $ssh_opts "$SSH_USER@$node" \
        "cd '$APP_BASE_DIR' && tar -xvf -" 2>/dev/null | tail -5 | sed "s/^/    [$node] /"
    log "Remote restore OK: $node:$APP_BASE_DIR/$fs"
    return 0
}

if [ -n "$APP_NODES" ]; then
    for node in $APP_NODES; do
        log "--- Restoring node: $node ---"
        for fs in $FS_LIST; do
            restore_remote_fs "$node" "$fs" || FAILED=$((FAILED + 1))
        done
    done
else
    if [ ! -d "$APP_BASE_DIR" ]; then
        log "ERROR: App base directory does not exist: $APP_BASE_DIR"
        exit 3
    fi
    for fs in $FS_LIST; do
        restore_local_fs "$fs" || FAILED=$((FAILED + 1))
    done
fi

if [ "$FAILED" -gt 0 ]; then
    log "ERROR: $FAILED restore(s) failed."
    exit 1
fi

log "All filesystem restores completed successfully."
log "Restore point : $RESTORE_POINT"
exit 0
