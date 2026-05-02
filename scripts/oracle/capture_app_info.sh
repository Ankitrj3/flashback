#!/usr/bin/env sh
# =============================================================================
# capture_app_info.sh — Detect file systems, check services, stop if needed
#
# USAGE   : sh capture_app_info.sh [--export]
#           eval $(sh capture_app_info.sh --export)
#
# EXIT    : 0 = app info captured successfully
#           1 = check/stop failed
#           3 = operator cancelled
#
# PURPOSE:
#   Connects to the application server (or local), auto-detects the EBS file 
#   systems (RUN, PATCH, fs_ne), checks the number of active EBS processes,
#   prompts to stop services using adstpall.sh if running, and generates 
#   nohup tar backup commands with date stamps.
#
# DEMO MODE:
#   Set FLASHBACK_DEMO=true to simulate the operations.
# =============================================================================

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [capture_app_info] $*" >&2
}

INSTANCE_ID="${FLASHBACK_INSTANCE_ID:-}"
APP_BASE_DIR="${FLASHBACK_APP_BASE_DIR:-}"
APPS_USER="${FLASHBACK_APPS_USER:-apps}"
APPS_PASS="${FLASHBACK_APPS_PASS:-}"
WLS_PASS="${FLASHBACK_WLS_PASS:-}"
OS_USER="${FLASHBACK_OS_USER:-$(whoami)}"

EXPORT_MODE="false"
if [ "${1:-}" = "--export" ]; then
    EXPORT_MODE="true"
fi

DATE_TAG=$(date '+%d%b%y' | tr '[:upper:]' '[:lower:]')   # e.g. 09dec25
BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/tmp}"

# =============================================================================
# DEMO MODE
# =============================================================================
if [ "${FLASHBACK_DEMO:-false}" = "true" ]; then
    log "DEMO MODE: Simulating App Info Capture."
    
    RUN_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
    PATCH_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
    NE_FS="$APP_BASE_DIR/fs_ne"
    
    log ""
    log "Application File Systems Detected:"
    log "  RUN File System           : $RUN_FS"
    log "  PATCH File System         : $PATCH_FS"
    log "  Non-Editioned File System : $NE_FS"
    log ""
    
    log "Checking active connections for user '$OS_USER'..."
    sleep 1
    # Simulate finding 274 connections as per user prompt
    CONN_COUNT=274
    log "Found $CONN_COUNT active connections."
    log ""
    
    if [ "$CONN_COUNT" -gt 0 ]; then
        printf "  Do you want to stop the application? (yes/no): " >&2
        read -r stop_app
        
        if [ "$stop_app" = "yes" ]; then
            log "Shutting down EBS services using adstpall.sh (simulated)..."
            log ""
            log "You are running adstpall.sh version 120.22.12020000.7"
            log ""
            log "Enter the APPS username: apps"
            log "Enter the APPS password: "
            log "Enter the WebLogic Server password: "
            sleep 2
            log "Services stopped successfully. (simulated)"
            APP_SERVICES_STOPPED="true"
        else
            log "Skipping application shutdown."
            APP_SERVICES_STOPPED="false"
        fi
    else
        APP_SERVICES_STOPPED="true"
    fi
    
    log ""
    log "Generated Backup Commands:"
    CMD_NE="nohup tar -cvf $BACKUP_DIR/${INSTANCE_ID}_fs_ne_backup_$DATE_TAG.tar fs_ne &"
    CMD_FS1="nohup tar -cvf $BACKUP_DIR/${INSTANCE_ID}_fs1_Patch_backup_$DATE_TAG.tar fs1 &"
    CMD_FS2="nohup tar -cvf $BACKUP_DIR/${INSTANCE_ID}_fs2_Run_backup_$DATE_TAG.tar fs2 &"
    
    log "  $CMD_NE"
    log "  $CMD_FS1"
    log "  $CMD_FS2"
    log ""
    
    if [ "$EXPORT_MODE" = "true" ]; then
        echo "APP_RUN_FS=\"$RUN_FS\""
        echo "APP_PATCH_FS=\"$PATCH_FS\""
        echo "APP_NE_FS=\"$NE_FS\""
        echo "APP_PROCESS_COUNT=\"$CONN_COUNT\""
        echo "APP_SERVICES_STOPPED=\"$APP_SERVICES_STOPPED\""
        echo "BACKUP_CMD_NE=\"$CMD_NE\""
        echo "BACKUP_CMD_FS1=\"$CMD_FS1\""
        echo "BACKUP_CMD_FS2=\"$CMD_FS2\""
    fi
    exit 0
fi

# =============================================================================
# REAL MODE
# =============================================================================

# In real mode, we typically execute locally if running on the app node, or via SSH if remote.
# For simplicity, assuming local execution on app node or single-node EBS if no SSH variables provided.
APP_NODES="${FLASHBACK_APP_NODES:-}"

