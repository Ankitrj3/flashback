#!/usr/bin/env sh
# Validate that the restored system is ready to hand over for load testing.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FLASHBACK_LOG_FILE="${FLASHBACK_LOG_FILE:-$SCRIPT_DIR/../../logs/flashback_execution.log}"

log() {
    echo "$*"
    mkdir -p "$(dirname "$FLASHBACK_LOG_FILE")" 2>/dev/null || true
    printf '[%s] [validate_load_test] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$FLASHBACK_LOG_FILE" 2>/dev/null || true
}

section() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

record_pass() {
    log "PASS: $*"
    PASS_COUNT=$((PASS_COUNT + 1))
}

record_warn() {
    log "WARN: $*"
    WARN_COUNT=$((WARN_COUNT + 1))
}

record_fail() {
    log "FAIL: $*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-DBNAME}"
PDB_NAME="${FLASHBACK_PDB_NAME:-$INSTANCE_ID}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-/db800/app/oracle/r122${INSTANCE_ID}}"
APP_HOST="${FLASHBACK_APP_HOST:-}"
SSH_USER="${FLASHBACK_SSH_USER:-$(whoami)}"
ORACLE_ENV="${FLASHBACK_ORACLE_ENV:-}"
FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"
APP_INFO_FILE="${FLASHBACK_APP_INFO_FILE:-$HOME/.flashback_app_info}"
MIN_FREE_GB="${FLASHBACK_LOAD_TEST_MIN_FREE_GB:-50}"
MIN_APP_PROCESSES="${FLASHBACK_LOAD_TEST_MIN_APP_PROCESSES:-3}"
URLS="${FLASHBACK_LOAD_TEST_URLS:-}"
ALERT_LOG="${FLASHBACK_ALERT_LOG:-}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

if [ -f "$APP_INFO_FILE" ]; then
    # shellcheck disable=SC1090
    . "$APP_INFO_FILE"
fi

RUN_FS="${FLASHBACK_RUN_FS:-$APP_BASE_DIR/fs2/EBSapps/appl}"
PATCH_FS="${FLASHBACK_PATCH_FS:-$APP_BASE_DIR/fs1/EBSapps/appl}"
NE_FS="${FLASHBACK_NE_FS:-$APP_BASE_DIR/fs_ne}"

run_app_cmd() {
    cmd="$1"
    if [ -n "$APP_HOST" ]; then
        ssh -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no "$SSH_USER@$APP_HOST" "$cmd"
    else
        sh -c "$cmd"
    fi
}

normalize_count() {
    raw_count="${1:-}"
    case "$raw_count" in
        ''|*[!0-9]*) echo "0" ;;
        *) echo "$raw_count" ;;
    esac
}

count_app_processes() {
    run_app_cmd "ps -ef | egrep \"FND|INV|frm|java|http|aporx\" | egrep -v \"bash|ssh|ps|grep\" | wc -l" 2>/dev/null | tr -d ' '
}

detect_alert_log() {
    if [ -n "$ALERT_LOG" ]; then
        echo "$ALERT_LOG"
        return 0
    fi

    if ! command -v sqlplus >/dev/null 2>&1; then
        return 1
    fi

    sqlplus -S "/ as sysdba" <<EOF 2>/dev/null | awk -F= '/^ALERT_LOG=/{print $2; exit}'
SET HEAD OFF FEED OFF PAGES 0 LINES 300 TRIMSPOOL ON
SELECT 'ALERT_LOG=' || VALUE || '/alert_' || INSTANCE_NAME || '.log'
FROM V\$DIAG_INFO, V\$INSTANCE
WHERE NAME = 'Diag Trace';
EXIT;
EOF
}

