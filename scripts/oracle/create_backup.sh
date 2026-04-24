#!/usr/bin/env sh
# =============================================================================
# create_backup.sh — Parallel nohup tar backup of EBS application filesystems
#
# USAGE   : sh create_backup.sh
# EXIT    : 0 = all backups completed successfully
#           1 = one or more backups failed
#           3 = configuration error (backup dir not writable / base dir missing)
#
# CLIENT ENVIRONMENT (RXEST01):
#   Base dir : /db8000/app/oracle/r122rxest01
#   Filesys  : fs_ne, fs1, fs2  (relative to base_dir)
#   Backup   : /iriscommon/backups/tars/RXEST01_fs_ne_backup_23APR26.tar
#   Method   : nohup tar -cvf ... &  (all 3 launched in parallel, then wait)
#   No compression: large EBS filesystems (100GB+) — gzip would take hours
#
# DEMO MODE:
#   Set FLASHBACK_DEMO=true to simulate backup with realistic output.
#   The GUI sets this automatically when demo.enabled=true in config.json.
#
# CONFIGURATION (environment variables set by the GUI / config.json):
#   FLASHBACK_INSTANCE_ID   Instance identifier  (default: RXEST01)
#   FLASHBACK_APP_BASE_DIR  Base dir on app node (default: /db8000/app/oracle/r122rxest01)
#   FLASHBACK_BACKUP_DIR    Destination for .tar files (default: /iriscommon/backups/tars)
#   FLASHBACK_FS_LIST       Space-separated relative fs names (default: fs_ne fs1 fs2)
#   FLASHBACK_APP_NODES     Space-separated app node hostnames (SSH remote backup)
#   FLASHBACK_SSH_USER      SSH username (default: oracle)
#   FLASHBACK_SSH_KEY       Path to SSH private key (optional)
# =============================================================================

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [create_backup] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-RXEST01}"
DATE_TAG=$(date '+%d%b%y' | tr '[:lower:]' '[:upper:]')   # e.g. 23APR26

# =============================================================================
# DEMO MODE
# =============================================================================
if [ "${FLASHBACK_DEMO:-false}" = "true" ]; then
    log "DEMO MODE: Simulating parallel nohup tar backup."
    log "DEMO: Instance     : $INSTANCE_ID"
    log "DEMO: Base dir     : /db8000/app/oracle/r122rxest01 (simulated)"
    log "DEMO: Backup dir   : /iriscommon/backups/tars (simulated)"
    log "DEMO: Filesystems  : fs_ne  fs1  fs2"
    log "DEMO:"
    log "DEMO: Launching all 3 tar jobs in parallel (nohup ... &) ..."
    log "DEMO: nohup tar -cvf /iriscommon/backups/tars/${INSTANCE_ID}_fs_ne_backup_${DATE_TAG}.tar fs_ne &"
    log "DEMO: nohup tar -cvf /iriscommon/backups/tars/${INSTANCE_ID}_fs1_Patch_backup_${DATE_TAG}.tar fs1 &"
    log "DEMO: nohup tar -cvf /iriscommon/backups/tars/${INSTANCE_ID}_fs2_Run_backup_${DATE_TAG}.tar fs2 &"
    sleep 1
    log "DEMO: [pid 12301] fs_ne backup running... (simulated)"
    log "DEMO: [pid 12302] fs1 backup running... (simulated)"
    log "DEMO: [pid 12303] fs2 backup running... (simulated)"
    sleep 2
    log "DEMO: Waiting for all tar processes to complete..."
    sleep 1
    log "DEMO: [pid 12301] fs_ne done — ${INSTANCE_ID}_fs_ne_backup_${DATE_TAG}.tar  (142 GB) (simulated)"
    log "DEMO: [pid 12302] fs1 done   — ${INSTANCE_ID}_fs1_Patch_backup_${DATE_TAG}.tar (89 GB) (simulated)"
    log "DEMO: [pid 12303] fs2 done   — ${INSTANCE_ID}_fs2_Run_backup_${DATE_TAG}.tar (211 GB) (simulated)"
    log "DEMO: All filesystem backups completed successfully. (simulated)"
    exit 0
fi

# =============================================================================
# REAL MODE
# =============================================================================

APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-/db8000/app/oracle/r122rxest01}"
BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/iriscommon/backups/tars}"
FS_LIST="${FLASHBACK_FS_LIST:-fs_ne fs1 fs2}"
APP_NODES="${FLASHBACK_APP_NODES:-}"
SSH_USER="${FLASHBACK_SSH_USER:-oracle}"
SSH_KEY="${FLASHBACK_SSH_KEY:-}"

log "Starting parallel filesystem backup."
log "Instance     : $INSTANCE_ID"
log "Base dir     : $APP_BASE_DIR"
log "Backup dir   : $BACKUP_DIR"
log "Filesystems  : $FS_LIST"
log "Date tag     : $DATE_TAG"

# ---- Helper: human-readable label per filesystem ----
fs_label() {
    case "$1" in
        fs_ne) echo "fs_ne" ;;
        fs1)   echo "fs1_Patch" ;;
        fs2)   echo "fs2_Run" ;;
        *)     echo "$1" ;;
    esac
}

# ---- Backup on a single node (local or via SSH) ----
run_backup_on_node() {
    node="$1"   # empty string = local
    pids=""

    for fs in $FS_LIST; do
        label=$(fs_label "$fs")
        archive="${BACKUP_DIR}/${INSTANCE_ID}_${label}_backup_${DATE_TAG}.tar"
        log_file="${BACKUP_DIR}/${INSTANCE_ID}_${label}_backup_${DATE_TAG}.log"

        if [ -z "$node" ]; then
            # Local backup — cd to base dir, use relative path
            log "Launching local: nohup tar -cvf $archive $fs &"
            (
                cd "$APP_BASE_DIR" || exit 1
                nohup tar -cvf "$archive" "$fs" > "$log_file" 2>&1
            ) &
            pids="$pids $!"
        else
            # Remote backup via SSH — run nohup on remote node
            ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"
            [ -n "$SSH_KEY" ] && ssh_opts="$ssh_opts -i $SSH_KEY"
            log "Launching remote on $node: nohup tar -cvf $archive $fs &"
            # shellcheck disable=SC2086
            ssh $ssh_opts "$SSH_USER@$node" \
                "cd '$APP_BASE_DIR' && nohup tar -cvf '$archive' '$fs' > '$log_file' 2>&1" &
            pids="$pids $!"
        fi
    done

    # Wait for all tar processes
    log "Waiting for all tar processes to complete..."
    FAILED=0
    for pid in $pids; do
        if ! wait "$pid"; then
            log "ERROR: A tar process (pid=$pid) failed."
            FAILED=$((FAILED + 1))
        fi
    done

    if [ "$FAILED" -gt 0 ]; then
        log "ERROR: $FAILED backup job(s) failed on node '${node:-local}'."
        return 1
    fi

    # Report sizes
    for fs in $FS_LIST; do
        label=$(fs_label "$fs")
        archive="${BACKUP_DIR}/${INSTANCE_ID}_${label}_backup_${DATE_TAG}.tar"
        if [ -z "$node" ]; then
            size=$(du -sh "$archive" 2>/dev/null | cut -f1 || echo "?")
            log "Done: $archive ($size)"
        else
            log "Done: $SSH_USER@$node:$archive"
        fi
    done
    return 0
}

# Validate backup directory
mkdir -p "$BACKUP_DIR" 2>/dev/null || true
if [ ! -d "$BACKUP_DIR" ]; then
    log "ERROR: Backup directory does not exist and could not be created: $BACKUP_DIR"
    exit 3
fi
if [ ! -w "$BACKUP_DIR" ]; then
    log "ERROR: Backup directory is not writable: $BACKUP_DIR"
    exit 3
fi

OVERALL_FAILED=0

if [ -n "$APP_NODES" ]; then
    for node in $APP_NODES; do
        log "--- Backing up node: $node ---"
        run_backup_on_node "$node" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
    done
else
    # Local: verify base dir exists
    if [ ! -d "$APP_BASE_DIR" ]; then
        log "ERROR: Application base directory does not exist: $APP_BASE_DIR"
        exit 3
    fi
    run_backup_on_node "" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
fi

if [ "$OVERALL_FAILED" -gt 0 ]; then
    log "ERROR: $OVERALL_FAILED node backup(s) failed."
    exit 1
fi

log "All filesystem backups completed successfully."
exit 0
