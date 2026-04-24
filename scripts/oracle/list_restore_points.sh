#!/usr/bin/env sh
# =============================================================================
# list_restore_points.sh — Query live V$RESTORE_POINT from Oracle
#
# USAGE   : sh list_restore_points.sh
# EXIT    : 0 = query successful (output on stdout in CSV-friendly format)
#           1 = sqlplus query failed
#           2 = sqlplus not available
#
# PURPOSE:
#   Provides the Restore workflow with a LIVE list of restore points directly
#   from Oracle V$RESTORE_POINT. The GUI parses this output to populate the
#   restore point dropdown instead of relying on the static demo JSON file.
#
# CLIENT ENVIRONMENT (RXEST01):
#   Source env : . ./rxecst01.sh
#   Connect    : sqlplus / as sysdba
#   Query      : SELECT NAME, TIME, GUARANTEE_FLASHBACK_DATABASE,
#                       STORAGE_SIZE, PDB_RESTORE_POINT, CON_ID
#                FROM V$RESTORE_POINT ORDER BY TIME;
#
# OUTPUT FORMAT (tab-delimited for easy parsing):
#   #NAME<TAB>TIME<TAB>GUA<TAB>STORAGE_SIZE<TAB>PDB<TAB>CON_ID
#   RXEST01_CDB_flashback_restore_11FEB26<TAB>2026-02-11 14:00:00<TAB>YES<TAB>...
#
# DEMO MODE:
#   Outputs the same table using demo/restore_points.json content (simulated).
#
# CONFIGURATION (environment variables):
#   FLASHBACK_ORACLE_ENV    Path to Oracle env file
#   FLASHBACK_DB_AUTH       "os" or "network"
#   FLASHBACK_INSTANCE_ID   Instance prefix
# =============================================================================

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [list_restore_points] $*" >&2
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-RXEST01}"

# =============================================================================
# DEMO MODE — Output matches the client's V$RESTORE_POINT format
# =============================================================================
if [ "${FLASHBACK_DEMO:-false}" = "true" ]; then
    log "DEMO MODE: Outputting simulated V\$RESTORE_POINT data."

    # Header line — parsed by GUI to detect columns
    echo "#NAME	TIME	GUA	STORAGE_SIZE	PDB	CON_ID"

    # Simulated rows matching client naming convention
    echo "${INSTANCE_ID}_CDB_26MARCH2026_DATA	26-MAR-26 06.31.28 PM	YES	2.4484E+12	NO	0"
    echo "${INSTANCE_ID}_PDB_26MARCH2026_DATA	26-MAR-26 06.31.28 PM	YES	2.6322E+11	YES	4"
    echo "${INSTANCE_ID}_CDB_04082026	08-APR-26 05.42.18 PM	YES	0	NO	0"
    echo "${INSTANCE_ID}_CDB_flashback_restore_11FEB26	11-FEB-26 14.00.00 PM	YES	2.4484E+12	NO	0"
    echo "${INSTANCE_ID}_PDB_flashback_restore_11FEB26	11-FEB-26 14.00.00 PM	YES	2.6322E+11	YES	4"

    log "DEMO: 5 restore points returned (simulated)."
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
fi

if ! command -v sqlplus > /dev/null 2>&1; then
    log "ERROR: sqlplus not found on PATH."
    exit 2
fi

DB_AUTH="${FLASHBACK_DB_AUTH:-os}"
if [ "$DB_AUTH" = "os" ]; then
    CONNECT_CMD="/ as sysdba"
else
    CONNECT_CMD="${FLASHBACK_DB_USER:-sys}/${FLASHBACK_DB_PASS:-}@${FLASHBACK_DB_HOST:-}:${FLASHBACK_DB_PORT:-1521}/${FLASHBACK_DB_SERVICE:-} as sysdba"
fi

log "Querying V\$RESTORE_POINT from Oracle ..."

# Output header
echo "#NAME	TIME	GUA	STORAGE_SIZE	PDB	CON_ID"

# Query: output tab-delimited for easy parsing by Python
sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD
SET PAGES 0
SET HEAD OFF
SET FEED OFF
SET COLSEP '	'
SET LINE 300
SELECT TRIM(NAME),
       TO_CHAR(TIME,'DD-MON-YY HH.MI.SS AM'),
       TRIM(GUARANTEE_FLASHBACK_DATABASE),
       NVL(TO_CHAR(STORAGE_SIZE),'0'),
       TRIM(PDB_RESTORE_POINT),
       TO_CHAR(CON_ID)
FROM v\$restore_point
ORDER BY TIME;
EXIT;
EOF

log "Query complete."
exit 0
