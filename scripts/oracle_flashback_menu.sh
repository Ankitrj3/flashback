#!/bin/bash

ENV_FILE="$HOME/.flashback_env"

# Function to load or prompt for credentials
load_or_prompt_credentials() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    else
        clear
        echo "=========================================="
        echo "       INITIAL SETUP: AUTO-DETECT         "
        echo "=========================================="
        
        # Auto-detect OS User
        FLASHBACK_OS_USER=$(whoami)
        
        # Auto-detect Instance ID
        FLASHBACK_INSTANCE_ID=""
        if [ -n "$CONTEXT_NAME" ]; then
            FLASHBACK_INSTANCE_ID=$(echo "$CONTEXT_NAME" | cut -d'_' -f1)
        elif [ -n "$TWO_TASK" ]; then
            FLASHBACK_INSTANCE_ID="$TWO_TASK"
        elif [ -n "$ORACLE_SID" ]; then
            FLASHBACK_INSTANCE_ID="$ORACLE_SID"
        else
            # Try to get from running Oracle pmon processes (if on DB server)
            pmon_inst=$(ps -ef | grep "[o]ra_pmon_" | awk '{print $NF}' | sed 's/ora_pmon_//' | head -1)
            if [ -n "$pmon_inst" ]; then
                FLASHBACK_INSTANCE_ID="$pmon_inst"
            else
                # Try to get from sqlplus
                if command -v sqlplus >/dev/null 2>&1; then
                    sql_inst=$(sh "$(dirname "$0")/oracle/get_instance_name.sh" instance 2>/dev/null)
                    if [ -n "$sql_inst" ]; then
                        FLASHBACK_INSTANCE_ID="$sql_inst"
                    fi
                fi
            fi
        fi
        
        # Fallback if auto-detect fails
        if [ -z "$FLASHBACK_INSTANCE_ID" ]; then
            read -p "Enter Database Instance Name (e.g. RXEST01): " FLASHBACK_INSTANCE_ID
        fi
        
        # Auto-detect App Base Directory
        FLASHBACK_APP_BASE_DIR=""
        if [ -n "$FILE_EDITION" ]; then
            FLASHBACK_APP_BASE_DIR=$(dirname "$FILE_EDITION")
        elif [ -n "$RUN_BASE" ]; then
            FLASHBACK_APP_BASE_DIR=$(dirname "$RUN_BASE")
        elif [ -n "$APPL_TOP" ]; then
            FLASHBACK_APP_BASE_DIR=$(dirname $(dirname $(dirname "$APPL_TOP")))
        else
            # Try to infer from running EBS processes (e.g. FNDLIBR)
            fnd_path=$(ps -ef | grep "[F]NDLIBR" | awk '{print $8}' | head -1)
            if [ -n "$fnd_path" ]; then
                # e.g., /db8000/app/oracle/r122rxest01/fs2/EBSapps/appl/fnd/12.0.0/bin/FNDLIBR
                FLASHBACK_APP_BASE_DIR=$(echo "$fnd_path" | sed -E 's|/fs[12]/.*||')
            else
                # Try to infer from active concurrent managers or OPMN
                opmn_path=$(ps -ef | grep "[o]pmn" | awk '{print $8}' | grep "EBSapps" | head -1)
                if [ -n "$opmn_path" ]; then
                    FLASHBACK_APP_BASE_DIR=$(echo "$opmn_path" | sed -E 's|/fs[12]/.*||')
                fi
            fi
        fi
        
        # Fallback if auto-detect fails
        if [ -z "$FLASHBACK_APP_BASE_DIR" ]; then
            read -p "Enter Application Base Directory (e.g. /db8000/app/oracle/r122rxest01): " FLASHBACK_APP_BASE_DIR
        fi
        
        echo "Detected OS User      : $FLASHBACK_OS_USER"
        echo "Detected Instance ID  : $FLASHBACK_INSTANCE_ID"
        echo "Detected Base Dir     : $FLASHBACK_APP_BASE_DIR"
        echo "=========================================="
        
        # Save to environment file
        echo "export FLASHBACK_INSTANCE_ID=\"$FLASHBACK_INSTANCE_ID\"" > "$ENV_FILE"
        echo "export FLASHBACK_APP_BASE_DIR=\"$FLASHBACK_APP_BASE_DIR\"" >> "$ENV_FILE"
        echo "export FLASHBACK_OS_USER=\"$FLASHBACK_OS_USER\"" >> "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        
        echo "Settings saved to $ENV_FILE"
        echo ""
        read -p "Press [Enter] key to continue..." fackEnterKey
    fi
    # Export for other scripts
    export FLASHBACK_INSTANCE_ID
    export FLASHBACK_APP_BASE_DIR
    export FLASHBACK_OS_USER
}

