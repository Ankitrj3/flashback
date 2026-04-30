#!/usr/bin/env python3
# =============================================================================
# query_to_script.py — Convert SQL/Flashback queries into executable shell scripts
#
# USAGE:
#   python3 query_to_script.py "SELECT instance_name FROM v$instance"
#   python3 query_to_script.py "CREATE RESTORE POINT my_point GUARANTEE FLASHBACK DATABASE"
#   python3 query_to_script.py "FLASHBACK DATABASE TO RESTORE POINT my_point"
#   python3 query_to_script.py "flashback_create_backup" (predefined commands)
#
# Converts SQL/commands into shell scripts and optionally executes them
# =============================================================================

import sys
import os
import re
import subprocess
import json
from pathlib import Path
from datetime import datetime

class QueryToScript:
    """Convert SQL/Flashback queries into executable shell scripts"""
    
    # Predefined command mappings
    COMMANDS = {
        'flashback_create_backup': {
            'type': 'sh',
            'script': 'scripts/oracle/create_backup.sh',
            'desc': 'Create database backup'
        },
        'flashback_create_point': {
            'type': 'sh',
            'script': 'scripts/oracle/create_flashback_restore_point.sh',
            'desc': 'Create flashback restore point'
        },
        'flashback_list_points': {
            'type': 'sql',
            'query': 'SELECT name, time, guarantee_flashback_database, storage_size, con_id FROM v$restore_point ORDER BY time DESC;',
            'desc': 'List all restore points'
        },
        'flashback_test_connectivity': {
            'type': 'sh',
            'script': 'scripts/oracle/test_connectivity.sh',
            'desc': 'Test database connectivity'
        },
        'flashback_get_instance': {
            'type': 'sql',
            'query': 'SELECT instance_name FROM v$instance;',
            'desc': 'Get current instance name'
        },
        'flashback_get_status': {
            'type': 'sql',
            'query': 'SELECT i.instance_name, d.name, d.open_mode, d.log_mode, d.flashback_on FROM v$instance i, v$database d;',
            'desc': 'Get database status'
        }
    }
    
    def __init__(self):
        self.script_dir = os.path.dirname(os.path.abspath(__file__))
        self.root_dir = os.path.dirname(self.script_dir)
    
    def is_sql_query(self, query_str):
        """Check if input is a SQL query"""
        sql_keywords = ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'CREATE', 'ALTER', 'DROP', 'FLASHBACK', 'FROM', 'WHERE']
        upper_query = query_str.strip().upper()
        return any(keyword in upper_query for keyword in sql_keywords)
    
    def parse_sql_query(self, query_str):
        """Parse SQL query and identify type"""
        upper_query = query_str.strip().upper()
        
        if 'FLASHBACK DATABASE' in upper_query:
            return {
                'type': 'flashback',
                'action': 'flashback_database',
                'original': query_str
            }
        elif 'CREATE RESTORE POINT' in upper_query:
            restore_point = self._extract_restore_point_name(query_str)
            return {
                'type': 'restore_point',
                'action': 'create_restore_point',
                'restore_point': restore_point,
                'original': query_str
            }
        elif 'SELECT' in upper_query and 'V$RESTORE_POINT' in upper_query:
            return {
                'type': 'query',
                'action': 'list_restore_points',
                'original': query_str
            }
        elif 'SELECT' in upper_query:
            return {
                'type': 'query',
                'action': 'select_query',
                'original': query_str
            }
        else:
            return {
                'type': 'query',
                'action': 'execute_sql',
                'original': query_str
            }
    
    def _extract_restore_point_name(self, query_str):
        """Extract restore point name from CREATE RESTORE POINT query"""
        match = re.search(r'CREATE\s+RESTORE\s+POINT\s+["\']?([^\s"\']+)["\']?', query_str, re.IGNORECASE)
        if match:
            return match.group(1)
        return None
    
    def generate_sql_script(self, query_info):
        """Generate shell script that executes SQL query"""
        query = query_info['original']
        action = query_info['action']
        
        script = f"""#!/bin/bash
# Auto-generated script from query: {action}
# Generated: {datetime.now().isoformat()}

set -e

log() {{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}}

log "Executing SQL query..."
log "Query: {query}"
log ""

# Execute SQL query
sqlplus / as sysdba <<EOSQL
    set heading on feedback off pagesize 100 linesize 150
    {query}
    exit;
EOSQL

log "Query execution completed."
"""
        return script
    
    def generate_flashback_script(self, query_info):
        """Generate flashback restoration script"""
        restore_point = query_info.get('restore_point', 'MY_RESTORE_POINT')
        
        script = f"""#!/bin/bash
# Auto-generated flashback script
# Generated: {datetime.now().isoformat()}

set -e

log() {{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}}

log "=============================================="
log "ORACLE FLASHBACK DATABASE"
log "=============================================="
log "Restore Point: {restore_point}"
log ""

# Verify restore point exists
log "Step 1: Verifying restore point..."
sqlplus / as sysdba <<EOSQL
    set heading on feedback off pagesize 0 linesize 100
    SELECT name, time, guarantee_flashback_database 
    FROM v\\$restore_point 
    WHERE name = '{restore_point}';
    exit;
EOSQL

# Close PDBs
log "Step 2: Closing all PDBs..."
sqlplus / as sysdba <<EOSQL
    ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE;
    exit;
EOSQL

# Flashback
log "Step 3: Executing flashback..."
sqlplus / as sysdba <<EOSQL
    FLASHBACK DATABASE TO RESTORE POINT "{restore_point}";
    ALTER DATABASE OPEN RESETLOGS;
    exit;
EOSQL

# Open PDBs
log "Step 4: Opening all PDBs..."
sqlplus / as sysdba <<EOSQL
    ALTER PLUGGABLE DATABASE ALL OPEN;
    exit;
EOSQL

log "Flashback completed successfully."
"""
        return script
    
    def generate_restore_point_script(self, query_info):
        """Generate restore point creation script"""
        restore_point = query_info.get('restore_point', 'AUTO_RP_' + datetime.now().strftime('%d%b%y'))
        
        script = f"""#!/bin/bash
# Auto-generated restore point creation script
# Generated: {datetime.now().isoformat()}

set -e

log() {{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}}

log "Creating restore point: {restore_point}"
log ""

# Create restore point
sqlplus / as sysdba <<EOSQL
    CREATE RESTORE POINT "{restore_point}" GUARANTEE FLASHBACK DATABASE;
    exit;
EOSQL

log "Restore point '{restore_point}' created successfully."
log ""
log "Verify with:"
log "  sqlplus / as sysdba"
log "  SELECT name, time FROM v\\$restore_point WHERE name='{restore_point}';"
"""
        return script
    
    def convert_query(self, query_input):
        """Convert query or command to shell script"""
        
        # Check if it's a predefined command
        if query_input.lower() in self.COMMANDS:
            cmd_info = self.COMMANDS[query_input.lower()]
            return {
                'type': 'predefined',
                'command': query_input.lower(),
                'description': cmd_info['desc'],
                'script_path': cmd_info.get('script'),
                'query': cmd_info.get('query')
            }
        
        # Parse as SQL query
        if self.is_sql_query(query_input):
            query_info = self.parse_sql_query(query_input)
            
            if query_info['type'] == 'flashback':
                script_content = self.generate_flashback_script(query_info)
                return {
                    'type': 'flashback',
                    'action': query_info['action'],
                    'script': script_content,
                    'query': query_input
                }
            elif query_info['type'] == 'restore_point':
                script_content = self.generate_restore_point_script(query_info)
                return {
                    'type': 'restore_point',
                    'action': query_info['action'],
                    'script': script_content,
                    'restore_point': query_info.get('restore_point'),
                    'query': query_input
                }
            else:
                script_content = self.generate_sql_script(query_info)
                return {
                    'type': 'sql',
                    'action': query_info['action'],
                    'script': script_content,
                    'query': query_input
                }
        
        return {
            'type': 'unknown',
            'error': 'Could not parse input as SQL query or predefined command',
            'input': query_input
        }
    
    def save_script(self, script_content, filename=None):
        """Save script to file"""
        if filename is None:
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            filename = f'generated_script_{timestamp}.sh'
        
        filepath = os.path.join(self.script_dir, filename)
        
        with open(filepath, 'w') as f:
            f.write(script_content)
        
        os.chmod(filepath, 0o755)
        return filepath
    
    def execute_script(self, script_content):
        """Execute generated script"""
        try:
            result = subprocess.run(
                ['bash', '-c', script_content],
                capture_output=True,
                text=True,
                timeout=300
            )
            return {
                'success': result.returncode == 0,
                'stdout': result.stdout,
                'stderr': result.stderr,
                'returncode': result.returncode
            }
        except subprocess.TimeoutExpired:
            return {
                'success': False,
                'error': 'Script execution timed out (5 minutes)',
                'returncode': -1
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e),
                'returncode': -1
            }