check_app_node() {
    section "APPLICATION NODE READINESS"

    if [ "$FLASHBACK_MODE" != "real" ]; then
        record_pass "DRY-RUN: Would verify SSH/local command access for application node."
        record_pass "DRY-RUN: Would check app process count is >= $MIN_APP_PROCESSES."
        record_pass "DRY-RUN: Would verify RUN/PATCH/NE filesystem paths."
        record_pass "DRY-RUN: Would verify at least ${MIN_FREE_GB}GB free under $APP_BASE_DIR."
        return 0
    fi

    if run_app_cmd "test -d '$APP_BASE_DIR'"; then
        record_pass "Application base directory is reachable: $APP_BASE_DIR"
    else
        record_fail "Application base directory is not reachable: $APP_BASE_DIR"
        return 0
    fi

    proc_count=$(normalize_count "$(count_app_processes || echo 0)")
    log "Application process count: $proc_count"
    if [ "$proc_count" -ge "$MIN_APP_PROCESSES" ]; then
        record_pass "Application services appear to be running."
    else
        record_fail "Application process count is below expected minimum $MIN_APP_PROCESSES."
    fi

    for path in "$RUN_FS" "$PATCH_FS" "$NE_FS"; do
        if run_app_cmd "test -d '$path'"; then
            record_pass "Filesystem path exists: $path"
        else
            record_fail "Filesystem path missing: $path"
        fi
    done

    available_gb=$(run_app_cmd "df -Pk '$APP_BASE_DIR' | awk 'NR==2 { printf \"%d\", \$4 / 1048576 }'" 2>/dev/null || echo 0)
    available_gb=$(normalize_count "$available_gb")
    log "Available space under $APP_BASE_DIR: ${available_gb}GB"
    if [ "$available_gb" -ge "$MIN_FREE_GB" ]; then
        record_pass "Application base directory has enough free space."
    else
        record_warn "Free space under $APP_BASE_DIR is below ${MIN_FREE_GB}GB."
    fi
}

check_urls() {
    section "APPLICATION URL CHECKS"

    if [ -z "$URLS" ]; then
        record_warn "No FLASHBACK_LOAD_TEST_URLS configured; skipping HTTP URL checks."
        return 0
    fi

    if [ "$FLASHBACK_MODE" != "real" ]; then
        for url in $URLS; do
            record_pass "DRY-RUN: Would check URL: $url"
        done
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        record_warn "curl is not available; skipping URL checks."
        return 0
    fi

    for url in $URLS; do
        status=$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 "$url" 2>/dev/null || echo 000)
        case "$status" in
            2*|3*) record_pass "URL reachable ($status): $url" ;;
            *) record_fail "URL check failed ($status): $url" ;;
        esac
    done
}

