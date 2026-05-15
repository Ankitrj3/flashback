# Oracle EBS Flashback Automation

Production-grade Oracle EBS flashback automation for database restore-point management, application filesystem backup and restore, application service control, and post-restore validation.

## What It Does

- **View Flashback** — Shows current guaranteed restore points, application tar backup files, and restore history from the Oracle alert log. Read-only, no state changes.
- **Make Flashback Request** — Validates the APPS password (when stopping services), checks application process state, detects RUN/PATCH filesystem roles, creates CDB and PDB guaranteed restore points with a unique `DDMonYY_HHmm` timestamp, and launches tar backups for all three filesystems in the background.
- **Restore Flashback** — Validates the APPS password, stops application services, queries and selects restore points interactively, selects the backup date tag, then launches the full restore in detached mode (DB flashback + filesystem restore + service restart).
- **Validate Load-Test Readiness** — Checks application availability, filesystem paths, free space, database and PDB open mode, invalid objects, blocking sessions, and recent alert-log errors.

> **Restore points are never dropped automatically.** They remain in the database after a flashback so they can be reused or reviewed via Option 1.

## Run

Run from the DB server (requires `sqlplus` on PATH and SSH access to the app node):

```bash
chmod +x scripts/oracle_flashback_menu.sh scripts/oracle/*.sh
./scripts/oracle_flashback_menu.sh
```

## Configuration

### Auto-detected (from `sqlplus / as sysdba`)

```
FLASHBACK_INSTANCE_ID   DB name / CDB name
FLASHBACK_DB_HOST       Database host
FLASHBACK_PDB_NAME      Default read-write PDB name
FLASHBACK_ALERT_LOG     Oracle alert log path
```

### Prompted at first run

```
FLASHBACK_APP_HOST        Application server hostname (blank if local)
FLASHBACK_SSH_USER        OS user for SSH to app node
FLASHBACK_APP_BASE_DIR    Application base directory (e.g. /db6000/app/oracle/r122RXECDV05)
FLASHBACK_BACKUP_DIR      Tar backup target directory (e.g. /iriscommon/backups/tars)
FLASHBACK_APPS_PASS       APPS schema password — prompted silently on first use of Option 2 or 3
```

### Optional / advanced

```
FLASHBACK_ORACLE_ENV               Path to Oracle environment script to source before sqlplus
FLASHBACK_DB_AUTH                  Set to 'os' (default) or 'password' for DB auth mode
FLASHBACK_DB_USER / FLASHBACK_DB_PASS / FLASHBACK_DB_SERVICE / FLASHBACK_DB_PORT
FLASHBACK_STOP_CMD                 EBS stop command (default: adstpall.sh)
FLASHBACK_START_CMD                EBS start command (default: adstrtal.sh)
FLASHBACK_WLS_PASS                 WebLogic admin password
FLASHBACK_APP_NODES                Space-separated list of app nodes for multi-node backups
FLASHBACK_SSH_KEY                  SSH private key path
FLASHBACK_FS_LIST                  Filesystems to back up (default: fs_ne fs1 fs2)
FLASHBACK_MIN_RESTORE_FREE_GB      Minimum free GB required before restore (default: 250)
FLASHBACK_LOAD_TEST_URLS           Space-separated URLs to probe during readiness check
FLASHBACK_LOAD_TEST_MIN_FREE_GB    Minimum free GB for readiness check (default: 50)
FLASHBACK_LOAD_TEST_MIN_APP_PROCESSES  Minimum process count for readiness check (default: 3)
```

## Persistent State Files

| File | Purpose |
|---|---|
| `~/.flashback_env` | All operator configuration; loaded at every startup |
| `~/.flashback_app_info` | RUN/PATCH/NE filesystem paths and `FLASHBACK_APP_STOPPED_BY_TOOL` flag; loaded at startup |
| `~/.flashback_restore_pid` | Detached restore PID and log path for status tracking (Option 7) |

## Restore Point Naming

Restore points are named using a `DDMonYY_HHmm` timestamp to avoid collisions across multiple same-day requests:

```
RXECDV05_CDB_flashback_restore_15May26_1133
RXECDV05_PDB_flashback_restore_15May26_1133
```

An optional custom suffix can be typed at the restore-point name prompt to override the default.

## Operational Notes

- Run the menu from the DB server or any host with `sqlplus` on PATH and SSH access to the app node.
- SSH access to the application node must work non-interactively (key-based or pre-authenticated).
- The database must be in `ARCHIVELOG` mode with `FLASHBACK_ON=YES`.
- The APPS password is collected silently (hidden input) on first use and persisted to `~/.flashback_env`.
- RUN/PATCH filesystem roles are auto-detected via EBS context XML or `EBSapps.env` symlink. If both methods fail, the operator is prompted once and the choice is persisted to `~/.flashback_app_info` for all subsequent runs.
- EBS service shutdown waits up to 20 minutes for all processes to stop before continuing.
- Backups (tar) run in the background; restore runs fully detached. Both write timestamped logs under `logs/`.
- Use **Option 6 (Delete stored config)** to clear `~/.flashback_env` and start configuration from scratch. Delete `~/.flashback_app_info` manually to force re-detection of filesystem roles.

## Main Files

```
scripts/oracle_flashback_menu.sh        Interactive entrypoint for all workflows
scripts/oracle/detect_environment.sh    Auto-detects DB environment via sqlplus
scripts/oracle/capture_app_info.sh      Detects FS roles, verifies paths, checks DB sessions
scripts/oracle/create_flashback_restore_point.sh  Creates CDB/PDB guaranteed restore points
scripts/oracle/create_backup.sh         Launches parallel tar backups (background)
scripts/oracle/stop_app_services.sh     Stops EBS services, waits up to 20 min for shutdown
scripts/oracle/start_app_services.sh    Starts EBS services, waits for processes to appear
scripts/oracle/restore_flashback.sh     Orchestrates full detached restore
scripts/oracle/restore_backup.sh        Restores filesystem tar archives
scripts/oracle/flashback_database.sh   Flashes back CDB and PDB via sqlplus
scripts/oracle/view_flashback.sh        Read-only view of restore points, tars, and history
scripts/oracle/list_restore_points.sh   Queries V$RESTORE_POINT
scripts/oracle/validate_load_test_ready.sh  Post-restore readiness validation
logs/                                   Runtime and detached restore logs
```

## Detailed Workflow

See [WORKFLOW.md](./WORKFLOW.md) for the full workflow, script-by-script behavior, and how the pieces fit together.
