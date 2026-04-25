#!/bin/bash

# Function to pause and wait for user input before returning to the menu
pause() {
    echo ""
    read -p "Press [Enter] key to continue..." fackEnterKey
}

# Function to execute 'Make flashback or backup'
make_backup() {
    clear
    echo "=========================================="
    echo "       MAKE FLASHBACK OR BACKUP           "
    echo "=========================================="
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
while true
do
    clear
    echo "=========================================="
    echo "       ORACLE DB FLASHBACK MANAGER        "
    echo "=========================================="
    echo "1. Make flashback or backup"
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
