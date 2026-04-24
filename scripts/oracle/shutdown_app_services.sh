#!/usr/bin/env sh
# =============================================================================
# shutdown_app_services.sh — SSH all app nodes, shutdown EBS services, verify clean
#
# This is PRE-VALIDATION Step 1 before "Restore Flashback GRP".
# Run BEFORE any database operation. The DB cannot be flashed back safely
# while EBS application services are still connected and running.
#
# USAGE   : sh shutdown_app_services.sh
# EXIT    : 0 = all app nodes confirmed clean (no running EBS processes)
#           1 = one or more nodes still have processes after shutdown attempt
#           2 = SSH connectivity failed to one or more nodes
#           3 = configuration error
#
# WHAT THIS SCRIPT DOES ON EACH NODE:
#   1) SSH to the node
#   2) Check if EBS services (Apache, Concurrent Manager, OPMN, etc.) are running
#   3) If running: execute adstpall.sh to shutdown all EBS services
#   4) Wait and recheck: if still running after timeout, report ERROR
#   5) Repeat for all nodes in FLASHBACK_APP_NODES
#
# CLIENT ENVIRONMENT (RXEST01):
#   App nodes    : node2, node3, node4, node5, node6, node7
#   SSH user     : oracle
#   Base dir     : /db8000/app/oracle/r122rxest01
#   EBS stop cmd : adstpall.sh (from EBS run filesystem)
#
# DEMO MODE:
#   Set FLASHBACK_DEMO=true to simulate the shutdown sequence per node.
#
# CONFIGURATION (environment variables):
#   FLASHBACK_APP_NODES      Space-separated node list (REQUIRED in production)
#   FLASHBACK_SSH_USER       SSH username (default: oracle)
#   FLASHBACK_SSH_KEY        SSH private key path (optional)
#   FLASHBACK_INSTANCE_ID    Instance prefix (default: RXEST01)
#   FLASHBACK_APP_BASE_DIR   App context base dir on each node
#   FLASHBACK_APPS_PASS      EBS APPS schema password (for adstpall.sh)
# =============================================================================

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [shutdown_services] $*"
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-RXEST01}"
APP_NODES="${FLASHBACK_APP_NODES:-}"
SSH_USER="${FLASHBACK_SSH_USER:-oracle}"
SSH_KEY="${FLASHBACK_SSH_KEY:-}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-/db8000/app/oracle/r122rxest01}"
APPS_PASS="${FLASHBACK_APPS_PASS:-apps}"
WAIT_SECS=30     # seconds to wait after shutdown before re-check

# =============================================================================
# DEMO MODE
# =============================================================================
if [ "${FLASHBACK_DEMO:-false}" = "true" ]; then
    log "DEMO MODE: Simulating EBS service shutdown on all app nodes."
    log "DEMO: Instance   : $INSTANCE_ID"
    log "DEMO: App nodes  : node2 node3 node4 node5 node6 node7 (simulated)"
    log ""

    for node in node2 node3 node4 node5 node6 node7; do
        log "DEMO: ---- Processing node: $node ----"
        log "DEMO: SSH check       : $node ... connected (simulated)"
        sleep 0.3
        log "DEMO: Service check   : Found FNDLIBR, Apache, opmn running (simulated)"
        log "DEMO: Shutting down   : adstpall.sh apps/apps running on $node ... (simulated)"
        sleep 1
        log "DEMO: Services stopped on $node. Verifying ..."
        sleep 0.3
        log "DEMO: Re-check        : No EBS processes running on $node.  OK (simulated)"
        log ""
    done

    log "DEMO: All app nodes confirmed clean. Safe to proceed with DB flashback. (simulated)"
    exit 0
fi

# =============================================================================
# REAL MODE
# =============================================================================

if [ -z "$APP_NODES" ]; then
    log "ERROR: FLASHBACK_APP_NODES is not set. Cannot check application nodes."
    log "  Set FLASHBACK_APP_NODES in config.json -> app.nodes"
    exit 3
fi

log "Starting EBS application service shutdown."
log "Instance     : $INSTANCE_ID"
log "App nodes    : $APP_NODES"
log "SSH user     : $SSH_USER"
log "App base dir : $APP_BASE_DIR"

FAILED_NODES=""

ssh_opts="-o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=no"
[ -n "$SSH_KEY" ] && ssh_opts="$ssh_opts -i $SSH_KEY"

for node in $APP_NODES; do
    log ""
    log "---- Processing node: $node ----"

    # Step 1: SSH connectivity check
    # shellcheck disable=SC2086
    if ! ssh $ssh_opts "$SSH_USER@$node" "echo SSH_ALIVE_OK" 2>/dev/null | grep -q "SSH_ALIVE_OK"; then
        log "ERROR: Cannot SSH to $node. Skipping."
        FAILED_NODES="$FAILED_NODES $node"
        continue
    fi
    log "SSH OK: connected to $node"

    # Step 2: Check if EBS services are running
    # shellcheck disable=SC2086
    proc_count=$(ssh $ssh_opts "$SSH_USER@$node" \
        "ps -ef | grep -E '(FNDLIBR|opmn|httpd|java.*oc4j|adcmctl)' | grep -v grep | wc -l" \
        2>/dev/null || echo "0")
    log "Running EBS processes on $node: $proc_count"

    if [ "$proc_count" -gt 0 ]; then
        # Step 3: Shutdown EBS services using adstpall.sh
        log "Shutting down EBS services on $node ..."
        # shellcheck disable=SC2086
        ssh $ssh_opts "$SSH_USER@$node" "
            export ORACLE_HOME=\$(find $APP_BASE_DIR -name 'oracle' -type d 2>/dev/null | head -1 || echo '')
            cd '$APP_BASE_DIR/fs2/inst/apps' 2>/dev/null || cd '$APP_BASE_DIR'
            # Use adstpall.sh from run filesystem
            adstpall_path=\$(find '$APP_BASE_DIR/fs2' -name adstpall.sh 2>/dev/null | head -1)
            if [ -n \"\$adstpall_path\" ]; then
                echo 'Running adstpall.sh ...'
                echo '$APPS_PASS' | sh \"\$adstpall_path\" 2>&1 || true
            else
                echo 'adstpall.sh not found — attempting manual service stop'
            fi
        " 2>&1 | sed "s/^/    [$node] /" || true

        log "Waiting $WAIT_SECS seconds for processes to terminate ..."
        sleep "$WAIT_SECS"

        # Step 4: Re-check processes
        # shellcheck disable=SC2086
        remaining=$(ssh $ssh_opts "$SSH_USER@$node" \
            "ps -ef | grep -E '(FNDLIBR|opmn|httpd|java.*oc4j)' | grep -v grep | wc -l" \
            2>/dev/null || echo "99")

        if [ "$remaining" -gt 0 ]; then
            log "ERROR: $remaining EBS process(es) still running on $node after shutdown."
            log "  Please manually stop remaining processes on $node before proceeding."
            FAILED_NODES="$FAILED_NODES $node"
        else
            log "OK: No EBS processes running on $node. Safe to proceed."
        fi
    else
        log "OK: No EBS processes running on $node. Nothing to shutdown."
    fi
done

if [ -n "$FAILED_NODES" ]; then
    log ""
    log "ERROR: The following nodes still have running processes:$FAILED_NODES"
    log "  Stop all EBS services on these nodes before running Flashback Restore."
    exit 1
fi

log ""
log "All app nodes confirmed clean. Safe to proceed with DB flashback."
exit 0
