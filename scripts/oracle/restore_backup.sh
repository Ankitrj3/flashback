#!/usr/bin/env sh
# Restore application filesystems from tar backups.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FLASHBACK_LOG_FILE="${FLASHBACK_LOG_FILE:-$SCRIPT_DIR/../../logs/flashback_execution.log}"

log() {
    echo "$*"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[%s] [restore_backup] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-/db800/app/oracle/r122${INSTANCE_ID}}"
BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/iriscommon/backup/tar}"
FS_LIST="${FLASHBACK_FS_LIST:-fs_ne fs1 fs2}"
APP_NODES="${FLASHBACK_APP_NODES:-${FLASHBACK_APP_HOST:-}}"
SSH_USER="${FLASHBACK_SSH_USER:-$(whoami)}"
SSH_KEY="${FLASHBACK_SSH_KEY:-}"
FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"
MIN_FREE_GB="${FLASHBACK_MIN_RESTORE_FREE_GB:-250}"
RESTORE_DATE_TAG="${1:-}"

log "Instance     : $INSTANCE_ID"
log "Base dir     : $APP_BASE_DIR"
log "Backup dir   : $BACKUP_DIR"
log "Filesystems  : $FS_LIST"
log "Min free GB  : $MIN_FREE_GB"
log "Mode         : $FLASHBACK_MODE"