def main():
    if len(sys.argv) < 2:
        print("Query to Script Converter")
        print("")
        print("Usage:")
        print("  python3 query_to_script.py '<SQL_QUERY>' [--execute] [--save <filename>]")
        print("  python3 query_to_script.py '<command>' [--list]")
        print("")
        print("Examples:")
        print("  python3 query_to_script.py 'SELECT instance_name FROM v$instance'")
        print("  python3 query_to_script.py 'CREATE RESTORE POINT my_rp GUARANTEE FLASHBACK DATABASE'")
        print("  python3 query_to_script.py 'FLASHBACK DATABASE TO RESTORE POINT my_rp'")
        print("  python3 query_to_script.py flashback_get_instance --execute")
        print("  python3 query_to_script.py --list")
        print("")
        print("Predefined Commands:")
        for cmd, info in QueryToScript.COMMANDS.items():
            print(f"  {cmd:<30} - {info['desc']}")
        sys.exit(1)
    
    converter = QueryToScript()
    
    # Handle --list flag
    if sys.argv[1] == '--list':
        print("Available Predefined Commands:")
        print("")
        for cmd, info in QueryToScript.COMMANDS.items():
            print(f"  {cmd}")
            print(f"    Description: {info['desc']}")
            print(f"    Type: {info['type']}")
            if 'query' in info:
                print(f"    Query: {info['query']}")
            print()
        sys.exit(0)
    
    query_input = sys.argv[1]
    execute_flag = '--execute' in sys.argv
    save_flag = '--save' in sys.argv
    save_filename = None
    
    if save_flag:
        try:
            idx = sys.argv.index('--save')
            if idx + 1 < len(sys.argv):
                save_filename = sys.argv[idx + 1]
        except (ValueError, IndexError):
            pass
    
    # Convert query
    result = converter.convert_query(query_input)
    
    print(json.dumps(result, indent=2, default=str))
    print("")
    
    if result['type'] == 'unknown':
        print(f"Error: {result['error']}")
        sys.exit(1)
    
    # Save script if requested
    if save_flag and 'script' in result:
        filepath = converter.save_script(result['script'], save_filename)
        print(f"Script saved to: {filepath}")
        print("")
    
    # Execute script if requested
    if execute_flag and 'script' in result:
        print("Executing script...")
        print("")
        exec_result = converter.execute_script(result['script'])
        
        if exec_result['success']:
            print("✓ Script executed successfully")
            if exec_result['stdout']:
                print("\nOutput:")
                print(exec_result['stdout'])
        else:
            print("✗ Script execution failed")
            print(f"Return code: {exec_result['returncode']}")
            if exec_result.get('error'):
                print(f"Error: {exec_result['error']}")
            if exec_result.get('stderr'):
                print(f"Stderr:\n{exec_result['stderr']}")
        
        sys.exit(0 if exec_result['success'] else 1)


if __name__ == '__main__':
    main()
