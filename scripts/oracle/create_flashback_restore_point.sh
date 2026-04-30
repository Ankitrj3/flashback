#!/usr/bin/env sh
# =============================================================================
# create_flashback_restore_point.sh — Create guaranteed flashback restore points
#
# USAGE   : sh create_flashback_restore_point.sh
# EXIT    : 0 = restore points created on CDB and PDB
#           1 = restore point creation failed (SQL error)
#           2 = PDB switch / PDB restore point failed
#           3 = pre-check failed (not ARCHIVELOG / Flashback not enabled)
#
# CLIENT ENVIRONMENT (RXEST01):
#   Source env   : . ./rxecst01.sh
#   Connect      : sqlplus / as sysdba  (OS authentication)
#   CDB RP name  : RXEST01_CDB_flashback_restore_23APR26
#   PDB RP name  : RXEST01_PDB_flashback_restore_23APR26
#   Method       : Single sqlplus session, ALTER SESSION SET CONTAINER=RXEST01
#   Query after  : SELECT NAME, TIME, GUARANTEE_FLASHBACK_DATABASE,
#                         STORAGE_SIZE, PDB_RESTORE_POINT, CON_ID
#                  FROM V$RESTORE_POINT ORDER BY TIME;
#
# DEMO MODE:
#   Set FLASHBACK_DEMO=true to simulate with realistic SQL output.
#   The GUI sets this automatically when demo.enabled=true in config.json.
#
# CONFIGURATION (environment variables):
#   FLASHBACK_INSTANCE_ID    Instance prefix, e.g. RXEST01 (default: RXEST01)
#   FLASHBACK_ORACLE_ENV     Path to Oracle env script, e.g. /path/to/rxecst01.sh
#   FLASHBACK_DB_AUTH        "os" (default) or "network"
#   FLASHBACK_PDB_NAME       PDB container name (default: RXEST01)
#   --- network auth only ---
#   FLASHBACK_DB_HOST        Oracle hostname
#   FLASHBACK_DB_PORT        Listener port (default 1521)
#   FLASHBACK_DB_SERVICE     CDB service name
#   FLASHBACK_DB_USER        DBA username (default: sys)
#   FLASHBACK_DB_PASS        DBA password
# =============================================================================

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [create_flashback] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-RXEST01}"
PDB_NAME="${FLASHBACK_PDB_NAME:-RXEST01}"
DATE_TAG=$(date '+%d%b%y' | tr '[:lower:]' '[:upper:]')   # e.g. 23APR26

CDB_RP_NAME="${INSTANCE_ID}_CDB_flashback_restore_${DATE_TAG}"
PDB_RP_NAME="${INSTANCE_ID}_PDB_flashback_restore_${DATE_TAG}"

# =============================================================================
# DEMO MODE
# =============================================================================
if [ "${FLASHBACK_DEMO:-false}" = "true" ]; then
    log "DEMO MODE: Simulating guaranteed flashback restore point creation."
    log "DEMO: Instance ID    : $INSTANCE_ID"
    log "DEMO: PDB Name       : $PDB_NAME"
    log "DEMO: CDB RP name    : $CDB_RP_NAME"
    log "DEMO: PDB RP name    : $PDB_RP_NAME"
    log "DEMO:"
    log "DEMO: Sourcing Oracle env: . ./rxecst01.sh (simulated)"
    log "DEMO: Connecting: sqlplus / as sysdba (simulated)"
    sleep 1
    log "DEMO: Pre-check: Database LOG_MODE: ARCHIVELOG  OK (simulated)"
    log "DEMO: Pre-check: Flashback Database: YES  OK (simulated)"
    log "DEMO:"
    log "DEMO: -- CDB restore point --"
    log "DEMO: SQL> CREATE RESTORE POINT \"$CDB_RP_NAME\" GUARANTEE FLASHBACK DATABASE;"
    sleep 1
    log "DEMO: Restore point created."
    log "DEMO:"
    log "DEMO: -- Switch to PDB --"
    log "DEMO: SQL> ALTER SESSION SET CONTAINER=$PDB_NAME;"
    log "DEMO: Session altered."
    sleep 1
    log "DEMO: -- PDB restore point --"
    log "DEMO: SQL> CREATE RESTORE POINT \"$PDB_RP_NAME\" GUARANTEE FLASHBACK DATABASE;"
    log "DEMO: Restore point created."
    log "DEMO:"
    log "DEMO: -- Back to CDB root, verify all restore points --"
    log "DEMO: SQL> ALTER SESSION SET CONTAINER=CDB\$ROOT;"
    log "DEMO: SQL> SELECT NAME, TIME, GUARANTEE_FLASHBACK_DATABASE GUA,"
    log "DEMO:            STORAGE_SIZE, PDB_RESTORE_POINT PDB, CON_ID"
    log "DEMO:      FROM V\$RESTORE_POINT ORDER BY TIME;"
    log "DEMO:"
    log "DEMO:  NAME                                 TIME                            GUA  STORAGE_SIZE  PDB  CON_ID"
    log "DEMO:  -----------------------------------  ------------------------------  ---  ------------  ---  ------"
    log "DEMO:  $CDB_RP_NAME  $(date '+%d-%b-%y %I.%M.%S000000000 %p')  YES  2.4484E+12    NO   0"
    log "DEMO:  $PDB_RP_NAME  $(date '+%d-%b-%y %I.%M.%S000000000 %p')  YES  2.6322E+11    YES  4"
    log "DEMO:"
    log "DEMO: SUCCESS: Both restore points created. (simulated)"
    log "CDB_RESTORE_POINT=$CDB_RP_NAME"
    log "PDB_RESTORE_POINT=$PDB_RP_NAME"
    exit 0
