#!/usr/bin/env sh
# Create CDB and PDB guaranteed restore points from the DB server.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FLASHBACK_LOG_FILE="${FLASHBACK_LOG_FILE:-$SCRIPT_DIR/../../logs/flashback_execution.log}"

log() {
    echo "$*"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[create_flashback] %s\n' "$*" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

marker() {
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$1] $2 : $ts"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[create_flashback] [%s] %s : %s\n' "$1" "$2" "$ts" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
PDB_NAME="${FLASHBACK_PDB_NAME:-$INSTANCE_ID}"
ORACLE_ENV="${FLASHBACK_ORACLE_ENV:-}"
RESTORE_SUFFIX="${FLASHBACK_RESTORE_SUFFIX:-}"
# Client runbook format, preserving the date command's natural month case.
# Hour+minute suffix ensures uniqueness when multiple RPs are created on the same day.
DATE_TAG=$(date '+%d%b%y_%H%M')

if [ -n "$RESTORE_SUFFIX" ]; then
    CDB_RP_NAME="${INSTANCE_ID}_CDB_${RESTORE_SUFFIX}"
    PDB_RP_NAME="${INSTANCE_ID}_PDB_${RESTORE_SUFFIX}"
else
    CDB_RP_NAME="${INSTANCE_ID}_CDB_flashback_restore_${DATE_TAG}"
    PDB_RP_NAME="${INSTANCE_ID}_PDB_flashback_restore_${DATE_TAG}"
fi

if [ -n "$ORACLE_ENV" ] && [ -f "$ORACLE_ENV" ]; then
    log "Sourcing Oracle environment: $ORACLE_ENV"
    # shellcheck disable=SC1090
    . "$ORACLE_ENV"
elif [ -n "$ORACLE_ENV" ]; then
    log "WARNING: Oracle env file not found: $ORACLE_ENV"
fi

DB_AUTH="${FLASHBACK_DB_AUTH:-os}"
if [ "$DB_AUTH" = "os" ]; then
    CONNECT_CMD="/ as sysdba"
    CONNECT_LABEL="/ as sysdba"
else
    CONNECT_CMD="${FLASHBACK_DB_USER:-sys}/${FLASHBACK_DB_PASS:-}@${FLASHBACK_DB_HOST:-}:${FLASHBACK_DB_PORT:-1521}/${FLASHBACK_DB_SERVICE:-} as sysdba"
    CONNECT_LABEL="${FLASHBACK_DB_USER:-sys}/*****@${FLASHBACK_DB_HOST:-}:${FLASHBACK_DB_PORT:-1521}/${FLASHBACK_DB_SERVICE:-} as sysdba"
fi

log "Instance ID  : $INSTANCE_ID"
log "PDB Name     : $PDB_NAME"
log "CDB RP name  : $CDB_RP_NAME"
log "PDB RP name  : $PDB_RP_NAME"

if ! command -v sqlplus >/dev/null 2>&1; then
    log "ERROR: sqlplus not found on PATH. Run this from DB server or source DB env first."
    exit 3
fi

marker "START" "DB restore point precheck"
precheck_result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD

SET HEAD OFF FEED OFF
SELECT 'LOG_MODE=' || LOG_MODE || '|FLASHBACK_ON=' || FLASHBACK_ON FROM v\$database;
SET HEAD ON FEED ON
EXIT;
EOF
)
marker "END" "DB restore point precheck"

echo "$precheck_result"

# Validate recoverability prerequisites before issuing any restore-point DDL.
# A failed precheck must leave the database untouched.
if ! echo "$precheck_result" | grep -q "LOG_MODE=ARCHIVELOG"; then
    log "ERROR: Database is not in ARCHIVELOG mode."
    exit 3
fi

if ! echo "$precheck_result" | grep -q "FLASHBACK_ON=YES"; then
    log "ERROR: Flashback Database is not enabled."
    exit 3
fi

marker "START" "Create CDB/PDB restore points"
# Temporarily disable errexit so that a sqlplus ORA- error does not silently
# kill the script before we can echo the error output to the operator.
set +e
result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD

PROMPT -- Creating CDB restore point: $CDB_RP_NAME
CREATE RESTORE POINT "$CDB_RP_NAME" GUARANTEE FLASHBACK DATABASE;

PROMPT -- Switching to PDB: $PDB_NAME
ALTER SESSION SET CONTAINER=$PDB_NAME;

PROMPT -- Creating PDB restore point: $PDB_RP_NAME
CREATE RESTORE POINT "$PDB_RP_NAME" GUARANTEE FLASHBACK DATABASE;

ALTER SESSION SET CONTAINER=CDB\$ROOT;

PROMPT -- Verifying restore points:
SET PAGES 220
SET LINE 200
COL NAME FOR A50
COL TIME FOR A35
COL GUA FOR A3
COL PDB FOR A3
SELECT NAME, TIME, GUARANTEE_FLASHBACK_DATABASE GUA,
       STORAGE_SIZE, PDB_RESTORE_POINT PDB, CON_ID
FROM v\$restore_point
ORDER BY TIME;

EXIT;
EOF
)
sqlplus_rc=$?
set -e
marker "END" "Create CDB/PDB restore points"

# Always print sqlplus output so operator can see any ORA- error details.
echo "$result"

if [ "$sqlplus_rc" -ne 0 ]; then
    log "ERROR: sqlplus exited with code $sqlplus_rc during restore point creation."
    log "       Check the ORA- error above. Common causes:"
    log "       ORA-38778 : restore point name already exists (run again, name is now time-stamped)"
    log "       ORA-01031 : insufficient privileges (connect as sysdba required)"
    log "       ORA-01261 : flash recovery area issue"
    exit 1
fi

marker "START" "Verify restore points"
if ! echo "$result" | grep -q "$CDB_RP_NAME"; then
    log "ERROR: CDB restore point was not found after creation."
    exit 1
fi

if ! echo "$result" | grep -q "$PDB_RP_NAME"; then
    log "ERROR: PDB restore point was not found after creation."
    exit 2
fi
marker "END" "Verify restore points"

log "SUCCESS: Both restore points created."
log "CDB_RESTORE_POINT=$CDB_RP_NAME"
log "PDB_RESTORE_POINT=$PDB_RP_NAME"
exit 0
