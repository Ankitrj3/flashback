#!/usr/bin/env sh
# Detect DB-side values from the DB server using sqlplus OS authentication.

set -eu

ORACLE_ENV="${FLASHBACK_ORACLE_ENV:-}"

if [ -n "$ORACLE_ENV" ] && [ -f "$ORACLE_ENV" ]; then
    # shellcheck disable=SC1090
    . "$ORACLE_ENV"
fi

if ! command -v sqlplus >/dev/null 2>&1; then
    exit 2
fi

sqlplus -S "/ as sysdba" <<'EOF' | awk -F= '
  {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
  }
  /^FLASHBACK_/ {
    key=$1
    value=substr($0, index($0, "=") + 1)
    gsub(/"/, "\\\"", value)
    printf "%s=\"%s\"\n", key, value
  }
'
SET HEAD OFF FEED OFF PAGES 0 LINES 500 TRIMSPOOL ON VERIFY OFF
SELECT 'FLASHBACK_INSTANCE_ID=' || name FROM v$database;
SELECT 'FLASHBACK_DB_HOST=' || host_name FROM v$instance;
SELECT 'FLASHBACK_ALERT_LOG=' || value || '/alert_' || instance_name || '.log'
FROM v$diag_info, v$instance
WHERE name = 'Diag Trace';
SELECT 'FLASHBACK_PDB_NAME=' || name
FROM (
  SELECT name
  FROM v$pdbs
  WHERE open_mode = 'READ WRITE'
  ORDER BY con_id
)
WHERE rownum = 1;
EXIT;
EOF
