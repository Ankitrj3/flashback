# Oracle EBS Flashback Automation

Production-ready Phase 1/2 automation for Oracle EBS flashback preparation from the DB server.

## Scope

1. **View Flashback**
   - Show DB guaranteed restore points from `V$RESTORE_POINT`.
   - Show application tar backups from `/iriscommon/backup/tar`.
   - Show restore history timings by grepping the DB alert log for `Flashback restore`.

2. **Make flashback request**
   - Detect DB name, DB hostname, PDB name, and alert log path from Oracle.
   - Create CDB guaranteed restore point.
   - Switch to PDB and create PDB guaranteed restore point.
   - Show current restore points.
   - Check application services from the DB server using SSH.
   - If application services are running, ask whether to continue backup as-is or shutdown first.
   - If shutdown is selected, stop services and verify application processes are down.
   - Take tar backups for `fs_ne`, `fs1`, and `fs2` under `/iriscommon/backup/tar`.

`Restore flashback` and `Validate system ready for Load test` are visible in the menu as next-phase placeholders.

## Run

Run from the DB server:

```bash
chmod +x scripts/oracle_flashback_menu.sh scripts/oracle/*.sh
./scripts/oracle_flashback_menu.sh
```

Default execution mode is `dry-run`. It prints the DB commands, shutdown actions, and tar commands without changing the database or filesystems.

Live execution:

```bash
FLASHBACK_MODE=real ./scripts/oracle_flashback_menu.sh
```

This one setting is the intended switch from demo to live action. If `~/.flashback_env` already contains `FLASHBACK_MODE=dry-run`, the command-line value `FLASHBACK_MODE=real` still wins for that run and is saved back to the config. You can also change mode from the menu.

## Values

The tool auto-detects DB-side values using `sqlplus / as sysdba`:

```bash
FLASHBACK_INSTANCE_ID
FLASHBACK_DB_HOST
FLASHBACK_PDB_NAME
FLASHBACK_ALERT_LOG
FLASHBACK_MODE
```

The operator confirms environment-specific application values:

```bash
FLASHBACK_APP_HOST
FLASHBACK_SSH_USER
FLASHBACK_APP_BASE_DIR
FLASHBACK_BACKUP_DIR
```

The default backup directory follows the client runbook:

```bash
/iriscommon/backup/tar
```

Shutdown credentials are requested only when application services are running and shutdown is approved:

```bash
FLASHBACK_APPS_USER
FLASHBACK_APPS_PASS
FLASHBACK_WLS_PASS
```

Values are stored in:

```bash
~/.flashback_env
```

The file is protected with `600` permissions. It can be removed from the menu with `Delete stored config`.

## Why Some Values Are Required

DB name, DB host, PDB name, and alert log path can be detected because the automation runs from the DB server.

Application host, SSH user, app base directory, backup directory, and application shutdown credentials are environment-specific. They must be confirmed because the DB server cannot safely infer the correct EBS application node, mount path, or credential policy in every environment.

## Scripts

- `scripts/oracle_flashback_menu.sh`
  Main interactive menu and config loader.

- `scripts/oracle/detect_environment.sh`
  Detects DB name, DB hostname, PDB name, and alert log path.

- `scripts/oracle/view_flashback.sh`
  Implements menu option 1, including a parsed start/complete timing view from the DB alert log.

- `scripts/oracle/list_restore_points.sh`
  Runs the `V$RESTORE_POINT` query.

- `scripts/oracle/create_flashback_restore_point.sh`
  Creates CDB and PDB guaranteed restore points.

- `scripts/oracle/capture_app_info.sh`
  Shows app file-system paths, checks app services, and handles the continue-or-shutdown backup decision.

- `scripts/oracle/create_backup.sh`
  Creates application tar backups for `fs_ne`, `fs1`, and `fs2` using the client date format, for example `09dec25`.

## Backup Decision

If application processes are detected, the tool asks whether to continue the backup while services are running. If the operator answers `no`, it asks whether to shutdown application services first. In `dry-run`, both paths print the intended actions. In `real`, shutdown uses `adstpall.sh` by default and then checks application processes again.

## Dry-Run Demo

Use dry-run mode for walkthroughs:

```bash
FLASHBACK_MODE=dry-run ./scripts/oracle_flashback_menu.sh
```

For a dry-run where app services appear to be running:

```bash
FLASHBACK_MODE=dry-run FLASHBACK_DRY_RUN_PROCESS_COUNT=274 ./scripts/oracle_flashback_menu.sh
```

This exercises the shutdown decision path without stopping services or creating tar files.

## Live Execution Checklist

Before running real actions, validate these items on the DB server:

- `sqlplus / as sysdba` works for the Oracle owner or `FLASHBACK_DB_AUTH` credentials are configured.
- Database is in `ARCHIVELOG` mode and `FLASHBACK_ON=YES`.
- Correct `FLASHBACK_PDB_NAME`, `FLASHBACK_APP_HOST`, `FLASHBACK_SSH_USER`, `FLASHBACK_APP_BASE_DIR`, and `FLASHBACK_BACKUP_DIR` are saved in `~/.flashback_env`.
- SSH from the DB server to each application node works without an interactive OS-password prompt.
- The backup directory exists or can be created, is writable, and has enough free space for `fs_ne`, `fs1`, and `fs2`.
- The operator has confirmed whether application services may remain running during backup, or has valid APPS/WebLogic credentials for shutdown.

Real action requires one of these:

```bash
FLASHBACK_MODE=real ./scripts/oracle_flashback_menu.sh
```

or choose `Change execution mode` from the menu and type `REAL`.

The workflow still requires an explicit `YES` confirmation before `Make flashback request` proceeds.
