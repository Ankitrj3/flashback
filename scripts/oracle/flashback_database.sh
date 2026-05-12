#!/usr/bin/env sh
# Flashback Oracle CDB and PDB to guaranteed restore points, then drop them.

set -eu

log() {
    if [ "${FLASHBACK_LOG_TIMESTAMPS:-true}" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [flashback_database] $*"
    else
        echo "[flashback_database] $*"
    fi
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
PDB_NAME="${FLASHBACK_PDB_NAME:-$INSTANCE_ID}"
ORACLE_ENV="${FLASHBACK_ORACLE_ENV:-}"
FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"

CDB_RP_NAME="${1:-${FLASHBACK_CDB_RESTORE_POINT:-}}"
PDB_RP_NAME="${2:-${FLASHBACK_PDB_RESTORE_POINT:-}}"

if [ -z "$CDB_RP_NAME" ] || [ -z "$PDB_RP_NAME" ]; then
    log "ERROR: Both CDB and PDB restore point names are required."
    log "Usage: flashback_database.sh <CDB_RP_NAME> <PDB_RP_NAME>"
    exit 2
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

log "Instance ID      : $INSTANCE_ID"
log "PDB Name         : $PDB_NAME"
log "CDB Restore Point: $CDB_RP_NAME"
log "PDB Restore Point: $PDB_RP_NAME"
log "Mode             : $FLASHBACK_MODE"

if [ "$FLASHBACK_MODE" != "real" ]; then
    if ! command -v sqlplus >/dev/null 2>&1; then
        log "DRY-RUN: sqlplus is not on PATH here, but live execution would require it."
    fi
    log "DRY-RUN: Would connect using: sqlplus $CONNECT_LABEL"
    log "DRY-RUN: Step 1 — Verify restore points exist in V\$RESTORE_POINT"
    log "DRY-RUN: Step 2 — Close PDB: ALTER PLUGGABLE DATABASE $PDB_NAME CLOSE IMMEDIATE"
    log "DRY-RUN:   FLASHBACK PLUGGABLE DATABASE TO RESTORE POINT \"$PDB_RP_NAME\""
    log "DRY-RUN:   ALTER PLUGGABLE DATABASE $PDB_NAME OPEN RESETLOGS"
    log "DRY-RUN: Step 3 — SHUTDOWN IMMEDIATE; STARTUP MOUNT"
    log "DRY-RUN:   FLASHBACK DATABASE TO RESTORE POINT \"$CDB_RP_NAME\""
    log "DRY-RUN:   ALTER DATABASE OPEN RESETLOGS"
    log "DRY-RUN: Step 4 — ALTER PLUGGABLE DATABASE $PDB_NAME OPEN"
    log "DRY-RUN: Step 5 — DROP RESTORE POINT \"$CDB_RP_NAME\""
    log "DRY-RUN:   DROP RESTORE POINT \"$PDB_RP_NAME\""
    log "DRY-RUN: Step 6 — Verify V\$DATABASE, V\$PDBS, V\$RESTORE_POINT"
    exit 0
fi

if ! command -v sqlplus >/dev/null 2>&1; then
    log "ERROR: sqlplus not found on PATH."
    exit 3
fi

# Step 1: Verify restore points
log "Step 1: Verifying restore points exist..."
verify_result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD
SET HEAD OFF FEED OFF PAGES 0 LINES 200 TRIMSPOOL ON
SELECT 'RP_FOUND=' || NAME FROM V\$RESTORE_POINT WHERE NAME IN ('$CDB_RP_NAME','$PDB_RP_NAME');
EXIT;
EOF
)
echo "$verify_result"
if ! echo "$verify_result" | grep -q "RP_FOUND=$CDB_RP_NAME"; then
    log "ERROR: CDB restore point not found: $CDB_RP_NAME"; exit 1
fi
if ! echo "$verify_result" | grep -q "RP_FOUND=$PDB_RP_NAME"; then
    log "ERROR: PDB restore point not found: $PDB_RP_NAME"; exit 1
fi
log "Both restore points verified."

# Step 2: Close PDB and flashback PDB
log "Step 2: Closing and flashing back PDB..."
pdb_result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD
ALTER PLUGGABLE DATABASE $PDB_NAME CLOSE IMMEDIATE;
ALTER SESSION SET CONTAINER=$PDB_NAME;
FLASHBACK PLUGGABLE DATABASE TO RESTORE POINT "$PDB_RP_NAME";
ALTER SESSION SET CONTAINER=CDB\$ROOT;
ALTER PLUGGABLE DATABASE $PDB_NAME OPEN RESETLOGS;
EXIT;
EOF
)
echo "$pdb_result"
log "PDB flashback completed."

# Step 3: Flashback CDB
log "Step 3: Flashing back CDB..."
cdb_result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
FLASHBACK DATABASE TO RESTORE POINT "$CDB_RP_NAME";
ALTER DATABASE OPEN RESETLOGS;
EXIT;
EOF
)
echo "$cdb_result"
log "CDB flashback completed."

# Step 4: Open PDB
log "Step 4: Opening PDB..."
sqlplus -S /nolog <<EOF
CONNECT $CONNECT_CMD
ALTER PLUGGABLE DATABASE $PDB_NAME OPEN;
EXIT;
EOF
log "PDB opened."

# Step 5: Drop restore points
log "Step 5: Dropping restore points..."
sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD
DROP RESTORE POINT "$CDB_RP_NAME";
ALTER SESSION SET CONTAINER=$PDB_NAME;
DROP RESTORE POINT "$PDB_RP_NAME";
ALTER SESSION SET CONTAINER=CDB\$ROOT;
EXIT;
EOF
log "Restore points dropped."

# Step 6: Verify
log "Step 6: Verifying database state..."
sqlplus -S /nolog <<EOF
CONNECT $CONNECT_CMD
SET PAGES 220 LINES 200 HEAD ON FEED OFF
SELECT NAME, OPEN_MODE, LOG_MODE FROM V\$DATABASE;
SELECT NAME, OPEN_MODE FROM V\$PDBS ORDER BY CON_ID;
COL NAME FOR A50
SELECT NAME, TIME, GUARANTEE_FLASHBACK_DATABASE GUA, CON_ID FROM V\$RESTORE_POINT ORDER BY TIME;
EXIT;
EOF

log "SUCCESS: Database flashback complete."
exit 0
