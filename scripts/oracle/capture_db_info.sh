#!/usr/bin/env sh
# =============================================================================
# capture_db_info.sh — Query V$RESTORE_POINT and let operator select one
#
# USAGE   : sh capture_db_info.sh
#           eval $(sh capture_db_info.sh --export)
#
# EXIT    : 0 = restore point selected (variables exported on stdout)
#           1 = sqlplus query failed / no restore points found
#           2 = sqlplus not available
#           3 = operator cancelled selection
#
# PURPOSE:
#   Connects to Oracle DB, runs the V$RESTORE_POINT query, presents a
#   numbered list of available restore points, and outputs the selected
#   restore point as shell variable assignments. The caller (menu script)
#   can eval the output to capture the variables.
#
# OUTPUT VARIABLES (printed to stdout when --export is used):
#   SELECTED_RESTORE_POINT       — Name of the selected restore point
#   RESTORE_POINT_TIME           — Timestamp of the selected point
#   RESTORE_POINT_GUARANTEED     — YES or NO
#   RESTORE_POINT_STORAGE        — Storage size
#   RESTORE_POINT_PDB            — PDB restore point (YES/NO)
#   RESTORE_POINT_CON_ID         — Container ID (0=CDB, 4=PDB typically)
#
# DEMO MODE:
#   Set FLASHBACK_DEMO=true to simulate with realistic restore point data.
#
# CONFIGURATION (environment variables):
#   FLASHBACK_ORACLE_ENV    Path to Oracle env file
#   FLASHBACK_DB_AUTH       "os" or "network"
#   FLASHBACK_INSTANCE_ID   Instance prefix
# =============================================================================

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [capture_db_info] $*" >&2
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-RXEST01}"
EXPORT_MODE="false"
if [ "${1:-}" = "--export" ]; then
    EXPORT_MODE="true"
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
log ""

# ---- Query restore points in a parseable format (pipe-delimited) ----
RAW_OUTPUT=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD
SET PAGES 0
SET HEAD OFF
SET FEED OFF
SET LINE 500
SET TRIMSPOOL ON
SET COLSEP '|'

SELECT TRIM(NAME) || '|' || TRIM(TO_CHAR(TIME, 'DD-MON-YY HH.MI.SS AM')) || '|' || TRIM(GUARANTEE_FLASHBACK_DATABASE) || '|' || TRIM(TO_CHAR(STORAGE_SIZE)) || '|' || TRIM(PDB_RESTORE_POINT) || '|' || TRIM(TO_CHAR(CON_ID))
FROM V\$RESTORE_POINT
ORDER BY TIME;
EXIT;
EOF
)

if [ $? -ne 0 ]; then
    log "ERROR: sqlplus query failed."
    exit 1
fi

# Filter out empty lines and SQL*Plus noise
PARSED_DATA=$(echo "$RAW_OUTPUT" | grep '|' | grep -v '^\-\-' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [ -z "$PARSED_DATA" ]; then
    log "WARNING: No restore points found in V\$RESTORE_POINT."
    log "  The database may not have any guaranteed flashback restore points."
    exit 1
fi

# ---- Also show the formatted table for visual reference ----
log "=============================================================================="
log " AVAILABLE RESTORE POINTS"
log "=============================================================================="
log ""

# Print header
printf "  %-4s %-45s %-25s %-4s %-15s %-4s %-6s\n" "#" "NAME" "TIME" "GUA" "STORAGE_SIZE" "PDB" "CON_ID" >&2
printf "  %-4s %-45s %-25s %-4s %-15s %-4s %-6s\n" "----" "---------------------------------------------" "-------------------------" "---" "---------------" "---" "------" >&2

i=1
echo "$PARSED_DATA" | while IFS='|' read -r name time gua storage pdb conid; do
    printf "  %-4s %-45s %-25s %-4s %-15s %-4s %-6s\n" "[$i]" "$name" "$time" "$gua" "$storage" "$pdb" "$conid" >&2
    i=$((i + 1))
done

log ""

# Count total restore points
TOTAL=$(echo "$PARSED_DATA" | wc -l | tr -d ' ')

# ---- Interactive selection ----
printf "  Enter restore point number [1-%s] (or 'q' to cancel): " "$TOTAL" >&2
read -r selection

if [ "$selection" = "q" ] || [ "$selection" = "Q" ]; then
    log "Selection cancelled by operator."
    exit 3
fi

# Validate selection
if ! echo "$selection" | grep -qE '^[0-9]+$'; then
    log "ERROR: Invalid selection: '$selection'. Enter a number between 1 and $TOTAL."
    exit 3
fi

if [ "$selection" -lt 1 ] || [ "$selection" -gt "$TOTAL" ]; then
    log "ERROR: Selection out of range. Enter a number between 1 and $TOTAL."
    exit 3
fi

# Extract the selected row
SELECTED_ROW=$(echo "$PARSED_DATA" | sed -n "${selection}p")
SEL_NAME=$(echo "$SELECTED_ROW" | cut -d'|' -f1)
SEL_TIME=$(echo "$SELECTED_ROW" | cut -d'|' -f2)
SEL_GUA=$(echo "$SELECTED_ROW" | cut -d'|' -f3)
SEL_STORAGE=$(echo "$SELECTED_ROW" | cut -d'|' -f4)
SEL_PDB=$(echo "$SELECTED_ROW" | cut -d'|' -f5)
SEL_CONID=$(echo "$SELECTED_ROW" | cut -d'|' -f6)

log ""
log "Selected restore point:"
log "  Name       : $SEL_NAME"
log "  Time       : $SEL_TIME"
log "  Guaranteed : $SEL_GUA"
log "  Storage    : $SEL_STORAGE"
log "  PDB        : $SEL_PDB"
log "  CON_ID     : $SEL_CONID"
log ""

# ---- Output variables for eval ----
if [ "$EXPORT_MODE" = "true" ]; then
    echo "SELECTED_RESTORE_POINT=\"$SEL_NAME\""
    echo "RESTORE_POINT_TIME=\"$SEL_TIME\""
    echo "RESTORE_POINT_GUARANTEED=\"$SEL_GUA\""
    echo "RESTORE_POINT_STORAGE=\"$SEL_STORAGE\""
    echo "RESTORE_POINT_PDB=\"$SEL_PDB\""
    echo "RESTORE_POINT_CON_ID=\"$SEL_CONID\""
else
    log "DB info capture complete. Use: eval \$(sh capture_db_info.sh --export)"
fi

exit 0
