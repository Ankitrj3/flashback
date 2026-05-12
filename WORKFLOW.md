# Oracle EBS Flashback Workflow

This document explains how the flashback automation works end to end, what each menu option does, and what every script is responsible for.

## Overview

The tool is centered on one interactive entrypoint:

- `scripts/oracle_flashback_menu.sh`

That menu collects configuration, calls worker scripts, and coordinates the four main operator workflows:

1. View flashback state
2. Make flashback request
3. Restore flashback
4. Validate load-test readiness

The rest of the scripts under `scripts/oracle/` are focused workers. Each one handles a specific part of the automation.

## End-to-End Product Flow

### 1. Environment setup

When the menu starts, it:

- Loads saved values from `~/.flashback_env` if present.
- Attempts database-side auto-detection through `detect_environment.sh`.
- Prompts for missing application-side details such as app host, SSH user, app base directory, and backup directory.
- Saves the resolved configuration back to `~/.flashback_env`.

### 2. View flashback

This workflow shows the current flashback picture without changing state:

- Database guaranteed restore points
- Application tar backup files
- Flashback restore history from the Oracle alert log

### 3. Make flashback request

This is the preparation workflow before load testing or another reversible activity.

It performs these stages:

1. Checks application processes and optionally stops services if the operator chooses that path.
2. Detects and saves RUN, PATCH, and non-editioned filesystem paths.
3. Verifies required application paths exist.
4. Optionally checks current database application session count.
5. Creates CDB and PDB guaranteed restore points.
6. Launches tar backups for `fs_ne`, `fs1`, and `fs2`.
7. Restarts application services only if this workflow stopped them earlier.

### 4. Restore flashback

This is the recovery workflow.

It performs these stages:

1. Stops application services.
2. Shows a database application session report.
3. Queries available restore points and asks the operator to select or enter them.
4. Lists available backup tar files and asks for the backup date tag to restore.
5. Launches `restore_flashback.sh` in detached mode and writes a timestamped log file under `logs/`.

The detached restore script then:

1. Restores application filesystems from tar backups.
2. Flashes back the PDB and CDB to the chosen restore points.
3. Drops the used restore points.
4. Starts application services.
5. Writes a summary and leaves a log trail for status tracking.

### 5. Validate load-test readiness

This workflow checks whether the restored or prepared system looks ready for testing.

It validates:

- Application base directory reachability
- Application process count
- RUN, PATCH, and non-editioned filesystem paths
- Free space
- Configured application URLs
- Database and PDB open mode
- Invalid objects
- Blocking sessions
- Recent alert-log errors

## Menu Script

### `scripts/oracle_flashback_menu.sh`

This is the operator-facing controller.

Responsibilities:

- Loads and saves configuration
- Displays the interactive menu
- Calls the correct worker script for each menu option
- Restarts application services after `Make flashback request` only when that request flow stopped them
- Collects restore-point and backup-tag choices during restore
- Starts detached restore execution
- Tracks detached restore PIDs and log files

Key artifacts managed here:

- `~/.flashback_env`
- `~/.flashback_app_info`
- `~/.flashback_restore_pid`

## Worker Scripts

### `scripts/oracle/detect_environment.sh`

Purpose:

- Queries Oracle for the DB name, DB host, alert log path, and a default read-write PDB.

Used by:

- `oracle_flashback_menu.sh`

### `scripts/oracle/view_flashback.sh`

Purpose:

- Implements the `View Flashback` option.

What it does:

- Calls `list_restore_points.sh`
- Lists application tar files from the backup directory
- Searches the alert log for flashback restore history

### `scripts/oracle/list_restore_points.sh`

Purpose:

- Queries `V$RESTORE_POINT` and prints current restore points.

Used by:

- `view_flashback.sh`
- `restore_flashback.sh`

### `scripts/oracle/capture_app_info.sh`

Purpose:

- Prepares the application-side context before backup.

What it does:

- Counts application processes
- Lets the operator choose whether to continue while services are up or stop them first
- Detects RUN and PATCH filesystem roles from EBS context XML when possible
- Verifies application filesystem paths
- Optionally checks database application sessions
- Writes filesystem metadata and stop-state metadata to `~/.flashback_app_info`

### `scripts/oracle/create_flashback_restore_point.sh`

Purpose:

- Creates the guaranteed restore points used later for recovery.

What it does:

