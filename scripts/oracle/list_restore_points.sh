#!/usr/bin/env sh
# Query live V$RESTORE_POINT from Oracle.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FLASHBACK_LOG_FILE="${FLASHBACK_LOG_FILE:-$SCRIPT_DIR/../../logs/flashback_execution.log}"

log() {
    echo "$*" >&2
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[list_restore_points] %s\n' "$*" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

marker() {
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$1] $2 : $ts" >&2
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[list_restore_points] [%s] %s : %s\n' "$1" "$2" "$ts" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

ORACLE_ENV="${FLASHBACK_ORACLE_ENV:-}"
if [ -n "$ORACLE_ENV" ] && [ -f "$ORACLE_ENV" ]; then
    log "Sourcing Oracle environment: $ORACLE_ENV"
    # shellcheck disable=SC1090
    . "$ORACLE_ENV"
elif [ -n "$ORACLE_ENV" ]; then
    log "WARNING: Oracle env file not found: $ORACLE_ENV"
fi

if ! command -v sqlplus >/dev/null 2>&1; then
    log "ERROR: sqlplus not found on PATH."
    exit 2
fi

DB_AUTH="${FLASHBACK_DB_AUTH:-os}"
if [ "$DB_AUTH" = "os" ]; then
    CONNECT_CMD="/ as sysdba"
else
    CONNECT_CMD="${FLASHBACK_DB_USER:-sys}/${FLASHBACK_DB_PASS:-}@${FLASHBACK_DB_HOST:-}:${FLASHBACK_DB_PORT:-1521}/${FLASHBACK_DB_SERVICE:-} as sysdba"
fi

marker "START" "Query V\$RESTORE_POINT"

sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 1;
CONNECT $CONNECT_CMD
SET PAGES 220
SET HEAD ON
SET FEED OFF
SET LINE 200
COL TIME FOR A40
COL NAME FOR A40
SELECT NAME,TIME,GUARANTEE_FLASHBACK_DATABASE,STORAGE_SIZE,PDB_RESTORE_POINT,CON_ID
FROM V\$RESTORE_POINT
ORDER BY TIME;
EXIT;
EOF

marker "END" "Query V\$RESTORE_POINT"
exit 0
