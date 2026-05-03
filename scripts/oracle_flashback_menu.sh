#!/bin/bash

ENV_FILE="$HOME/.flashback_env"

# Function to load or prompt for credentials
load_or_prompt_credentials() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    else
        clear
        echo "=========================================="
        echo "       INITIAL SETUP: CONFIGURATION       "
        echo "=========================================="
        
        read -p "Enter Application Hostname (e.g. orxpcadv05ebs): " FLASHBACK_APP_HOST
        read -p "Enter Application OS User (e.g. aporxdev): " FLASHBACK_APP_USER
        
        echo ""
        echo "Testing SSH connectivity to $FLASHBACK_APP_USER@$FLASHBACK_APP_HOST..."
        
            if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$FLASHBACK_APP_USER@$FLASHBACK_APP_HOST" "echo 'SSH connection successful.'"; then
                echo "Warning: SSH connectivity failed. Please ensure key-based authentication is set up."
                echo ""
                # Fallback if SSH fails
                read -p "Enter Database Instance Name (e.g. RXEST01): " FLASHBACK_INSTANCE_ID
                read -p "Enter Application Base Directory (e.g. /db6000/app/oracle/r122rxedv05): " FLASHBACK_APP_BASE_DIR
            else
                echo ""
                echo "Fetching environment files from $FLASHBACK_APP_HOST..."
                echo "--------------------------------------------------------"
                ssh "$FLASHBACK_APP_USER@$FLASHBACK_APP_HOST" "cd ~ && ls -lrt *.env 2>/dev/null"
                echo "--------------------------------------------------------"
                echo ""
                read -p "Enter the environment file to source (e.g. EBSapps.env): " FLASHBACK_APP_ENV_FILE
                
                # Auto-detect base dir and instance ID from the env file
                if [ -n "$FLASHBACK_APP_ENV_FILE" ]; then
                    base_dir=$(ssh "$FLASHBACK_APP_USER@$FLASHBACK_APP_HOST" "readlink -f ~/$FLASHBACK_APP_ENV_FILE | xargs dirname")
                    if [ -n "$base_dir" ]; then
                        echo "Auto-detected Application Base Directory: $base_dir"
                        FLASHBACK_APP_BASE_DIR="$base_dir"
                    fi
                    
                    instance_id=$(ssh "$FLASHBACK_APP_USER@$FLASHBACK_APP_HOST" "source ~/$FLASHBACK_APP_ENV_FILE >/dev/null 2>&1 && echo \$TWO_TASK")
                    if [ -n "$instance_id" ]; then
                        echo "Auto-detected Database Instance Name: $instance_id"
                        FLASHBACK_INSTANCE_ID="$instance_id"
                    fi
                fi
                
                if [ -z "$FLASHBACK_APP_BASE_DIR" ]; then
                    read -p "Enter Application Base Directory (e.g. /db6000/app/oracle/r122rxedv05): " FLASHBACK_APP_BASE_DIR
                fi
                if [ -z "$FLASHBACK_INSTANCE_ID" ]; then
                    read -p "Enter Database Instance Name (e.g. RXEDV05): " FLASHBACK_INSTANCE_ID
                fi
            fi
        # Save to environment file
        echo "export FLASHBACK_INSTANCE_ID=\"$FLASHBACK_INSTANCE_ID\"" > "$ENV_FILE"
        echo "export FLASHBACK_APP_HOST=\"$FLASHBACK_APP_HOST\"" >> "$ENV_FILE"
        echo "export FLASHBACK_APP_USER=\"$FLASHBACK_APP_USER\"" >> "$ENV_FILE"
        echo "export FLASHBACK_APP_ENV_FILE=\"$FLASHBACK_APP_ENV_FILE\"" >> "$ENV_FILE"
        echo "export FLASHBACK_APP_BASE_DIR=\"$FLASHBACK_APP_BASE_DIR\"" >> "$ENV_FILE"
        echo "export FLASHBACK_APP_NODES=\"$FLASHBACK_APP_HOST\"" >> "$ENV_FILE"
        echo "export FLASHBACK_SSH_USER=\"$FLASHBACK_APP_USER\"" >> "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        
        echo ""
        echo "=========================================="
        echo "Detected Instance ID  : $FLASHBACK_INSTANCE_ID"
        echo "Detected Hostname     : $FLASHBACK_APP_HOST"
        echo "Detected OS User      : $FLASHBACK_APP_USER"
        echo "Detected Env File     : $FLASHBACK_APP_ENV_FILE"
        echo "Detected Base Dir     : $FLASHBACK_APP_BASE_DIR"
        echo "=========================================="
        echo "Settings saved to $ENV_FILE"
        echo ""
        read -p "Press [Enter] key to continue..." fackEnterKey
    fi
    # Export for other scripts
    export FLASHBACK_INSTANCE_ID
    export FLASHBACK_APP_HOST
    export FLASHBACK_APP_USER
    export FLASHBACK_APP_ENV_FILE
    export FLASHBACK_APP_BASE_DIR
    export FLASHBACK_APP_NODES="$FLASHBACK_APP_HOST"
    export FLASHBACK_SSH_USER="$FLASHBACK_APP_USER"
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
    
    capture_out=$(sh "$(dirname "$0")/oracle/capture_app_info.sh" --export)
    ret=$?
    if [ $ret -ne 0 ]; then
        pause
        return
    fi
    eval "$capture_out"
    
    echo ""
    echo "Running backup command..."
    export FLASHBACK_APP_RUN_FS="$APP_RUN_FS"
    export FLASHBACK_APP_PATCH_FS="$APP_PATCH_FS"
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
