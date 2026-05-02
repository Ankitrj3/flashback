#!/usr/bin/env sh
# =============================================================================
# flashback_to_restore_point.sh — Flashback Oracle CDB+PDB to a restore point
#
# USAGE   : sh flashback_to_restore_point.sh <CDB_RESTORE_POINT> [PDB_RESTORE_POINT]
#           If only 1 arg given, it is used for both CDB and PDB checks.
#
# EXIT    : 0 = flashback completed, DB is OPEN READ WRITE, PDBs open
#           1 = restore point not found or not GUARANTEED
#           2 = FLASHBACK DATABASE or OPEN RESETLOGS failed
#           3 = PDBs did not open in READ WRITE mode
#           9 = usage error
#
# CLIENT ENVIRONMENT (RXEST01):
#   Source env : . ./rxecst01.sh
#   Connect    : sqlplus / as sysdba
#   4-step SQL :
#     1) Verify restore point exists in V$RESTORE_POINT (GUARANTEED=YES)
#     2) ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE
#     3) FLASHBACK DATABASE TO RESTORE POINT "..."
#        ALTER DATABASE OPEN RESETLOGS
#     4) ALTER PLUGGABLE DATABASE ALL OPEN
#        SELECT NAME, TIME, GUA, STORAGE_SIZE, PDB, CON_ID FROM V$RESTORE_POINT
#
# DEMO MODE:
#   Set FLASHBACK_DEMO=true to simulate all 4 steps with realistic output.
#
# CONFIGURATION (environment variables):
#   FLASHBACK_ORACLE_ENV   Path to Oracle env script (rxecst01.sh)
#   FLASHBACK_DB_AUTH      "os" (default) or "network"
#   FLASHBACK_INSTANCE_ID  Instance prefix (default: RXEST01)
#   --- network auth only ---
#   FLASHBACK_DB_HOST / FLASHBACK_DB_PORT / FLASHBACK_DB_SERVICE
#   FLASHBACK_DB_USER / FLASHBACK_DB_PASS
# =============================================================================

set -eu

CDB_RESTORE_POINT="${1:-}"
if [ -z "$CDB_RESTORE_POINT" ]; then
    echo "Usage: $0 <CDB_RESTORE_POINT> [PDB_RESTORE_POINT]" >&2
    exit 9
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [flashback_restore] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-RXEST01}"

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
fi

# ---- Connection string ----
DB_AUTH="${FLASHBACK_DB_AUTH:-os}"
if [ "$DB_AUTH" = "os" ]; then
    CONNECT_CMD="/ as sysdba"
else
    CONNECT_CMD="${FLASHBACK_DB_USER:-sys}/${FLASHBACK_DB_PASS:-}@${FLASHBACK_DB_HOST:-}:${FLASHBACK_DB_PORT:-1521}/${FLASHBACK_DB_SERVICE:-} as sysdba"
fi

if ! command -v sqlplus > /dev/null 2>&1; then
    log "ERROR: sqlplus not found on PATH. Source Oracle env file first."
    exit 1
fi

log "========================================================================"
log " ORACLE FLASHBACK DATABASE - RESTORE STARTING"
log "  Instance      : $INSTANCE_ID"
log "  Restore Point : $CDB_RESTORE_POINT"
log "  Operator time : $(date '+%Y-%m-%d %H:%M:%S')"
log "========================================================================"

# Step 1: Verify restore point
log "Step 1/4: Verifying restore point '$CDB_RESTORE_POINT' ..."
rp_check=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD
SET PAGES 220
SET LINE 200
COL NAME FOR A50
COL TIME FOR A35
COL GUA  FOR A3
COL PDB  FOR A3
SELECT NAME, TIME, GUARANTEE_FLASHBACK_DATABASE GUA,
       STORAGE_SIZE, PDB_RESTORE_POINT PDB, CON_ID
FROM v\$restore_point
WHERE NAME='$CDB_RESTORE_POINT';
EXIT;
EOF
)
echo "$rp_check" | sed 's/^/    /'
if ! echo "$rp_check" | grep -q "$CDB_RESTORE_POINT"; then
    log "ERROR: Restore point '$CDB_RESTORE_POINT' not found in V\$RESTORE_POINT."
    exit 1
fi
if ! echo "$rp_check" | grep -iq "YES"; then
    log "ERROR: Restore point '$CDB_RESTORE_POINT' is NOT guaranteed."
    exit 1
fi
log "Pre-check passed: GUARANTEED restore point found."

# Step 2: Close PDBs
log "Step 2/4: Closing all PDBs ..."
sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 2;
CONNECT $CONNECT_CMD
ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE;
SELECT CON_ID, NAME, OPEN_MODE FROM v\$pdbs;
EXIT;
EOF
log "All PDBs closed."

# Step 3: Flashback + open resetlogs
log "Step 3/4: Executing FLASHBACK DATABASE TO RESTORE POINT '$CDB_RESTORE_POINT' ..."
flashback_result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 2;
CONNECT $CONNECT_CMD
FLASHBACK DATABASE TO RESTORE POINT "$CDB_RESTORE_POINT";
ALTER DATABASE OPEN RESETLOGS;
SELECT STATUS, INSTANCE_NAME, DATABASE_STATUS FROM v\$instance;
SELECT NAME, OPEN_MODE, LOG_MODE FROM v\$database;
EXIT;
EOF
)
echo "$flashback_result" | sed 's/^/    /'
if ! echo "$flashback_result" | grep -iq "OPEN"; then
    log "ERROR: Database may not have opened after flashback."
    log "CRITICAL: Manual DBA intervention required."
    exit 2
fi
log "Flashback complete. Database OPEN with RESETLOGS."

# Step 4: Open PDBs + final verification
log "Step 4/4: Opening all PDBs and verifying ..."
pdb_result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 3;
CONNECT $CONNECT_CMD
ALTER PLUGGABLE DATABASE ALL OPEN;
SELECT CON_ID, NAME, OPEN_MODE FROM v\$pdbs ORDER BY CON_ID;

-- Final restore point verification
SET PAGES 220
SET LINE 200
COL NAME FOR A50
COL TIME FOR A35
COL GUA  FOR A3
COL PDB  FOR A3
PROMPT -- Current restore points after flashback:
SELECT NAME, TIME, GUARANTEE_FLASHBACK_DATABASE GUA,
       STORAGE_SIZE, PDB_RESTORE_POINT PDB, CON_ID
FROM v\$restore_point ORDER BY TIME;
EXIT;
EOF
)
echo "$pdb_result" | sed 's/^/    /'
if ! echo "$pdb_result" | grep -iq "READ WRITE"; then
    log "WARNING: PDBs may not be in READ WRITE mode. Check V\$PDBS manually."
    exit 3
fi
log "All PDBs opened in READ WRITE mode."

log "========================================================================"
log " ORACLE FLASHBACK DATABASE - RESTORE COMPLETE"
log "  Instance      : $INSTANCE_ID"
log "  Restore Point : $CDB_RESTORE_POINT"
log "  Completed at  : $(date '+%Y-%m-%d %H:%M:%S')"
log "  Database is   : OPEN (READ WRITE)"
log "========================================================================"
exit 0
