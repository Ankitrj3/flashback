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
            read -p "Enter Application Base Directory (e.g. /db8000/app/oracle/r122rxest01): " FLASHBACK_APP_BASE_DIR
        fi
        
        echo "Detected OS User      : $FLASHBACK_OS_USER"
        echo "Detected Instance ID  : $FLASHBACK_INSTANCE_ID"
        echo "Detected Base Dir     : $FLASHBACK_APP_BASE_DIR"
        echo "=========================================="
        
        read -p "Enter APPS Username: " FLASHBACK_APPS_USER
        read -s -p "Enter APPS Password: " FLASHBACK_APPS_PASS
        echo ""
        read -s -p "Enter WebLogic Server Password: " FLASHBACK_WLS_PASS
        echo ""
        
        # Save to environment file
        echo "export FLASHBACK_INSTANCE_ID=\"$FLASHBACK_INSTANCE_ID\"" > "$ENV_FILE"
        echo "export FLASHBACK_APP_BASE_DIR=\"$FLASHBACK_APP_BASE_DIR\"" >> "$ENV_FILE"
        echo "export FLASHBACK_OS_USER=\"$FLASHBACK_OS_USER\"" >> "$ENV_FILE"
        echo "export FLASHBACK_APPS_USER=\"$FLASHBACK_APPS_USER\"" >> "$ENV_FILE"
        echo "export FLASHBACK_APPS_PASS=\"$FLASHBACK_APPS_PASS\"" >> "$ENV_FILE"
        echo "export FLASHBACK_WLS_PASS=\"$FLASHBACK_WLS_PASS\"" >> "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        
        echo "Credentials saved to $ENV_FILE"
        echo ""
        read -p "Press [Enter] key to continue..." fackEnterKey
    fi
    # Export for other scripts
    export FLASHBACK_INSTANCE_ID
    export FLASHBACK_APP_BASE_DIR
    export FLASHBACK_OS_USER
    export FLASHBACK_APPS_USER
    export FLASHBACK_APPS_PASS
    export FLASHBACK_WLS_PASS
}

# Function to delete credentials
delete_credentials() {
    clear
    echo "=========================================="
    echo "          DELETE CREDENTIALS              "
    echo "=========================================="
    if [ -f "$ENV_FILE" ]; then
        rm -f "$ENV_FILE"
        echo "Credentials deleted successfully. They will be requested on next run."
    else
        echo "No credentials file found."
    fi
    pause
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
    
    echo "Checking active connections for user '$FLASHBACK_OS_USER'..."
    conn_count=$(ps -ef | grep "$FLASHBACK_OS_USER" | grep -v sh | grep -v sshd | grep -v "ps -ef" | grep -v grep | wc -l | tr -d ' ')
    echo "Found $conn_count active connections."
    
    if [ "$conn_count" -gt 0 ]; then
        echo ""
        read -p "Do you want to stop the application? (yes/no): " stop_app
        if [[ "$stop_app" == "yes" ]]; then
            echo "Stopping application using adstpall.sh..."
            adstpall.sh <<EOF
$FLASHBACK_APPS_USER
$FLASHBACK_APPS_PASS
$FLASHBACK_WLS_PASS
EOF
            if [ $? -ne 0 ]; then
                echo "Warning: adstpall.sh returned a non-zero exit status."
            fi
        fi
    fi
    
    echo ""
    echo "Application File Systems to be backed up:"
    echo "  RUN File System           : $FLASHBACK_APP_BASE_DIR/fs2/EBSapps/appl"
    echo "  PATCH File System         : $FLASHBACK_APP_BASE_DIR/fs1/EBSapps/appl"
    echo "  Non-Editioned File System : $FLASHBACK_APP_BASE_DIR/fs_ne"
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
    echo "========================================================================================="
    sh "$(dirname "$0")/oracle/list_restore_points.sh"
    echo "========================================================================================="
    
    echo ""
    # Second confirmation
    echo "CRITICAL WARNING: This action cannot be undone."
    read -p "Please type 'RESTORE' to confirm again: " confirm2
    if [[ "$confirm2" != "RESTORE" ]]; then
        echo "Restore cancelled. Confirmation did not match."
        pause
        return
    fi
    
    echo ""
    read -p "Enter restore point name: " rp_name
    if [ -z "$rp_name" ]; then
        echo "Restore point name cannot be empty. Cancelled."
        pause
        return
    fi

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
    echo "5. Delete stored credentials"
    echo "=========================================="
    read -p "Enter your choice [1-5]: " choice

    case $choice in
        1) make_backup ;;
        2) restore_flashback ;;
        3) view_flashback ;;
        4) 
            echo "Exiting..."
            exit 0 
            ;;
        5) delete_credentials ;;
        *) 
            echo "Invalid option. Please choose between 1 and 5."
            pause
            ;;
    esac
done
