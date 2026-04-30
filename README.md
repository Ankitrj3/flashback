# Oracle Flashback Management Tool

A comprehensive bash-based solution for managing Oracle Database flashback points and backups.

FLASHBACK_DEMO=true ./scripts/oracle_flashback_menu.sh

## Quick Start

### Prerequisites
- Oracle Database installed and running
- Oracle client tools configured
- Bash shell environment

### Installation

1. Clone or extract this repository:
```bash
cd /Users/ankitrj3/Desktop/flashback
```

2. Make scripts executable:
```bash
chmod +x ./scripts/*.sh
chmod +x ./scripts/oracle/*.sh
```

## Running the Application

### Interactive Menu (Recommended)
```bash
./scripts/oracle_flashback_menu.sh
```

This provides a user-friendly menu with options to:
- **Create Backup & Flashback Point** - Backup database and create a restore point
- **Restore from Flashback** - Revert database to a previous state (requires confirmation)
- **List Restore Points** - View all available flashback points
- **Test Connectivity** - Verify database connection
- **Shutdown App Services** - Stop application services before flashback

### CLI Execution
```bash
./scripts/run_cli.sh
```

## Demo Workflow

### 1. Test Connectivity
```bash
./scripts/oracle/test_connectivity.sh
```
Verifies your database is accessible.

### 2. Create a Backup Point
```bash
./scripts/oracle/create_backup.sh
./scripts/oracle/create_flashback_restore_point.sh
```
Creates a backup and associated flashback restore point.

### 3. View Available Restore Points
```bash
./scripts/oracle/list_restore_points.sh
```
Lists all available flashback restore points.

### 4. Restore from a Point (if needed)
```bash
./scripts/oracle/flashback_to_restore_point.sh
```
Restores database to a previous state.

## Project Structure

```
scripts/
├── oracle_flashback_menu.sh      # Main interactive menu
├── run_cli.sh                     # CLI entry point
├── package.sh                     # Packaging utility
└── oracle/
    ├── create_backup.sh           # Backup creation
    ├── create_flashback_restore_point.sh
    ├── flashback_to_restore_point.sh
    ├── list_restore_points.sh
    ├── restore_backup.sh
    ├── shutdown_app_services.sh
    └── test_connectivity.sh
```

## Features

✓ Interactive menu-driven interface  
✓ Automated backup creation  
✓ Flashback restore point management  
✓ Database connectivity testing  
✓ Application service shutdown before restore  
✓ Double-confirmation for restore operations  

## Safety Features

- **Double Confirmation**: Restore operations require user confirmation to prevent accidental data loss
- **Service Shutdown**: Can gracefully shutdown app services before flashback
- **Connectivity Check**: Verify database is available before operations

## Troubleshooting

- Ensure Oracle database is running and accessible
- Verify database credentials are configured
- Check that flashback database is enabled on your Oracle instance
- Run `test_connectivity.sh` to diagnose connection issues

## License

See LICENSE file for details.

