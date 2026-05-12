#!/usr/bin/env sh
# Restore application filesystems from tar backups.

set -eu

log() {
    if [ "${FLASHBACK_LOG_TIMESTAMPS:-true}" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [restore_backup] $*"
    else
        echo "[restore_backup] $*"
    fi
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-/db800/app/oracle/r122${INSTANCE_ID}}"
BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/iriscommon/backup/tar}"
FS_LIST="${FLASHBACK_FS_LIST:-fs_ne fs1 fs2}"
APP_NODES="${FLASHBACK_APP_NODES:-${FLASHBACK_APP_HOST:-}}"
SSH_USER="${FLASHBACK_SSH_USER:-$(whoami)}"
SSH_KEY="${FLASHBACK_SSH_KEY:-}"
FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"
# Optional: specific date tag to restore, otherwise auto-detect latest.
RESTORE_DATE_TAG="${1:-}"

log "Instance     : $INSTANCE_ID"
log "Base dir     : $APP_BASE_DIR"
log "Backup dir   : $BACKUP_DIR"
log "Filesystems  : $FS_LIST"
log "Mode         : $FLASHBACK_MODE"

fs_label() {
    case "$1" in
        fs_ne) echo "fs_ne" ;;
        fs1) echo "fs1_Patch" ;;
        fs2) echo "fs2_Run" ;;
        *) echo "$1" ;;
    esac
}

list_available_backups() {
    target="$1"
    if [ -n "$target" ]; then
        ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"
        [ -n "$SSH_KEY" ] && ssh_opts="$ssh_opts -i $SSH_KEY"
        # shellcheck disable=SC2086
        ssh $ssh_opts "$SSH_USER@$target" \
            "ls -1t '${BACKUP_DIR}/${INSTANCE_ID}'_*_backup_*.tar 2>/dev/null" || true
    else
        ls -1t "${BACKUP_DIR}/${INSTANCE_ID}"_*_backup_*.tar 2>/dev/null || true
    fi
}

detect_latest_date_tag() {
    # Extract the date tag from the most recent tar filename.
    # Filename format: ${INSTANCE_ID}_${label}_backup_${DATE_TAG}.tar
    first_node=""
    if [ -n "$APP_NODES" ]; then
        for n in $APP_NODES; do first_node="$n"; break; done
    fi
    latest_tar=$(list_available_backups "$first_node" | head -1)
    if [ -z "$latest_tar" ]; then
        return 1
    fi
    basename "$latest_tar" .tar | sed "s/.*_backup_//"
}

restore_on_node() {
    node="$1"
    date_tag="$2"

    ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"
    [ -n "$SSH_KEY" ] && ssh_opts="$ssh_opts -i $SSH_KEY"

    for fs in $FS_LIST; do
        label=$(fs_label "$fs")
        archive="${BACKUP_DIR}/${INSTANCE_ID}_${label}_backup_${date_tag}.tar"

        if [ "$FLASHBACK_MODE" != "real" ]; then
            if [ -z "$node" ]; then
                log "DRY-RUN: Would restore locally: cd '$APP_BASE_DIR' && tar -xvf '$archive'"
            else
                log "DRY-RUN: Would restore on $node: cd '$APP_BASE_DIR' && tar -xvf '$archive'"
            fi
            continue
        fi

        if [ -z "$node" ]; then
            log "Restoring locally: tar -xvf $archive"
            (cd "$APP_BASE_DIR" && tar -xf "$archive")
            log "Done: $archive"
        else
            log "Restoring on $node: tar -xvf $archive"
            # shellcheck disable=SC2086
            ssh $ssh_opts "$SSH_USER@$node" \
                "cd '$APP_BASE_DIR' && tar -xf '$archive'"
            log "Done: $SSH_USER@$node:$archive"
        fi
    done
}

# --- Resolve date tag ---
if [ -z "$RESTORE_DATE_TAG" ]; then
    log "No date tag specified, detecting latest backup..."
    RESTORE_DATE_TAG=$(detect_latest_date_tag || true)
    if [ -z "$RESTORE_DATE_TAG" ]; then
        if [ "$FLASHBACK_MODE" != "real" ]; then
            # In dry-run, SSH may be unreachable. Use the standard date tag
            # format so the dry-run output is still meaningful.
            RESTORE_DATE_TAG=$(date '+%d%b%y' | tr '[:upper:]' '[:lower:]')
            log "DRY-RUN: Could not list remote backups. Using date tag: $RESTORE_DATE_TAG"
        else
            log "ERROR: No backup tar files found in $BACKUP_DIR matching ${INSTANCE_ID}_*_backup_*.tar"
            exit 1
        fi
    else
        log "Auto-detected latest backup date tag: $RESTORE_DATE_TAG"
    fi
fi

log "Restoring backups with date tag: $RESTORE_DATE_TAG"

# --- List files that will be restored ---
echo ""
log "Tar files to restore:"
for fs in $FS_LIST; do
    label=$(fs_label "$fs")
    archive="${BACKUP_DIR}/${INSTANCE_ID}_${label}_backup_${RESTORE_DATE_TAG}.tar"
    log "  $archive -> $APP_BASE_DIR/$fs"
done
echo ""

# --- Execute restore ---
overall_failed=0

if [ -n "$APP_NODES" ]; then
    for node in $APP_NODES; do
        log "--- Restoring on node: $node ---"
        restore_on_node "$node" "$RESTORE_DATE_TAG" || overall_failed=$((overall_failed + 1))
    done
else
    if [ "$FLASHBACK_MODE" = "real" ]; then
        if [ ! -d "$APP_BASE_DIR" ]; then
            log "ERROR: Application base directory does not exist: $APP_BASE_DIR"
            exit 3
        fi
    else
        log "DRY-RUN: Would verify local directory: $APP_BASE_DIR"
    fi
    restore_on_node "" "$RESTORE_DATE_TAG" || overall_failed=$((overall_failed + 1))
fi

if [ "$overall_failed" -gt 0 ]; then
    log "ERROR: $overall_failed node restore(s) failed."
    exit 1
fi

log "All filesystem restores completed successfully."
exit 0