# Function to pause and wait for user input before returning to the menu
pause() {
    echo ""
    read -p "Press [Enter] key to continue..." fackEnterKey
}

# Function to execute 'Make flashback request'
make_backup() {
    clear
    echo "=========================================="
    echo "         MAKE FLASHBACK REQUEST           "
    echo "=========================================="
    
    capture_out=$(sh "$(dirname "$0")/oracle/capture_app_info.sh" --export)
    ret=$?
    if [ $ret -ne 0 ]; then
        pause
        return
    fi
    eval "$capture_out"
    
    echo ""
    echo "Running backup command..."
    if ! sh "$(dirname "$0")/oracle/create_backup.sh"; then
        echo "Error: Backup command failed."
        pause
        return
    fi
    
    echo "Running create flashback restore point command..."
    if ! sh "$(dirname "$0")/oracle/create_flashback_restore_point.sh"; then
        echo "Error: Create flashback restore point command failed."
        pause
        return
    fi
    
    echo "Backup and flashback restore point created successfully."
    pause
}

# Function to execute 'Restore flashback' with double confirmation
restore_flashback() {
    clear
    echo "=========================================="
    echo "           RESTORE FLASHBACK              "
    echo "=========================================="
    echo "WARNING: Restoring a flashback may revert recent data changes!"
    echo ""
    
    # First confirmation
    read -p "Are you sure you want to proceed with restore? (yes/no): " confirm1
    if [[ "$confirm1" != "yes" ]]; then
        echo "Restore cancelled by user."
        pause
        return
    fi
    
    echo ""
    echo "Fetching available restore points..."
    
    capture_out=$(sh "$(dirname "$0")/oracle/capture_db_info.sh" --export)
    ret=$?
    if [ $ret -ne 0 ]; then
        pause
        return
    fi
    eval "$capture_out"
    
    rp_name="$SELECTED_RESTORE_POINT"
    if [ -z "$rp_name" ]; then
        echo "Restore point selection failed."
        pause
        return
    fi
    
    echo ""
    # Second confirmation
    echo "CRITICAL WARNING: This action cannot be undone."
    read -p "Please type 'RESTORE' to confirm restoring to '$rp_name': " confirm2
    if [[ "$confirm2" != "RESTORE" ]]; then
        echo "Restore cancelled. Confirmation did not match."
        pause
        return
    fi

    echo ""
    echo "Capturing application information and stopping services before restore..."
    app_capture_out=$(sh "$(dirname "$0")/oracle/capture_app_info.sh" --export)
    app_ret=$?
    if [ $app_ret -ne 0 ]; then
        pause
        return
    fi
    eval "$app_capture_out"

    echo "Running restore backup command..."
    if ! sh "$(dirname "$0")/oracle/restore_backup.sh" "$rp_name"; then
        echo "Error: Restore backup command failed."
        pause
        return
    fi
    
    echo "Running flashback to restore point command..."
    if ! sh "$(dirname "$0")/oracle/flashback_to_restore_point.sh" "$rp_name"; then
        echo "Error: Flashback to restore point command failed."
        pause
        return
    fi
    
    echo "Restore completed successfully."
    pause
}

# Function to execute 'View Flashback'
view_flashback() {
    clear
    echo "=========================================="
    echo "             VIEW FLASHBACK               "
    echo "=========================================="
    echo "Listing restore points..."
    sh "$(dirname "$0")/oracle/list_restore_points.sh"
    
    pause
}

# Main menu loop
# Ensure credentials are loaded before starting the menu loop
load_or_prompt_credentials

while true
do
    clear
    echo "=========================================="
    echo "       ORACLE DB FLASHBACK MANAGER        "
    echo "=========================================="
    echo "1. Make flashback request"
    echo "2. Restore flashback"
    echo "3. View Flashback"
    echo "4. Exit"
    echo "=========================================="
    read -p "Enter your choice [1-4]: " choice

    case $choice in
        1) make_backup ;;
        2) restore_flashback ;;
        3) view_flashback ;;
        4) 
            echo "Exiting..."
            exit 0 
            ;;
        *) 
            echo "Invalid option. Please choose between 1 and 4."
            pause
            ;;
    esac
done
