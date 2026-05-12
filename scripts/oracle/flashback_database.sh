#!/usr/bin/env sh
# Flashback Oracle CDB and PDB to guaranteed restore points, then drop them.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FLASHBACK_LOG_FILE="${FLASHBACK_LOG_FILE:-$SCRIPT_DIR/../../logs/flashback_execution.log}"

log() {
    echo "$*"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[%s] [flashback_database] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
PDB_NAME="${FLASHBACK_PDB_NAME:-$INSTANCE_ID}"
ORACLE_ENV="${FLASHBACK_ORACLE_ENV:-}"
FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"
DB_UNIQUE_NAME="${FLASHBACK_DB_UNIQUE_NAME:-$INSTANCE_ID}"

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
log "DB unique name   : $DB_UNIQUE_NAME"
log "Mode             : $FLASHBACK_MODE"

if [ "$FLASHBACK_MODE" != "real" ]; then
    if ! command -v sqlplus >/dev/null 2>&1; then
        log "DRY-RUN: sqlplus is not on PATH here, but live execution would require it."
    fi
    log "DRY-RUN: Would connect using: sqlplus $CONNECT_LABEL"
    log "DRY-RUN: Step 1 - Show cluster_database and prepare RAC database if needed."
    log "DRY-RUN: Step 2 - Verify restore points exist in V\$RESTORE_POINT."
    log "DRY-RUN: Step 3 - Close PDB and flashback PDB to \"$PDB_RP_NAME\"."
    log "DRY-RUN: Step 4 - Restart CDB in mount and flashback CDB to \"$CDB_RP_NAME\"."
    log "DRY-RUN: Step 5 - Open PDB, drop restore points, and verify DB state."
    log "DRY-RUN: Step 6 - Restore cluster_database=TRUE and start with srvctl if RAC was detected."
    exit 0
fi

if ! command -v sqlplus >/dev/null 2>&1; then
    log "ERROR: sqlplus not found on PATH."
    exit 3
fi

cluster_value=$(sqlplus -S /nolog <<EOF 2>/dev/null | awk -F= '/^CLUSTER_DATABASE=/{print $2; exit}'
CONNECT $CONNECT_CMD
SET HEAD OFF FEED OFF PAGES 0 LINES 200 TRIMSPOOL ON
SELECT 'CLUSTER_DATABASE=' || VALUE FROM V\$PARAMETER WHERE NAME='cluster_database';
EXIT;
EOF
)
cluster_value=$(echo "${cluster_value:-FALSE}" | tr '[:lower:]' '[:upper:]')
log "cluster_database : $cluster_value"

if [ "$cluster_value" = "TRUE" ]; then
    log "Preparing RAC database for flashback by setting cluster_database=FALSE."
    sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD
ALTER SYSTEM SET CLUSTER_DATABASE=FALSE SCOPE=SPFILE;
EXIT;
EOF

    if command -v srvctl >/dev/null 2>&1; then
        log "srvctl status database -d $DB_UNIQUE_NAME"
        srvctl status database -d "$DB_UNIQUE_NAME" || true
        log "srvctl stop database -d $DB_UNIQUE_NAME"
        srvctl stop database -d "$DB_UNIQUE_NAME"
    else
        log "WARNING: srvctl not found; falling back to sqlplus shutdown immediate."
        sqlplus -S /nolog <<EOF
CONNECT $CONNECT_CMD
SHUTDOWN IMMEDIATE;
EXIT;
EOF
    fi

    log "Starting one instance with cluster_database=FALSE."
    sqlplus -S /nolog <<EOF
CONNECT $CONNECT_CMD
STARTUP;
EXIT;
EOF
fi

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
    log "ERROR: CDB restore point not found: $CDB_RP_NAME"
    exit 1
fi
if ! echo "$verify_result" | grep -q "RP_FOUND=$PDB_RP_NAME"; then
    log "ERROR: PDB restore point not found: $PDB_RP_NAME"
    exit 1
fi
log "Both restore points verified."

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

log "Step 4: Opening PDB..."
sqlplus -S /nolog <<EOF
CONNECT $CONNECT_CMD
ALTER PLUGGABLE DATABASE $PDB_NAME OPEN;
EXIT;
EOF
log "PDB opened."

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

if [ "$cluster_value" = "TRUE" ]; then
    log "Restoring cluster_database=TRUE and restarting database with srvctl."
    sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD
ALTER SYSTEM SET CLUSTER_DATABASE=TRUE SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
EXIT;
EOF

    if command -v srvctl >/dev/null 2>&1; then
        srvctl start database -d "$DB_UNIQUE_NAME"
    else
        log "WARNING: srvctl not found; database remains stopped after restoring cluster_database=TRUE."
    fi
fi

log "SUCCESS: Database flashback complete."
exit 0
