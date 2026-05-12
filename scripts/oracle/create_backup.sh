#!/usr/bin/env sh
# Parallel tar backup of EBS application file systems.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FLASHBACK_LOG_FILE="${FLASHBACK_LOG_FILE:-$SCRIPT_DIR/../../logs/flashback_execution.log}"

log() {
    echo "$*"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[%s] [create_backup] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
# Client runbook format, preserving the date command's natural month case.
DATE_TAG=$(date '+%d%b%y')
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-/db800/app/oracle/r122${INSTANCE_ID}}"
BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/iriscommon/backup/tar}"
FS_LIST="${FLASHBACK_FS_LIST:-fs_ne fs1 fs2}"
APP_NODES="${FLASHBACK_APP_NODES:-${FLASHBACK_APP_HOST:-}}"
SSH_USER="${FLASHBACK_SSH_USER:-$(whoami)}"
SSH_KEY="${FLASHBACK_SSH_KEY:-}"
FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"

log "Starting parallel filesystem backup."
log "Instance     : $INSTANCE_ID"
log "Base dir     : $APP_BASE_DIR"
log "Backup dir   : $BACKUP_DIR"
log "Filesystems  : $FS_LIST"
log "RUN FS       : ${FLASHBACK_RUN_FS:-$APP_BASE_DIR/fs2/EBSapps/appl}"
log "PATCH FS     : ${FLASHBACK_PATCH_FS:-$APP_BASE_DIR/fs1/EBSapps/appl}"
log "NE FS        : ${FLASHBACK_NE_FS:-$APP_BASE_DIR/fs_ne}"
log "Date tag     : $DATE_TAG"
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

run_backup_on_node() {
    node="$1"

    # In real mode, fail before launching background tar jobs if the backup
    # target is missing or unwritable. This keeps partial backups obvious.
    if [ -n "$node" ]; then
        ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"
        [ -n "$SSH_KEY" ] && ssh_opts="$ssh_opts -i $SSH_KEY"
        if [ "$FLASHBACK_MODE" = "real" ]; then
            # shellcheck disable=SC2086
            if ! ssh $ssh_opts "$SSH_USER@$node" "mkdir -p '$BACKUP_DIR' && test -w '$BACKUP_DIR' && test -d '$APP_BASE_DIR'"; then
                log "ERROR: Remote app base or backup directory is not ready on $node."
                return 1
            fi
        else
            log "DRY-RUN: Would verify remote directories on $node: $APP_BASE_DIR and $BACKUP_DIR"
        fi
    fi

    for fs in $FS_LIST; do
        label=$(fs_label "$fs")
        archive="${BACKUP_DIR}/${INSTANCE_ID}_${label}_backup_${DATE_TAG}.tar"
        log_file="${BACKUP_DIR}/${INSTANCE_ID}_${label}_backup_${DATE_TAG}.log"

        if [ "$FLASHBACK_MODE" != "real" ]; then
            if [ -z "$node" ]; then
                log "DRY-RUN: Would run locally: cd '$APP_BASE_DIR' && nohup tar -cvf '$archive' '$fs' > '$log_file' 2>&1 &"
            else
                log "DRY-RUN: Would run on $node: cd '$APP_BASE_DIR' && nohup tar -cvf '$archive' '$fs' > '$log_file' 2>&1 &"
            fi
            continue
        fi

        if [ -z "$node" ]; then
            log "Launching local: nohup tar -cvf $archive $fs &"
            (
                cd "$APP_BASE_DIR" || exit 1
                nohup tar -cvf "$archive" "$fs" > "$log_file" 2>&1 </dev/null &
            ) &
        else
            log "Launching remote on $node: nohup tar -cvf $archive $fs &"
            # shellcheck disable=SC2086
            ssh $ssh_opts "$SSH_USER@$node" \
                "cd '$APP_BASE_DIR' && nohup tar -cvf '$archive' '$fs' > '$log_file' 2>&1 </dev/null &"
        fi

        log "Backup started: $archive"
        log "Backup log    : $log_file"
    done

    if [ "$FLASHBACK_MODE" != "real" ]; then
        log "DRY-RUN: No tar processes launched."
        return 0
    fi

    log "Backup commands were detached successfully for node '${node:-local}'."
}

overall_failed=0

if [ -n "$APP_NODES" ]; then
    for node in $APP_NODES; do
        log "--- Backing up node: $node ---"
        run_backup_on_node "$node" || overall_failed=$((overall_failed + 1))
    done
else
    if [ "$FLASHBACK_MODE" = "real" ]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null || true
        if [ ! -d "$BACKUP_DIR" ] || [ ! -w "$BACKUP_DIR" ]; then
            log "ERROR: Backup directory is not writable: $BACKUP_DIR"
            exit 3
        fi
        if [ ! -d "$APP_BASE_DIR" ]; then
            log "ERROR: Application base directory does not exist: $APP_BASE_DIR"
            exit 3
        fi
    else
        log "DRY-RUN: Would verify local directories: $APP_BASE_DIR and $BACKUP_DIR"
    fi
    run_backup_on_node "" || overall_failed=$((overall_failed + 1))
fi

if [ "$overall_failed" -gt 0 ]; then
    log "ERROR: $overall_failed node backup(s) failed."
    exit 1
fi

log "All filesystem backup jobs were started successfully."
exit 0