run_db_checks() {
    section "DATABASE READINESS"

    if [ "$FLASHBACK_MODE" != "real" ]; then
        record_pass "DRY-RUN: Would source Oracle environment and connect with sqlplus."
        record_pass "DRY-RUN: Would verify database and PDB are open."
        record_warn "DRY-RUN: Would report invalid object count, active sessions, and blocking sessions."
        return 0
    fi

    if [ -n "$ORACLE_ENV" ] && [ -f "$ORACLE_ENV" ]; then
        # shellcheck disable=SC1090
        . "$ORACLE_ENV"
    fi

    if ! command -v sqlplus >/dev/null 2>&1; then
        record_fail "sqlplus not found on PATH; cannot validate database readiness."
        return 0
    fi

    db_output=$(sqlplus -S "/ as sysdba" <<EOF 2>/dev/null || true
SET HEAD OFF FEED OFF PAGES 0 LINES 500 TRIMSPOOL ON
SELECT 'DATABASE_OPEN_MODE=' || OPEN_MODE FROM V\$DATABASE;
SELECT 'DATABASE_LOG_MODE=' || LOG_MODE FROM V\$DATABASE;
SELECT 'PDB_OPEN_MODE=' || NAME || '=' || OPEN_MODE
FROM V\$PDBS
WHERE LOWER(NAME) = LOWER('$PDB_NAME');
SELECT 'INVALID_OBJECTS=' || COUNT(*) FROM DBA_OBJECTS WHERE STATUS='INVALID';
SELECT 'NON_BACKGROUND_SESSIONS=' || COUNT(*) FROM GV\$SESSION WHERE PROGRAM NOT LIKE 'oracle@%';
SELECT 'ACTIVE_NON_BACKGROUND_SESSIONS=' || COUNT(*) FROM GV\$SESSION WHERE PROGRAM NOT LIKE 'oracle@%' AND STATUS='ACTIVE';
SELECT 'BLOCKING_SESSIONS=' || COUNT(*) FROM GV\$SESSION WHERE BLOCKING_SESSION IS NOT NULL;
EXIT;
EOF
)

    echo "$db_output"

    db_open=$(echo "$db_output" | awk -F= '/^DATABASE_OPEN_MODE=/{print $2; exit}')
    if [ "$db_open" = "READ WRITE" ]; then
        record_pass "Database is READ WRITE."
    else
        record_fail "Database open mode is not READ WRITE: ${db_open:-unknown}"
    fi

    pdb_open=$(echo "$db_output" | awk -F= '/^PDB_OPEN_MODE=/{print $3; exit}')
    if [ "$pdb_open" = "READ WRITE" ]; then
        record_pass "PDB $PDB_NAME is READ WRITE."
    else
        record_fail "PDB $PDB_NAME open mode is not READ WRITE: ${pdb_open:-not found}"
    fi

    invalid_count=$(normalize_count "$(echo "$db_output" | awk -F= '/^INVALID_OBJECTS=/{print $2; exit}')")
    if [ "$invalid_count" -eq 0 ]; then
        record_pass "No invalid database objects found."
    else
        record_warn "Invalid database object count: $invalid_count"
    fi

    blocking_count=$(normalize_count "$(echo "$db_output" | awk -F= '/^BLOCKING_SESSIONS=/{print $2; exit}')")
    if [ "$blocking_count" -eq 0 ]; then
        record_pass "No blocking database sessions found."
    else
        record_fail "Blocking database session count: $blocking_count"
    fi
}

check_alert_log() {
    section "ALERT LOG CHECK"

    if [ "$FLASHBACK_MODE" != "real" ]; then
        record_warn "DRY-RUN: Would scan recent alert log entries for ORA-/TNS-/error messages."
        return 0
    fi

    alert_file=$(detect_alert_log || true)
    if [ -z "$alert_file" ]; then
        record_warn "Alert log path not configured and could not be detected."
        return 0
    fi

    log "Alert log: $alert_file"
    if [ ! -f "$alert_file" ]; then
        record_warn "Alert log file not found: $alert_file"
        return 0
    fi

    recent_errors=$(tail -300 "$alert_file" | egrep -i 'ORA-|TNS-|error|incident' || true)
    if [ -z "$recent_errors" ]; then
        record_pass "No recent ORA/TNS/error entries found in last 300 alert-log lines."
    else
        record_warn "Recent alert-log warnings/errors found:"
        echo "$recent_errors"
    fi
}

echo "=========================================="
echo "      VALIDATE LOAD TEST READINESS        "
echo "=========================================="
log "Instance     : $INSTANCE_ID"
log "PDB          : $PDB_NAME"
log "App base dir : $APP_BASE_DIR"
log "Mode         : $FLASHBACK_MODE"

check_app_node
check_urls
run_db_checks
check_alert_log

section "READINESS SUMMARY"
log "PASS: $PASS_COUNT"
log "WARN: $WARN_COUNT"
log "FAIL: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    log "SYSTEM IS NOT READY FOR LOAD TEST."
    exit 1
fi

if [ "$WARN_COUNT" -gt 0 ]; then
    log "SYSTEM IS READY WITH WARNINGS. Review warnings before load test."
    exit 0
fi

log "SYSTEM IS READY FOR LOAD TEST."
exit 0
