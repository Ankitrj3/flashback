# Oracle EBS Flashback Workflow

This document explains how the flashback automation works end to end, what each menu option does, and what every script is responsible for.

## Overview

The tool is centered on one interactive entrypoint:

- `scripts/oracle_flashback_menu.sh`

That menu collects configuration, calls worker scripts, and coordinates four operator workflows accessible from a numbered menu:

| Option | Name |
|---|---|
| 1 | View Flashback |
| 2 | Make Flashback Request |
| 3 | Restore Flashback |
| 4 | Validate System Ready for Load Test |
| 5 | Exit |
| 6 | Delete Stored Config |
| 7 | View Backup / Restore Job Status |

All worker scripts live under `scripts/oracle/`.

---

## End-to-End Product Flow

### Startup

When the menu starts, it:

1. Loads saved configuration from `~/.flashback_env` if it exists.
2. Attempts DB-side auto-detection via `detect_environment.sh` (instance ID, PDB name, alert log path).
3. Prompts for missing application-side values (app host, SSH user, app base directory, backup directory).
4. Saves the resolved configuration back to `~/.flashback_env`.
5. Loads previously persisted filesystem role metadata from `~/.flashback_app_info` (if available). This prevents re-detection or re-prompting of RUN/PATCH roles on subsequent sessions.

---

### Option 1 — View Flashback

Read-only. No state changes.

What it shows:
- All current `V$RESTORE_POINT` entries (name, time, guaranteed flag, storage size, PDB, CON_ID)
- Application tar backup files matching `${INSTANCE_ID}_*_backup_*.tar` in the backup directory
- Flashback restore history from the Oracle alert log (grep for `Flashback restore`)

---

### Option 2 — Make Flashback Request

This is the preparation workflow. It runs in three stages.

#### Stage 1 — Application Service Check

1. Counts running EBS-related processes (FND, INV, Forms, Java, HTTP, aporx).
2. Asks the operator: **"Continue backup WITH services running? (yes/no)"**
   - **yes** → proceeds without stopping services; no password required.
   - **no** → prompts for APPS password (silent input), validates against DB, then stops services using `stop_app_services.sh`. After successful stop, sets `FLASHBACK_APP_STOPPED_BY_TOOL=true` in `~/.flashback_app_info`.
   - anything else → cancelled, returns to menu.
3. Calls `capture_app_info.sh` to detect FS roles and verify paths.

#### Stage 2 — Create DB Restore Points

Calls `create_flashback_restore_point.sh`:
- Verifies `ARCHIVELOG` mode and `FLASHBACK_ON=YES`.
- Creates CDB guaranteed restore point named `{INSTANCE_ID}_CDB_flashback_restore_{DDMonYY_HHmm}`.
- Creates PDB guaranteed restore point named `{INSTANCE_ID}_PDB_flashback_restore_{DDMonYY_HHmm}`.
- The `_HHmm` suffix prevents name collisions when multiple requests are made on the same day.
- If sqlplus fails (ORA- error), the full error output is displayed with diagnostic hints.

#### Stage 3 — Launch Tar Backups

Calls `create_backup.sh` via `nohup` in the background:
- Backs up `fs_ne`, `fs1`, and `fs2` relative to `APP_BASE_DIR`.
- Names archives: `{INSTANCE_ID}_{fs_label}_backup_{DDMonYY}.tar`
- Writes per-filesystem `.log` files in the backup directory.
- The menu returns to the operator immediately; backup continues unattended.

If the tool stopped services in Stage 1, it restarts them via `start_app_services.sh` before returning to the menu.

---

### Option 3 — Restore Flashback

This is the recovery workflow. It runs **foreground** up to the final confirmation, then launches detached.

#### Foreground Steps

