#!/usr/bin/env sh
# Restore Flashback — Orchestrator
# Reverses a "Make Flashback Request" by restoring application filesystems
# and flashing back the Oracle database to guaranteed restore points.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

log() {
    echo "[restore_flashback] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
PDB_NAME="${FLASHBACK_PDB_NAME:-$INSTANCE_ID}"
FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"
ORACLE_ENV="${FLASHBACK_ORACLE_ENV:-}"

# Tell sub-scripts to omit per-line timestamps from log() output.
export FLASHBACK_LOG_TIMESTAMPS=false

# --- Step 0: Resolve restore point names ---
# When called in detached mode the menu pre-sets these env vars so the
# script can run fully non-interactive.
CDB_RP_NAME="${FLASHBACK_CDB_RESTORE_POINT:-}"
PDB_RP_NAME="${FLASHBACK_PDB_RESTORE_POINT:-}"

if [ -z "$CDB_RP_NAME" ] || [ -z "$PDB_RP_NAME" ]; then
    # Interactive mode — show available restore points and prompt.
    echo ""
    log "Querying available restore points..."
    echo ""

    if [ "$FLASHBACK_MODE" != "real" ]; then
        if ! command -v sqlplus >/dev/null 2>&1; then
            log "DRY-RUN: sqlplus not on PATH. Skipping live restore point query."
            log "DRY-RUN: In live execution, V\$RESTORE_POINT would be queried here."
            echo ""
        else
            sh "$SCRIPT_DIR/list_restore_points.sh" 2>/dev/null || true
            echo ""
        fi
    else
        if ! sh "$SCRIPT_DIR/list_restore_points.sh"; then
            log "ERROR: Failed to query restore points."
            exit 1
        fi
        echo ""
    fi

    DATE_TAG_DEFAULT=$(date '+%d%b%y' | tr '[:lower:]' '[:upper:]')
    CDB_RP_DEFAULT="${INSTANCE_ID}_CDB_flashback_restore_${DATE_TAG_DEFAULT}"
    PDB_RP_DEFAULT="${INSTANCE_ID}_PDB_flashback_restore_${DATE_TAG_DEFAULT}"

    printf "Enter CDB restore point name [%s]: " "$CDB_RP_DEFAULT"
    read -r CDB_RP_NAME
    CDB_RP_NAME="${CDB_RP_NAME:-$CDB_RP_DEFAULT}"

    printf "Enter PDB restore point name [%s]: " "$PDB_RP_DEFAULT"
    read -r PDB_RP_NAME
    PDB_RP_NAME="${PDB_RP_NAME:-$PDB_RP_DEFAULT}"
fi

export FLASHBACK_CDB_RESTORE_POINT="$CDB_RP_NAME"
export FLASHBACK_PDB_RESTORE_POINT="$PDB_RP_NAME"

# --- Start banner with timestamp ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [restore_flashback] Restore Flashback Started."
log "CDB Restore Point: $CDB_RP_NAME"
log "PDB Restore Point: $PDB_RP_NAME"
log "Mode             : $FLASHBACK_MODE"

# --- Step 1: Stop application services ---
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 1/5: Stopping application services — Started."
if ! sh "$SCRIPT_DIR/stop_app_services.sh"; then
    log "ERROR: Application service shutdown failed."
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 1/5: Stopping application services — Completed."

# --- Step 2: Restore application filesystems from tar backups ---
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 2/5: Restoring application filesystems — Started."
if ! sh "$SCRIPT_DIR/restore_backup.sh"; then
    log "ERROR: Application filesystem restore failed."
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 2/5: Restoring application filesystems — Completed."

# --- Step 3: Flashback database to restore points ---
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 3/5: Flashing back database — Started."
if ! sh "$SCRIPT_DIR/flashback_database.sh" "$CDB_RP_NAME" "$PDB_RP_NAME"; then
    log "ERROR: Database flashback failed."
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 3/5: Flashing back database — Completed."

# --- Step 4: Start application services ---
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 4/5: Starting application services — Started."
if ! sh "$SCRIPT_DIR/start_app_services.sh"; then
    log "WARNING: Application startup may need manual intervention."
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 4/5: Starting application services — Completed."

# --- Step 5: Summary ---
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 5/5: Restore summary"
log "  CDB Restore Point : $CDB_RP_NAME (flashed back & dropped)"
log "  PDB Restore Point : $PDB_RP_NAME (flashed back & dropped)"
log "  Filesystems       : restored from tar backups"
log "  App services      : start attempted"
log "  Mode              : $FLASHBACK_MODE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [restore_flashback] Restore Flashback Completed."

exit 0
