#!/usr/bin/env sh
# Restore Flashback orchestrator.
# Reverses a Make Flashback Request by restoring application filesystems
# and flashing back the Oracle database to selected restore points.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FLASHBACK_LOG_FILE="${FLASHBACK_LOG_FILE:-$SCRIPT_DIR/../../logs/flashback_execution.log}"

log() {
    echo "$*"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[restore_flashback] %s\n' "$*" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

marker() {
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$1] $2 : $ts"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[restore_flashback] [%s] %s : %s\n' "$1" "$2" "$ts" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
PDB_NAME="${FLASHBACK_PDB_NAME:-$INSTANCE_ID}"
RESTORE_DATE_TAG="${FLASHBACK_RESTORE_DATE_TAG:-}"
SKIP_APP_STOP="${FLASHBACK_SKIP_APP_STOP:-false}"

# When called in detached mode the menu pre-sets these env vars so the
# script can run fully non-interactive.
CDB_RP_NAME="${FLASHBACK_CDB_RESTORE_POINT:-}"
PDB_RP_NAME="${FLASHBACK_PDB_RESTORE_POINT:-}"

if [ -z "$CDB_RP_NAME" ] || [ -z "$PDB_RP_NAME" ]; then
    echo ""
    log "Querying available restore points..."
    echo ""

    if ! sh "$SCRIPT_DIR/list_restore_points.sh"; then
        log "ERROR: Failed to query restore points."
        exit 1
    fi
        echo ""

    DATE_TAG_DEFAULT=$(date '+%d%b%y')
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

marker "START" "Restore Flashback"
log "CDB Restore Point: $CDB_RP_NAME"
log "PDB Restore Point: $PDB_RP_NAME"
log "App backup tag   : ${RESTORE_DATE_TAG:-auto-detect latest}"

echo ""
marker "START" "Step 1/5: Stopping application services"
if [ "$SKIP_APP_STOP" = "true" ]; then
    log "Application service stop was already completed by the menu pre-check."
else
    if ! sh "$SCRIPT_DIR/stop_app_services.sh"; then
        log "ERROR: Application service shutdown failed."
        exit 1
    fi
fi
marker "END" "Step 1/5: Stopping application services"

echo ""
marker "START" "Step 2/5: Restoring application filesystems"
if ! sh "$SCRIPT_DIR/restore_backup.sh" "$RESTORE_DATE_TAG"; then
    log "ERROR: Application filesystem restore failed."
    exit 1
fi
marker "END" "Step 2/5: Restoring application filesystems"

echo ""
marker "START" "Step 3/5: Flashing back database"
if ! sh "$SCRIPT_DIR/flashback_database.sh" "$CDB_RP_NAME" "$PDB_RP_NAME"; then
    log "ERROR: Database flashback failed."
    exit 1
fi
marker "END" "Step 3/5: Flashing back database"

echo ""
marker "START" "Step 4/5: Starting application services"
if ! sh "$SCRIPT_DIR/start_app_services.sh"; then
    log "WARNING: Application startup may need manual intervention."
fi
marker "END" "Step 4/5: Starting application services"

echo ""
marker "START" "Step 5/5: Restore summary"
log "  CDB Restore Point : $CDB_RP_NAME (flashed back and dropped)"
log "  PDB Restore Point : $PDB_RP_NAME (flashed back and dropped)"
log "  Filesystems       : restored from tar backups"
log "  App services      : start attempted"
marker "END" "Step 5/5: Restore summary"
marker "END" "Restore Flashback"

exit 0