1. **Confirm** — Operator types `YES` to proceed.
2. **Password validation** — APPS password prompted silently if not already configured. Validated via sqlplus. If wrong, the cached password is cleared and the operator is returned to the menu.
3. **Stop services** — Calls `stop_app_services.sh`. Waits up to **20 minutes** for all EBS processes to stop.
4. **DB session report** — Shows non-background session counts by program/module.
5. **Select restore point** — Queries `V$RESTORE_POINT`, presents a numbered list, operator picks CDB and PDB restore points separately.
6. **Select backup date tag** — Lists available tar files and asks for the backup date tag to restore from.
7. **Final confirm** — Operator types `RESTORE` to launch.

#### Detached Restore (`restore_flashback.sh`)

Runs under `nohup` with all output written to `logs/restore_flashback_{timestamp}.log`.

Steps:
1. **Restore application filesystems** (`restore_backup.sh`)
   - Checks free space (minimum 250 GB by default).
   - Renames existing `fs_ne`, `fs1`, `fs2` aside with a timestamp (safety net, not deletion).
   - Extracts tar archives for all three filesystems in parallel.
   - Waits for all tar jobs to complete before continuing.
2. **Flash back database** (`flashback_database.sh`)
   - Verifies both restore points still exist.
   - Handles RAC: sets `cluster_database=FALSE`, stops via `srvctl`, restarts single-instance.
   - Flashes back the PDB.
   - Flashes back the CDB (requires `MOUNT` mode via `SHUTDOWN IMMEDIATE` + `STARTUP MOUNT`).
   - Opens PDB and CDB with `RESETLOGS`.
   - **Restore points are NOT dropped** — they remain available for review (Option 1).
   - Verifies final database open mode and PDB state.
3. **Start application services** (`start_app_services.sh`)
   - Locates `adstrtal.sh`, runs it.
   - Waits up to 10 minutes (20 × 30 s) for EBS processes to appear.
4. **Restore summary** — Logs CDB/PDB restore points used, filesystem restore status, and service start status.

PID and log path recorded in `~/.flashback_restore_pid` for Option 7 status tracking.

---

### Option 4 — Validate System Ready for Load Test

Runs `validate_load_test_ready.sh`. Each check is recorded as PASS / WARN / FAIL.

| Check | Pass condition |
|---|---|
| Application base directory reachable | Directory exists via SSH or local |
| Application process count | ≥ `FLASHBACK_LOAD_TEST_MIN_APP_PROCESSES` (default 3) |
| RUN, PATCH, NE filesystem paths | All three directories exist |
| Free space | ≥ `FLASHBACK_LOAD_TEST_MIN_FREE_GB` GB (default 50) |
| Configured URLs (if set) | HTTP 2xx or 3xx response |
| Database open mode | `READ WRITE` |
| PDB open mode | `READ WRITE` |
| Invalid objects | 0 invalid objects (warn if > 0) |
| Blocking sessions | 0 blocking sessions |
| Alert log scan | No ORA-/TNS-/error entries in last 300 lines (warn if found) |

Exits 1 if any FAIL. Exits 0 with warning summary if only WARNs.

---

### Option 6 — Delete Stored Config

Removes `~/.flashback_env`. The next menu interaction will prompt for all configuration from scratch.

> To reset filesystem role detection only (without clearing all config), manually delete `~/.flashback_app_info` on the server.

---

### Option 7 — View Backup / Restore Job Status

Reads `~/.flashback_restore_pid` and shows:
- PID of each launched restore job
- Status: RUNNING or DONE (based on whether the PID still exists)
- Last 15 lines of the most recent restore log

---

## Script Reference

### `scripts/oracle_flashback_menu.sh`

The operator-facing controller and only interactive entrypoint.

Responsibilities:
- Load and save configuration (`~/.flashback_env`, `~/.flashback_app_info`)
- Display the numbered interactive menu
- Orchestrate the service-check and password-validation flow for Options 2 and 3
- Call worker scripts for each workflow step
- Restart application services when the request flow stopped them
- Collect restore-point and backup-tag selections interactively (foreground)
- Launch detached restore and track its PID/log