fs_label() {
    case "$1" in
        fs_ne) echo "fs_ne" ;;
        fs1)
            case "${FLASHBACK_RUN_FS:-}" in
                */fs1/*) echo "fs1_Run" ;;
                *) echo "fs1_Patch" ;;
            esac
            ;;
        fs2)
            case "${FLASHBACK_RUN_FS:-}" in
                */fs1/*) echo "fs2_Patch" ;;
                *) echo "fs2_Run" ;;
            esac
            ;;
        *) echo "$1" ;;
    esac
}

fs_archive() {
    fs="$1"
    date_tag="$2"
    label=$(fs_label "$fs")
    echo "${BACKUP_DIR}/${INSTANCE_ID}_${label}_backup_${date_tag}.tar"
}

fs_move_name() {
    fs="$1"
    ts="$2"
    case "$(fs_label "$fs")" in
        fs1_Run) echo "fs1_run_${ts}" ;;
        fs1_Patch) echo "fs1_patch_${ts}" ;;
        fs2_Run) echo "fs2_run_${ts}" ;;
        fs2_Patch) echo "fs2_patch_${ts}" ;;
        fs_ne) echo "fs_ne_${ts}" ;;
        *) echo "${fs}_${ts}" ;;
    esac
}

ssh_options() {
    opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"
    [ -n "$SSH_KEY" ] && opts="$opts -i $SSH_KEY"
    echo "$opts"
}

list_available_backups() {
    target="$1"
    if [ -n "$target" ]; then
        ssh_opts=$(ssh_options)
        # shellcheck disable=SC2086
        ssh $ssh_opts "$SSH_USER@$target" \
            "ls -1t '${BACKUP_DIR}/${INSTANCE_ID}'_*_backup_*.tar 2>/dev/null" || true
    else
        ls -1t "${BACKUP_DIR}/${INSTANCE_ID}"_*_backup_*.tar 2>/dev/null || true
    fi
}

detect_latest_date_tag() {
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

check_free_space() {
    node="$1"

    if [ "$FLASHBACK_MODE" != "real" ]; then
        log "DRY-RUN: Would verify at least ${MIN_FREE_GB}GB free under $APP_BASE_DIR."
        return 0
    fi

    if [ -n "$node" ]; then
        ssh_opts=$(ssh_options)
        # shellcheck disable=SC2086
        available_gb=$(ssh $ssh_opts "$SSH_USER@$node" "df -Pk '$APP_BASE_DIR' | awk 'NR==2 { printf \"%d\", \$4 / 1048576 }'" 2>/dev/null || echo 0)
    else
        available_gb=$(df -Pk "$APP_BASE_DIR" | awk 'NR==2 { printf "%d", $4 / 1048576 }')
    fi

    case "$available_gb" in
        ''|*[!0-9]*) available_gb=0 ;;
    esac

    log "Available space under $APP_BASE_DIR: ${available_gb}GB"
    if [ "$available_gb" -lt "$MIN_FREE_GB" ]; then
        log "ERROR: At least ${MIN_FREE_GB}GB free space is required before restore."
        return 1
    fi
}

move_existing_filesystems() {
    node="$1"
    ts=$(date '+%Y%m%d_%H%M%S')

    if [ "$FLASHBACK_MODE" != "real" ]; then
        for fs in $FS_LIST; do
            log "DRY-RUN: Would rename $APP_BASE_DIR/$fs to $APP_BASE_DIR/$(fs_move_name "$fs" "$ts")"
        done
        return 0
    fi

    if [ -n "$node" ]; then
        ssh_opts=$(ssh_options)
        remote_cmd=""
        for fs in $FS_LIST; do
            dest=$(fs_move_name "$fs" "$ts")
            remote_cmd="${remote_cmd} if [ -d '$APP_BASE_DIR/$fs' ]; then mv '$APP_BASE_DIR/$fs' '$APP_BASE_DIR/$dest'; fi;"
        done
        # shellcheck disable=SC2086
        ssh $ssh_opts "$SSH_USER@$node" "$remote_cmd"
    else
        for fs in $FS_LIST; do
            src="$APP_BASE_DIR/$fs"
            dest="$APP_BASE_DIR/$(fs_move_name "$fs" "$ts")"
            if [ -d "$src" ]; then
                mv "$src" "$dest"
                log "Renamed $src to $dest"
            fi
        done
    fi
}

restore_on_node() {
    node="$1"
    date_tag="$2"
    pids=""
    failed=0

    check_free_space "$node" || return 1
    move_existing_filesystems "$node" || return 1

    for fs in $FS_LIST; do
        archive=$(fs_archive "$fs" "$date_tag")

        if [ "$FLASHBACK_MODE" != "real" ]; then
            if [ -z "$node" ]; then
                log "DRY-RUN: Would run locally: cd '$APP_BASE_DIR' && nohup tar -xvf '$archive' > '${archive}.restore.log' 2>&1 &"
            else
                log "DRY-RUN: Would run on $node: cd '$APP_BASE_DIR' && nohup tar -xvf '$archive' > '${archive}.restore.log' 2>&1 &"
            fi
            continue
        fi

        if [ -z "$node" ]; then
            log "Restoring locally: $archive"
            (
                cd "$APP_BASE_DIR" || exit 1
                nohup tar -xvf "$archive" > "${archive}.restore.log" 2>&1
            ) &
            pids="$pids $!"
        else
            log "Restoring on $node: $archive"
            ssh_opts=$(ssh_options)
            # shellcheck disable=SC2086
            ssh $ssh_opts "$SSH_USER@$node" \
                "cd '$APP_BASE_DIR' && nohup tar -xvf '$archive' > '${archive}.restore.log' 2>&1" &
            pids="$pids $!"
        fi
    done

    if [ "$FLASHBACK_MODE" != "real" ]; then
        return 0
    fi

    log "Waiting for application filesystem restore tar jobs to complete..."
    for pid in $pids; do
        if ! wait "$pid"; then
            failed=$((failed + 1))
        fi
    done

    if [ "$failed" -gt 0 ]; then
        log "ERROR: $failed restore tar job(s) failed on node '${node:-local}'."
        return 1
    fi
}

if [ -z "$RESTORE_DATE_TAG" ]; then
    log "No date tag specified, detecting latest backup..."
    RESTORE_DATE_TAG=$(detect_latest_date_tag || true)
    if [ -z "$RESTORE_DATE_TAG" ]; then
        if [ "$FLASHBACK_MODE" != "real" ]; then
            RESTORE_DATE_TAG=$(date '+%d%b%y')
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

echo ""
log "Tar files to restore:"
for fs in $FS_LIST; do
    archive=$(fs_archive "$fs" "$RESTORE_DATE_TAG")
    log "  $archive -> $APP_BASE_DIR/$fs"
done
echo ""

overall_failed=0

if [ -n "$APP_NODES" ]; then
    for node in $APP_NODES; do
        log "--- Restoring on node: $node ---"
        restore_on_node "$node" "$RESTORE_DATE_TAG" || overall_failed=$((overall_failed + 1))
    done
else
    if [ "$FLASHBACK_MODE" = "real" ] && [ ! -d "$APP_BASE_DIR" ]; then
        log "ERROR: Application base directory does not exist: $APP_BASE_DIR"
        exit 3
    fi
    if [ "$FLASHBACK_MODE" != "real" ]; then
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