- Verifies the database is in `ARCHIVELOG`
- Verifies `FLASHBACK_ON=YES`
- Creates a CDB guaranteed restore point
- Switches to the target PDB and creates a PDB guaranteed restore point
- Verifies both restore points were created successfully

### `scripts/oracle/create_backup.sh`

Purpose:

- Starts application filesystem tar backups.

What it does:

- Validates backup directory and application base path
- Works locally or through SSH to remote application nodes
- Builds tar file names using the instance ID and date tag
- Starts backup jobs for `fs_ne`, `fs1`, and `fs2`

### `scripts/oracle/stop_app_services.sh`

Purpose:

- Stops Oracle EBS application services before restore or when backup requires it.

What it does:

- Counts running application processes
- Prompts for APPS and WebLogic credentials when needed
- Locates `adstpall.sh` or the configured stop command
- Runs the stop command
- Waits until application processes go down

### `scripts/oracle/restore_flashback.sh`

Purpose:

- Orchestrates the detached restore flow.

What it does:

- Uses the selected restore-point names and backup date tag
- Stops services if the menu did not already do it
- Calls `restore_backup.sh`
- Calls `flashback_database.sh`
- Calls `start_app_services.sh`
- Writes summary markers and final status to the restore log

### `scripts/oracle/restore_backup.sh`

Purpose:

- Restores application filesystems from backup tar files.

What it does:

- Detects the latest backup date tag when one is not provided
- Checks free space
- Renames existing filesystems aside with a timestamp suffix
- Extracts tar files for `fs_ne`, `fs1`, and `fs2`
- Waits for restore jobs to complete

### `scripts/oracle/flashback_database.sh`

Purpose:

- Flashes back the database to the selected restore points and then cleans up.

What it does:

- Verifies the restore points exist
- Handles RAC precheck logic through `cluster_database`
- Flashes back the PDB
- Flashes back the CDB
- Opens the PDB
- Drops the restore points
- Verifies final database state

### `scripts/oracle/start_app_services.sh`

Purpose:

- Starts Oracle EBS application services after restore.

What it does:

- Prompts for APPS and WebLogic credentials when needed
- Locates `adstrtal.sh` or the configured start command
- Runs the start command
- Waits until application processes appear

### `scripts/oracle/validate_load_test_ready.sh`

Purpose:

- Performs readiness checks after restore or preparation.

What it does:

- Checks application base directory and filesystem paths
- Checks process count
- Checks free space
- Checks configured URLs if provided
- Checks database and PDB open mode
- Reports invalid objects and blocking sessions
- Scans recent alert-log lines for errors

## Files Written During Execution

### `~/.flashback_env`

Saved operator configuration such as:

- DB and PDB values
- app host and SSH user
- application base directory
- backup directory
- alert log path

### `~/.flashback_app_info`

Saved application filesystem metadata:

- `FLASHBACK_RUN_FS`
- `FLASHBACK_PATCH_FS`
- `FLASHBACK_NE_FS`
- `FLASHBACK_APP_STOPPED_BY_TOOL`

### `~/.flashback_restore_pid`

Used by the menu to track:

- Detached restore PID
- Restore log file path

### `logs/restore_flashback_<timestamp>.log`

Full restore execution log for detached restore runs.

## Logging Model

The scripts now use operation markers instead of timestamping every line.

Typical pattern:

```text
[START] <Operation> : <timestamp>
...
[END] <Operation> : <timestamp>
```

This keeps output readable while still showing when major operations started and ended.

## Failure Model

The scripts are built to stop on failed prerequisites or failed critical actions.

Examples:

- Missing `sqlplus`
- Missing restore points
- Backup directory not writable
- Application base directory not found
- Flashback prerequisites not enabled
- Tar restore failure
- Application stop failure

Where the workflow can safely continue with operator awareness, the scripts log warnings instead of exiting immediately.

## Suggested Operational Sequence

Typical operator usage:

1. Start the menu.
2. Confirm saved or detected environment values.
3. Run `Make flashback request`.
4. Perform the external activity that may need rollback.
5. Run `Restore flashback` if rollback is required.
6. Run `Validate system ready for Load test` after restore or handoff preparation.

## Notes

- This automation assumes the DB host can reach the application node over SSH.
- It assumes Oracle authentication and EBS service control are already aligned with the target environment.
- Because restore changes both database and filesystem state, operator confirmation is intentionally required before destructive actions begin.