Key functions:

| Function | Purpose |
|---|---|
| `load_or_prompt_config` | Load env file; detect or prompt for all config values; save to env file |
| `reload_app_info` | Source `~/.flashback_app_info`; export FS roles and stop-state flag |
| `persist_app_info` | Write current FS roles and stop-state flag to `~/.flashback_app_info` |
| `validate_apps_password` | Prompt for password silently if not set; validate via sqlplus; cache or clear on result |
| `make_flashback_request` | Option 2 orchestrator |
| `restore_flashback` | Option 3 foreground orchestrator |
| `view_restore_status` | Option 7 status display |

---

### `scripts/oracle/detect_environment.sh`

Queries `/ as sysdba` for:
- Instance name (`INSTANCE_ID`)
- DB host (`DB_HOST`)
- Alert log path (`ALERT_LOG`)
- Default read-write PDB (`PDB_NAME`)

Output is a set of `KEY="value"` lines parsed by the menu.

---

### `scripts/oracle/capture_app_info.sh`

Runs during Make Flashback Request (Stage 1).

Key behaviour:
- If `FLASHBACK_RUN_FS` and `FLASHBACK_PATCH_FS` are already exported (from a previous session's `~/.flashback_app_info`), **skips detection entirely** and uses the persisted values.
- Otherwise tries: XML `s_file_edition_type` → `EBSapps.env` symlink → interactive operator prompt.
- Confirmed/detected roles are saved to `~/.flashback_app_info` and persist across sessions.
- The service-state decision is controlled by `FLASHBACK_SKIP_SERVICE_PROMPT` exported by the menu; the script never asks for shutdown independently when the menu has already handled it.

---

### `scripts/oracle/create_flashback_restore_point.sh`

Creates guaranteed restore points. Key details:
- Verifies `ARCHIVELOG` and `FLASHBACK_ON=YES` before issuing any DDL.
- Uses `set +e` around the CREATE sqlplus call so ORA- errors are always captured and printed to the operator before the script exits.
- If sqlplus fails, diagnostic hints are shown (ORA-38778 = name exists, ORA-01031 = privileges, ORA-01261 = FRA space).
- Default naming: `{INSTANCE_ID}_CDB_flashback_restore_{DDMonYY_HHmm}` — the `_HHmm` prevents same-day collisions.

---

### `scripts/oracle/create_backup.sh`

Launches background tar jobs. Key details:
- Supports local and remote (SSH) application nodes.
- Verifies backup directory is writable and app base directory exists before starting.
- Tar jobs run under `nohup` on the application node; the script exits after launching them.

---

### `scripts/oracle/stop_app_services.sh`

Stops EBS services. Key details:
- Counts processes, skips if already zero.
- Locates `adstpall.sh` under `APP_BASE_DIR` if not on PATH.
- Pipes credentials (APPS user/password, WebLogic password) to stdin.
- Waits up to **20 minutes** (40 × 30 s) for all EBS processes to stop.
- Exits 1 if processes are still running after timeout.

---

### `scripts/oracle/restore_flashback.sh`

Detached restore orchestrator. Runs fully non-interactive. Calls:

1. `restore_backup.sh` — filesystem restore
2. `flashback_database.sh` — DB flashback
3. `start_app_services.sh` — service restart

All output goes to `logs/restore_flashback_{timestamp}.log`.

---

### `scripts/oracle/restore_backup.sh`

Restores application filesystems. Key details:
- Detects latest backup date tag automatically if not provided.
- Checks minimum free space (`FLASHBACK_MIN_RESTORE_FREE_GB`, default 250 GB).
- Renames existing directories aside (e.g. `fs1` → `fs1_run_20260515_113300`). **Does not delete anything.**
- Runs all three tar extract jobs in parallel with `nohup`, then `wait`s for all to complete.

---

### `scripts/oracle/flashback_database.sh`

Flashes back CDB and PDB. Key details:
- Verifies both restore points exist before touching the database.
- RAC-aware: sets `cluster_database=FALSE` via SPFILE, stops all instances via `srvctl`, starts single-instance for flashback.
- Flashes back PDB first (CLOSE IMMEDIATE → FLASHBACK → OPEN RESETLOGS).
- Flashes back CDB (SHUTDOWN IMMEDIATE → STARTUP MOUNT → FLASHBACK → OPEN RESETLOGS).
- Opens PDB after CDB flashback.
- **Restore points are NOT dropped** — they remain in `V$RESTORE_POINT` after the operation.
- Verifies final database and PDB open mode before exiting.
- After RAC flashback: restores `cluster_database=TRUE` and restarts via `srvctl`.

---

### `scripts/oracle/start_app_services.sh`

Starts EBS services. Key details:
- Locates `adstrtal.sh` under `APP_BASE_DIR` if not on PATH.
- Pipes credentials to stdin.
- Waits up to 10 minutes (20 × 30 s) for processes to appear.
- Exits 1 with a WARNING (not a hard failure) if no processes are detected — restore continues.

---

### `scripts/oracle/validate_load_test_ready.sh`

Post-restore readiness validation. Records each check as PASS / WARN / FAIL. Exits 1 if any check FAILs.

---

## Filesystem Role Persistence

RUN/PATCH/NE filesystem paths are detected once and cached in `~/.flashback_app_info`. On every subsequent run — including new SSH sessions — those cached values are loaded at menu startup and passed to `capture_app_info.sh`, which skips all detection methods when the values are already available.

Detection priority:
1. Values in `~/.flashback_app_info` (loaded at startup by `reload_app_info`)
2. EBS context XML (`s_file_edition_type` attribute)
3. `EBSapps.env` symlink target
4. Interactive operator prompt (stored after confirmation)

---

## APPS Password Handling

The APPS password is **never prompted at config time**. It is collected silently (using `read -s`) on first use of Option 2 or Option 3, validated via sqlplus, and then persisted to `~/.flashback_env`. If validation fails, the cached password is cleared so the operator is re-prompted on the next attempt.

---

## Logging Model

Each script writes to a shared log file (`logs/flashback_execution.log`) and to a per-run log for detached operations.

All major operations are bracketed with START/END markers:

```
[START] Operation name : YYYY-MM-DD HH:MM:SS
...
[END] Operation name : YYYY-MM-DD HH:MM:SS
```

Detached restore operations write to a separate timestamped log:
```
logs/restore_flashback_YYYYMMDD_HHMMSS.log
```

---

## Failure Model

Scripts use `set -eu` (exit on error, unset variable). The following conditions cause hard exits:

| Condition | Script | Exit code |
|---|---|---|
| `sqlplus` not on PATH | multiple | 3 |
| DB not in ARCHIVELOG | create_flashback_restore_point | 3 |
| FLASHBACK_ON ≠ YES | create_flashback_restore_point | 3 |
| sqlplus ORA- error during CREATE RESTORE POINT | create_flashback_restore_point | 1 |
| Restore point not found in V$RESTORE_POINT | flashback_database | 1 |
| Application stop timeout | stop_app_services | 1 |
| Tar restore failure | restore_backup | 1 |
| Insufficient free space | restore_backup | 1 |
| App base directory missing | restore_backup | 3 |

Where a failure can be logged as a warning without blocking the workflow, scripts use `record_warn` (validate_load_test_ready) or `|| true` with explicit log messages.

---

## Suggested Operational Sequence

```
1. Start the menu on the DB server.
2. Confirm or update environment values.
3. Option 2 — Make Flashback Request  (before any reversible activity)
4. Perform the external load test or change.
5. Option 3 — Restore Flashback  (if rollback is required)
6. Option 4 — Validate system ready for Load Test  (after restore)
7. Option 1 — View Flashback  (to confirm restore points still exist)
```
