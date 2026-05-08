#!/usr/bin/env sh
# Create CDB and PDB guaranteed restore points from the DB server.

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [create_flashback] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
PDB_NAME="${FLASHBACK_PDB_NAME:-$INSTANCE_ID}"
ORACLE_ENV="${FLASHBACK_ORACLE_ENV:-}"
FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"
# Client runbook format, for example 28APR26.
DATE_TAG=$(date '+%d%b%y' | tr '[:lower:]' '[:upper:]')

CDB_RP_NAME="${INSTANCE_ID}_CDB_flashback_restore_${DATE_TAG}"
PDB_RP_NAME="${INSTANCE_ID}_PDB_flashback_restore_${DATE_TAG}"

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

if [ "$FLASHBACK_MODE" != "real" ]; then
    if ! command -v sqlplus >/dev/null 2>&1; then
        log "DRY-RUN: sqlplus is not on PATH here, but live execution would require it."
    fi
    log "DRY-RUN: Would connect using: sqlplus $CONNECT_LABEL"
    log "DRY-RUN: Would verify ARCHIVELOG and FLASHBACK_ON."
    log "DRY-RUN: Would create CDB restore point: $CDB_RP_NAME"
    log "DRY-RUN: Would run: ALTER SESSION SET CONTAINER=$PDB_NAME"
    log "DRY-RUN: Would create PDB restore point: $PDB_RP_NAME"
    log "DRY-RUN: Would query V\$RESTORE_POINT for verification."
    log "CDB_RESTORE_POINT=$CDB_RP_NAME"
    log "PDB_RESTORE_POINT=$PDB_RP_NAME"
    exit 0
fi

if ! command -v sqlplus >/dev/null 2>&1; then
    log "ERROR: sqlplus not found on PATH. Run this from DB server or source DB env first."
    exit 3
fi

precheck_result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD

SET HEAD OFF FEED OFF
SELECT 'LOG_MODE=' || LOG_MODE || '|FLASHBACK_ON=' || FLASHBACK_ON FROM v\$database;
SET HEAD ON FEED ON
EXIT;
EOF
)

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

echo "$result"

if ! echo "$result" | grep -q "$CDB_RP_NAME"; then
    log "ERROR: CDB restore point was not found after creation."
    exit 1
fi

if ! echo "$result" | grep -q "$PDB_RP_NAME"; then
    log "ERROR: PDB restore point was not found after creation."
    exit 2
fi

log "SUCCESS: Both restore points created."
log "CDB_RESTORE_POINT=$CDB_RP_NAME"
log "PDB_RESTORE_POINT=$PDB_RP_NAME"
exit 0