if [ -z "$APP_NODES" ]; then
    # Initialize variables as empty to enforce dynamic detection
    RUN_FS=""
    PATCH_FS=""
    NE_FS=""
    
    # Dynamically query run/patch locations via SSH if we have the connection details
    if [ -n "${FLASHBACK_APP_HOST:-}" ] && [ -n "${FLASHBACK_APP_USER:-}" ] && [ -n "${FLASHBACK_APP_ENV_FILE:-}" ]; then
        log "Querying dynamic file system locations from $FLASHBACK_APP_HOST..."
        remote_vars=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$FLASHBACK_APP_USER@$FLASHBACK_APP_HOST" "source ~/$FLASHBACK_APP_ENV_FILE >/dev/null 2>&1 && echo \"\$RUN_BASE|\$FILE_EDITION|\$NE_BASE\"" 2>/dev/null || echo "")
        if [ -n "$remote_vars" ]; then
            dyn_run=$(echo "$remote_vars" | cut -d'|' -f1)
            dyn_patch=$(echo "$remote_vars" | cut -d'|' -f2)
            dyn_ne=$(echo "$remote_vars" | cut -d'|' -f3)
            
            if [ -n "$dyn_run" ]; then RUN_FS="${dyn_run}/EBSapps/appl"; fi
            if [ -n "$dyn_patch" ]; then PATCH_FS="${dyn_patch}/EBSapps/appl"; fi
            if [ -n "$dyn_ne" ]; then NE_FS="${dyn_ne}"; fi
        fi
    else
        # Local fallback if we run directly on the app server with variables already sourced
        if [ -n "${FILE_EDITION:-}" ] && [ -n "${RUN_BASE:-}" ]; then
             RUN_FS="${RUN_BASE}/EBSapps/appl"
             PATCH_FS="${FILE_EDITION}/EBSapps/appl"
        fi
    fi
    
    log ""
    log "Application File Systems Detected:"
    log "  RUN File System           : $RUN_FS"
    log "  PATCH File System         : $PATCH_FS"
    log "  Non-Editioned File System : $NE_FS"
    log ""
    
    log "Checking active connections for user '$OS_USER'..."
    CONN_COUNT=$(ps -ef | grep "$OS_USER" | grep -v sh | grep -v sshd | grep -v "ps -ef" | grep -v grep | wc -l | tr -d ' ')
    log "Found $CONN_COUNT active connections."
    
    APP_SERVICES_STOPPED="true"
    
    if [ "$CONN_COUNT" -gt 0 ]; then
        printf "  Do you want to stop the application? (yes/no): " >&2
        read -r stop_app
        
        if [ "$stop_app" = "yes" ]; then
            log "Stopping application using adstpall.sh..."
            # Check if adstpall.sh exists in PATH or find it
            ADSTPALL_PATH=$(command -v adstpall.sh || find "$APP_BASE_DIR" -name adstpall.sh 2>/dev/null | head -1)
            
            if [ -n "$ADSTPALL_PATH" ]; then
                log "Found adstpall.sh at $ADSTPALL_PATH"
                
                # Execute adstpall.sh interactively so user can enter passwords if needed
                sh "$ADSTPALL_PATH" >&2
                if [ $? -eq 0 ]; then
                    log "Application services stopped."
                else
                    log "WARNING: adstpall.sh returned non-zero status. Please check."
                    APP_SERVICES_STOPPED="false"
                fi
            else
                log "ERROR: adstpall.sh not found. Cannot stop services automatically."
                APP_SERVICES_STOPPED="false"
            fi
        else
            log "Skipping application shutdown."
            APP_SERVICES_STOPPED="false"
        fi
    fi
else
    log "App node list provided ($APP_NODES). File system detection on remote node not fully implemented in this script yet."
    log "Relying on base directory: $APP_BASE_DIR"
    RUN_FS="$APP_BASE_DIR/fs2/EBSapps/appl"
    PATCH_FS="$APP_BASE_DIR/fs1/EBSapps/appl"
    NE_FS="$APP_BASE_DIR/fs_ne"
    CONN_COUNT=0
    APP_SERVICES_STOPPED="true" # Assuming shutdown script handles remote nodes
fi

log ""
log "Generated Backup Commands:"
CMD_NE="nohup tar -cvf $BACKUP_DIR/${INSTANCE_ID}_fs_ne_backup_$DATE_TAG.tar fs_ne &"
CMD_FS1="nohup tar -cvf $BACKUP_DIR/${INSTANCE_ID}_fs1_Patch_backup_$DATE_TAG.tar fs1 &"
CMD_FS2="nohup tar -cvf $BACKUP_DIR/${INSTANCE_ID}_fs2_Run_backup_$DATE_TAG.tar fs2 &"

log "  $CMD_NE"
log "  $CMD_FS1"
log "  $CMD_FS2"
log ""

if [ "$EXPORT_MODE" = "true" ]; then
    echo "APP_RUN_FS=\"$RUN_FS\""
    echo "APP_PATCH_FS=\"$PATCH_FS\""
    echo "APP_NE_FS=\"$NE_FS\""
    echo "APP_PROCESS_COUNT=\"$CONN_COUNT\""
    echo "APP_SERVICES_STOPPED=\"$APP_SERVICES_STOPPED\""
    echo "BACKUP_CMD_NE=\"$CMD_NE\""
    echo "BACKUP_CMD_FS1=\"$CMD_FS1\""
    echo "BACKUP_CMD_FS2=\"$CMD_FS2\""
else
    log "App info capture complete. Use: eval \$(sh capture_app_info.sh --export)"
fi

exit 0
