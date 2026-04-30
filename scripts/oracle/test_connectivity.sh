#!/usr/bin/env sh
# =============================================================================
# test_connectivity.sh — Verify SSH and Oracle DB connectivity
#
# USAGE   : sh test_connectivity.sh
# EXIT    : 0 = all checks passed
#           1 = SSH connectivity failure
#           2 = Oracle DB connectivity failure
#           3 = configuration error
#
# CLIENT ENVIRONMENT (RXEST01):
#   Source env : . ./rxecst01.sh
#   Connect    : sqlplus / as sysdba
#   Checks     : SSH ping all app nodes + Oracle DB ping + V$SESSION SOA check
#
# DEMO MODE:
#   Set FLASHBACK_DEMO=true to simulate all checks successfully.
#
# CONFIGURATION (environment variables):
#   FLASHBACK_ORACLE_ENV   Path to Oracle env file (rxecst01.sh)
#   FLASHBACK_DB_AUTH      "os" or "network" (default: os)
#   FLASHBACK_APP_NODES    Space-separated app node hostnames
#   FLASHBACK_SSH_USER     SSH username (default: oracle)
#   FLASHBACK_SSH_KEY      Path to SSH private key (optional)
#   FLASHBACK_INSTANCE_ID  Instance prefix (default: RXEST01)
# =============================================================================

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [test_connectivity] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-RXEST01}"
APP_NODES="${FLASHBACK_APP_NODES:-}"
SSH_USER="${FLASHBACK_SSH_USER:-oracle}"
SSH_KEY="${FLASHBACK_SSH_KEY:-}"

# =============================================================================
# DEMO MODE
# =============================================================================
if [ "${FLASHBACK_DEMO:-false}" = "true" ]; then
    log "DEMO MODE: Running simulated connectivity check."
    log "DEMO: Instance    : $INSTANCE_ID"
    log "DEMO: App nodes   : node2 node3 node4 node5 node6 node7 (simulated)"
    log ""
    for node in node2 node3 node4 node5 node6 node7; do
        log "DEMO: SSH check : $node ... OK (simulated)"
    done
    log ""
    log "DEMO: DB check  : Connecting as sysdba (OS auth) ... OK (simulated)"
    log "DEMO: DB mode   : ARCHIVELOG | FLASHBACK_ON=YES (simulated)"
    log "DEMO: Flashback : ENABLED (simulated)"
    log ""
    log "DEMO: SOA session check (from DB node) ..."
    log "DEMO:"
    log "DEMO:   USERNAME   STATUS    PROGRAM            MACHINE    CNT"
    log "DEMO:   ---------  --------  -----------------  ---------  ---"
    log "DEMO:   SOA_APP    ACTIVE    JDBC Thin Client   appnode2   3"
    log "DEMO:   USER1      INACTIVE  sqlplus            appnode3   1"
    log "DEMO:"
    log "DEMO: WARNING: 1 SOA active connection found. Inform SOA Admins before shutdown. (simulated)"
    log ""
    log "DEMO: All connectivity checks passed. (simulated)"
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

log "Starting connectivity checks."
log "Instance    : $INSTANCE_ID"

# 1. SSH checks for all app nodes
if [ -n "$APP_NODES" ]; then
    for node in $APP_NODES; do
        log "SSH check : $node"
        ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"
        [ -n "$SSH_KEY" ] && ssh_opts="$ssh_opts -i $SSH_KEY"
        # shellcheck disable=SC2086
        if ! ssh $ssh_opts "$SSH_USER@$node" "echo SSHOK_$node" 2>/dev/null | grep -q "SSHOK_$node"; then
            log "ERROR: SSH failed to node: $node"
            exit 1
        fi
        log "SSH OK    : $node"
    done
else
    log "INFO: FLASHBACK_APP_NODES is empty — skipping SSH checks."
fi

# 2. Oracle DB connectivity (OS auth or network)
if ! command -v sqlplus > /dev/null 2>&1; then
    log "ERROR: sqlplus not found on PATH. Source Oracle env file first."
    exit 2
fi

DB_AUTH="${FLASHBACK_DB_AUTH:-os}"
if [ "$DB_AUTH" = "os" ]; then
    CONNECT_CMD="/ as sysdba"
    log "DB check  : sqlplus / as sysdba"
else
    CONNECT_CMD="${FLASHBACK_DB_USER:-sys}/${FLASHBACK_DB_PASS:-}@${FLASHBACK_DB_HOST:-}:${FLASHBACK_DB_PORT:-1521}/${FLASHBACK_DB_SERVICE:-} as sysdba"
    log "DB check  : ${FLASHBACK_DB_USER:-sys}@${FLASHBACK_DB_HOST:-}:${FLASHBACK_DB_PORT:-1521}/${FLASHBACK_DB_SERVICE:-}"
fi

db_result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 2;
CONNECT $CONNECT_CMD
SELECT 'PING_OK|' || LOG_MODE || '|FLASHBACK=' || FLASHBACK_ON AS probe FROM v\$database;
EXIT;
EOF
)

if ! echo "$db_result" | grep -q "PING_OK"; then
    log "ERROR: Oracle DB connectivity failed."
    echo "$db_result" | sed 's/^/    /'
    exit 2
fi
log "DB OK     : $(echo "$db_result" | grep PING_OK | tr '|' ' ')"

if ! echo "$db_result" | grep -q "ARCHIVELOG"; then
    log "WARNING: DB is not in ARCHIVELOG mode — Flashback requires ARCHIVELOG."
fi
if echo "$db_result" | grep -q "FLASHBACK=YES"; then
    log "Flashback : ENABLED"
else
    log "WARNING: Flashback Database is DISABLED. Run: ALTER DATABASE FLASHBACK ON;"
fi

# 3. SOA session check (informational — does not block)
log "SOA session check (querying V\$SESSION from DB node) ..."
soa_result=$(sqlplus -S /nolog <<EOF
WHENEVER SQLERROR EXIT 0;
CONNECT $CONNECT_CMD
SET PAGES 100
SET LINE 180
COL USERNAME FOR A12
COL STATUS   FOR A10
COL PROGRAM  FOR A30
COL MACHINE  FOR A20
SELECT USERNAME, STATUS, PROGRAM, MACHINE, COUNT(*) CNT
FROM v\$session
WHERE USERNAME IS NOT NULL
  AND USERNAME NOT IN ('SYS','SYSTEM','DBSNMP','RMAN')
GROUP BY USERNAME, STATUS, PROGRAM, MACHINE
ORDER BY CNT DESC;
EXIT;
EOF
)
echo "$soa_result" | sed 's/^/  /'

soa_count=$(echo "$soa_result" | grep -ic "ACTIVE" || true)
if [ "$soa_count" -gt 0 ]; then
    log "WARNING: $soa_count active session group(s) found."
    log "WARNING: Inform SOA Admins to shutdown SOA managed servers before DB operation."
else
    log "Session check: No active non-DBA sessions found."
fi

log "All connectivity checks passed."
exit 0
