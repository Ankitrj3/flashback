# Oracle EBS Flashback Automation

Production-oriented Oracle EBS flashback automation for database restore-point management, application filesystem backup and restore, application service control, and post-restore validation.

## What It Does

- Views current flashback state:
  restore points, application tar backups, and restore history from the alert log.
- Creates a flashback request:
  validates the application state, captures filesystem details, creates CDB and PDB guaranteed restore points, starts application filesystem backups, and restarts services only when the tool stopped them for the request flow.
- Restores a flashback point:
  stops application services, restores filesystem backups, flashes back the database, drops restore points, restarts services, and writes a detached restore log.
- Validates load-test readiness:
  checks application availability, filesystem paths, free space, database state, URLs, and recent alert-log issues.

## Run

Run from the DB server:

```bash
chmod +x scripts/oracle_flashback_menu.sh scripts/oracle/*.sh
./scripts/oracle_flashback_menu.sh
```

## Configuration

The tool auto-detects database-side values with `sqlplus / as sysdba` when possible:

```bash
FLASHBACK_INSTANCE_ID
FLASHBACK_DB_HOST
FLASHBACK_PDB_NAME
FLASHBACK_ALERT_LOG
```

The operator confirms application-side values:

```bash
FLASHBACK_APP_HOST
FLASHBACK_SSH_USER
FLASHBACK_APP_BASE_DIR
FLASHBACK_BACKUP_DIR
```

Optional values used by the workflow:

```bash
FLASHBACK_ORACLE_ENV
FLASHBACK_DB_AUTH
FLASHBACK_DB_USER
FLASHBACK_DB_PASS
FLASHBACK_DB_HOST
FLASHBACK_DB_PORT
FLASHBACK_DB_SERVICE
FLASHBACK_STOP_CMD
FLASHBACK_START_CMD
FLASHBACK_LOAD_TEST_URLS
FLASHBACK_LOAD_TEST_MIN_FREE_GB
FLASHBACK_LOAD_TEST_MIN_APP_PROCESSES
FLASHBACK_MIN_RESTORE_FREE_GB
FLASHBACK_APP_NODES
FLASHBACK_SSH_KEY
```

Saved configuration is written to:

```bash
~/.flashback_env
```

Captured application filesystem metadata is written to:

```bash
~/.flashback_app_info
```

Restore process status is tracked in:

```bash
~/.flashback_restore_pid
```

## Operational Notes

- Run the menu from the database server or from a host with Oracle access, `sqlplus`, and connectivity to the application node.
- SSH access to the application node must work non-interactively for the OS user running the automation.
- Database flashback requires `ARCHIVELOG` and `FLASHBACK_ON=YES`.
- Backup and restore actions assume the configured filesystem paths and tar backup directory are correct and writable.
- In `Make flashback request`, if the tool stops application services for backup safety, it attempts to start them again after the request flow completes and also after later request-flow failures.
- Restore runs in detached mode and writes progress to a timestamped log under `logs/`.

## Main Files

- `scripts/oracle_flashback_menu.sh`
  Interactive entrypoint for all workflows.
- `scripts/oracle/`
  Worker scripts for detection, restore-point creation, backup, restore, service control, validation, and status views.
- `logs/`
  Runtime logs, including detached restore logs.

## Detailed Workflow

See [WORKFLOW.md](./WORKFLOW.md) for the full workflow, script-by-script behavior, and how the pieces fit together.