fi

# =============================================================================
# REAL MODE
# =============================================================================

# ---- Source Oracle environment ----
ORACLE_ENV="${FLASHBACK_ORACLE_ENV:-}"
if [ -n "$ORACLE_ENV" ] && [ -f "$ORACLE_ENV" ]; then
    log "Sourcing Oracle environment: $ORACLE_ENV"
    # shellcheck disable=SC1090
    . "$ORACLE_ENV"
elif [ -n "$ORACLE_ENV" ]; then
    log "WARNING: Oracle env file not found: $ORACLE_ENV"
    log "Assuming ORACLE_HOME and sqlplus are already on PATH."
fi

# ---- Build sqlplus connection string ----
DB_AUTH="${FLASHBACK_DB_AUTH:-os}"
if [ "$DB_AUTH" = "os" ]; then
    CONNECT_CMD="/ as sysdba"
    log "Auth mode: OS authentication (sqlplus / as sysdba)"
else
    DB_HOST="${FLASHBACK_DB_HOST:-}"
    DB_PORT="${FLASHBACK_DB_PORT:-1521}"
    DB_SERVICE="${FLASHBACK_DB_SERVICE:-}"
    DB_USER="${FLASHBACK_DB_USER:-sys}"
    DB_PASS="${FLASHBACK_DB_PASS:-}"
    CONNECT_CMD="${DB_USER}/${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_SERVICE} as sysdba"
    log "Auth mode: network (${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_SERVICE})"
fi

log "Instance ID  : $INSTANCE_ID"
log "PDB Name     : $PDB_NAME"
log "CDB RP name  : $CDB_RP_NAME"
log "PDB RP name  : $PDB_RP_NAME"

if ! command -v sqlplus > /dev/null 2>&1; then
    log "ERROR: sqlplus not found on PATH."
    log "  Source Oracle env file or add \$ORACLE_HOME/bin to PATH."
    exit 3
fi

# ---- Single sqlplus session: pre-check, CDB RP, switch to PDB, PDB RP, verify ----
log "Starting sqlplus session..."
result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD

-- Pre-check: ARCHIVELOG + Flashback mode
SET HEAD OFF FEED OFF
SELECT 'LOG_MODE=' || LOG_MODE || '|FLASHBACK_ON=' || FLASHBACK_ON FROM v\$database;
SET HEAD ON FEED ON

-- Create CDB restore point
PROMPT -- Creating CDB restore point: $CDB_RP_NAME
CREATE RESTORE POINT "$CDB_RP_NAME" GUARANTEE FLASHBACK DATABASE;

-- Switch to PDB
PROMPT -- Switching to PDB: $PDB_NAME
ALTER SESSION SET CONTAINER=$PDB_NAME;

-- Create PDB restore point
PROMPT -- Creating PDB restore point: $PDB_RP_NAME
CREATE RESTORE POINT "$PDB_RP_NAME" GUARANTEE FLASHBACK DATABASE;

-- Return to CDB root
ALTER SESSION SET CONTAINER=CDB\$ROOT;

-- Verify: show all restore points
PROMPT -- Verifying restore points:
SET PAGES 220
SET LINE 200
COL NAME FOR A50
COL TIME FOR A35
COL GUA  FOR A3
COL PDB  FOR A3
SELECT NAME, TIME, GUARANTEE_FLASHBACK_DATABASE GUA,
       STORAGE_SIZE, PDB_RESTORE_POINT PDB, CON_ID
FROM v\$restore_point
ORDER BY TIME;

EXIT;
EOF
)

echo "$result"

# Check ARCHIVELOG
if ! echo "$result" | grep -q "LOG_MODE=ARCHIVELOG"; then
    log "ERROR: Database is NOT in ARCHIVELOG mode."
    exit 3
fi

# Check Flashback ON
if ! echo "$result" | grep -q "FLASHBACK_ON=YES"; then
    log "ERROR: Flashback Database is NOT enabled. Run: ALTER DATABASE FLASHBACK ON;"
    exit 3
fi

# Confirm CDB restore point was created
if ! echo "$result" | grep -q "$CDB_RP_NAME"; then
    log "ERROR: CDB restore point '$CDB_RP_NAME' not visible in V\$RESTORE_POINT."
    exit 1
fi

# Confirm PDB restore point was created
if ! echo "$result" | grep -q "$PDB_RP_NAME"; then
    log "ERROR: PDB restore point '$PDB_RP_NAME' not visible in V\$RESTORE_POINT."
    exit 2
fi

log "SUCCESS: Both restore points created."
log "CDB_RESTORE_POINT=$CDB_RP_NAME"
log "PDB_RESTORE_POINT=$PDB_RP_NAME"
exit 0
