#!/usr/bin/env sh
# =============================================================================
# get_instance_name.sh — Dynamically fetch Oracle instance name and CDB/PDB info
#
# USAGE   : sh get_instance_name.sh
# OUTPUT  : JSON format with instance details
#
# Examples:
#   source ./get_instance_name.sh
#   INSTANCE_NAME=$(get_instance_name)
#   echo "Instance: $INSTANCE_NAME"
#
# Fetches:
#   - INSTANCE_NAME       : Current Oracle instance name
#   - DB_NAME             : Database name (CDB root)
#   - CDB_NAME            : Container database name
#   - PDB_NAME            : Pluggable database name (if connected to PDB)
#   - OPEN_MODE           : Database open mode
#   - LOG_MODE            : Archive log mode status
#   - FLASHBACK_STATUS    : Flashback database status
# =============================================================================

set -eu

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [get_instance_name] $*"
}

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================================
# Function: get_instance_name
# Queries Oracle instance name dynamically
# =============================================================================
get_instance_name() {
    sqlplus -S / as sysdba <<EOF 2>/dev/null | grep -v "^$" | tail -1
        set heading off feedback off pagesize 0 linesize 32767
        select instance_name from v\$instance;
        exit;
EOF
}

# =============================================================================
# Function: get_db_name
# Queries database name dynamically
# =============================================================================
get_db_name() {
    sqlplus -S / as sysdba <<EOF 2>/dev/null | grep -v "^$" | tail -1
        set heading off feedback off pagesize 0 linesize 32767
        select name from v\$database;
        exit;
EOF
}

# =============================================================================
# Function: get_cdb_name
# Queries CDB name (for multitenant environments)
# =============================================================================
get_cdb_name() {
    sqlplus -S / as sysdba <<EOF 2>/dev/null | grep -v "^$" | tail -1
        set heading off feedback off pagesize 0 linesize 32767
        select db_name from v\$database;
        exit;
EOF
}

# =============================================================================
# Function: get_pdb_name
# Queries current PDB name (if in multitenant environment)
# =============================================================================
get_pdb_name() {
    sqlplus -S / as sysdba <<EOF 2>/dev/null | grep -v "^$" | tail -1
        set heading off feedback off pagesize 0 linesize 32767
        select name from v\$pdbs where open_cursors > 0 fetch first 1 rows only;
        exit;
EOF
}

# =============================================================================
# Function: get_database_status
# Queries complete database status including flashback info
# =============================================================================
get_database_status() {
    sqlplus -S / as sysdba <<EOF 2>/dev/null
        set heading on feedback off pagesize 0 linesize 100
        column INSTANCE_NAME format a20
        column DB_NAME format a20
        column OPEN_MODE format a15
        column LOG_MODE format a15
        column FLASHBACK_ON format a15
        
        select 
            i.instance_name,
            d.name as db_name,
            d.open_mode,
            d.log_mode,
            d.flashback_on
        from v\$instance i, v\$database d;
        exit;
EOF
}

# =============================================================================
# Function: get_restore_points
# Lists all available restore points
# =============================================================================
get_restore_points() {
    sqlplus -S / as sysdba <<EOF 2>/dev/null
        set heading on feedback off pagesize 100 linesize 150
        column NAME format a50
        column TIME format a30
        column GUARANTEE_FLASHBACK_DATABASE format a5
        column STORAGE_SIZE format 9.9EEEE
        
        select 
            name,
            time,
            guarantee_flashback_database,
            storage_size,
            pdb_restore_point,
            con_id
        from v\$restore_point 
        order by time desc;
        exit;
EOF
}

# =============================================================================
# Function: create_flashback_point_dynamic
# Creates a restore point using dynamic instance name
# =============================================================================
create_flashback_point_dynamic() {
    local instance_name=$(get_instance_name)
    local date_tag=$(date '+%d%b%y' | tr '[:lower:]' '[:upper:]')
    local restore_point_name="${instance_name}_flashback_restore_${date_tag}"
    
    log "Creating restore point for instance: $instance_name"
    log "Restore point name: $restore_point_name"
    
    sqlplus / as sysdba <<EOF
        CREATE RESTORE POINT "$restore_point_name" GUARANTEE FLASHBACK DATABASE;
        exit;
EOF
    
    log "Restore point '$restore_point_name' created successfully."
}

# =============================================================================
# Function: flashback_to_dynamic_point
# Flashbacks database to a dynamically named restore point
# =============================================================================
flashback_to_dynamic_point() {
    local restore_point_name="${1:-}"
    
    if [ -z "$restore_point_name" ]; then
        log "ERROR: Restore point name required"
        return 1
    fi
    
    local instance_name=$(get_instance_name)
    
    log "=========================================="
    log "FLASHBACK DATABASE - Dynamic Instance"
    log "=========================================="
    log "Instance: $instance_name"
    log "Restore Point: $restore_point_name"
    log ""
    
    sqlplus / as sysdba <<EOF
        -- Step 1: Verify restore point exists
        SELECT name, time, guarantee_flashback_database 
        FROM v\$restore_point 
        WHERE name = '$restore_point_name';
        
        -- Step 2: Close PDBs if multitenant
        ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE;
        
        -- Step 3: Flashback database
        FLASHBACK DATABASE TO RESTORE POINT "$restore_point_name";
        ALTER DATABASE OPEN RESETLOGS;
        
        -- Step 4: Open PDBs
        ALTER PLUGGABLE DATABASE ALL OPEN;
        
        -- Verify success
        SELECT name, open_mode FROM v\$database;
        
        exit;
EOF

    log "Flashback to restore point '$restore_point_name' completed."
}

# =============================================================================
# MAIN - Export functions if sourced, otherwise run interactively
# =============================================================================

if [ "${1:-}" = "" ]; then
    # Interactive mode - display dynamic instance information
    log "Fetching Oracle Database information dynamically..."
    log ""
    
    instance=$(get_instance_name)
    db_name=$(get_db_name)
    
    log "Instance Name: $instance"
    log "Database Name: $db_name"
    log ""
    
    log "Database Status:"
    get_database_status
    
    log ""
    log "Available Restore Points:"
    get_restore_points
    
elif [ "$1" = "create" ]; then
    create_flashback_point_dynamic
    
elif [ "$1" = "flashback" ]; then
    if [ -z "${2:-}" ]; then
        log "Usage: $0 flashback <RESTORE_POINT_NAME>"
        exit 1
    fi
    flashback_to_dynamic_point "$2"
    
elif [ "$1" = "status" ]; then
    get_database_status
    
elif [ "$1" = "points" ]; then
    get_restore_points
    
elif [ "$1" = "instance" ]; then
    get_instance_name
    
else
    log "Unknown command: $1"
    exit 1
fi
