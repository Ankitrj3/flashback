# Oracle Flashback Automation — Complete Developer & Operator Guide

> **Who is this for?**
> A new developer, DBA, or operator who has never seen this codebase before and needs to
> understand how it works, how to run it, how to test it, and how everything connects.

---

## Table of Contents

1. [What This Tool Does](#1-what-this-tool-does)
2. [Architecture — The Two Layers](#2-architecture--the-two-layers)
3. [Project File Structure](#3-project-file-structure)
4. [How to Run It](#4-how-to-run-it)
5. [Configuration (config.json) Explained](#5-configuration-configjson-explained)
6. [GUI Walkthrough — Button by Button](#6-gui-walkthrough--button-by-button)
7. [CREATE Workflow — What Happens Step by Step](#7-create-workflow--what-happens-step-by-step)
8. [RESTORE Workflow — What Happens Step by Step](#8-restore-workflow--what-happens-step-by-step)
9. [Demo Mode Explained (Why Only 3 Restore Points?)](#9-demo-mode-explained-why-only-3-restore-points)
10. [Shell Scripts Explained](#10-shell-scripts-explained)
11. [How to Run Unit Tests](#11-how-to-run-unit-tests)
12. [How Logging Works](#12-how-logging-works)
13. [How Email Notification Works](#13-how-email-notification-works)
14. [How to Package for Client Delivery](#14-how-to-package-for-client-delivery)
15. [Common Questions and Troubleshooting](#15-common-questions-and-troubleshooting)
16. [Module Reference](#16-module-reference)

---
---

## Quick Command Reference

> Copy-paste commands for everything you need. Run all commands from `e:\Task\flashback\`.

### Setup — First Time Only

```powershell
# Install test dependency (only needed to run tests)
pip install pytest

# Create your config from the template
copy config.example.json config.json

# Edit config with your environment values
notepad config.json
```

### Run the Application

```powershell
# GUI — recommended (double-click or terminal)
python gui.py

# GUI via batch launcher (sets UTF-8 console automatically)
scripts\run_gui.bat

# CLI — dry-run only (shows steps, nothing executes — safe anytime)
python cli.py --dry-run

# CLI — execute real workflow
python cli.py --execute

# CLI — test connectivity only
python cli.py --test-connectivity

# CLI — show all options
python cli.py --help
```

### Run Tests

```powershell
# All tests — quick summary
python -m pytest tests/ -q

# All tests — verbose (shows each test name)
python -m pytest tests/ -v

# All tests — short error info on failure
python -m pytest tests/ --tb=short

# Single test FILE
python -m pytest tests/test_config.py -v
python -m pytest tests/test_workflows.py -v
python -m pytest tests/test_validators.py -v
python -m pytest tests/test_shell_runner.py -v

# Single specific TEST by name
python -m pytest tests/test_config.py::TestDefaultConfig::test_oracle_config_defaults -v
python -m pytest tests/test_workflows.py::TestDryRunRestoreSteps::test_step_count -v

# Run tests matching a keyword
python -m pytest tests/ -k "timeout" -v
python -m pytest tests/ -k "restore" -v

# Expected result on Windows:
#   71 passed, 5 skipped
#   (5 skipped = .sh execution tests, need Linux/macOS to run)
```

### Package for Client Delivery

```powershell
# Create client-ready zip (excludes logs/, tests/, __pycache__, config.json)
PowerShell -ExecutionPolicy Bypass -File scripts\package.ps1
# Output: flashback_YYYYMMDD_HHMMSS.zip
```

### Search Logs

```powershell
# List all session log files
Get-ChildItem logs\

# Find all failures across all logs
Select-String -Path "logs\*.log" -Pattern "FAILED"

# Find all logs for a specific run ID
Select-String -Path "logs\*.log" -Pattern "run:200c8e6d"

# Open the latest log file
Get-ChildItem logs\ | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | %{ notepad $_.FullName }
```

### Add a Demo Restore Point

```powershell
# Edit the demo fixture file
notepad tests\fixtures\restore_points.json
```

Add an entry in this format:
```json
{ "name": "RXEST01_CDB_flashback_restore_23APR26", "time": "23-APR-26 11.00.00 AM", "guaranteed": "YES", "storage_size": "2.4484E+12", "pdb": "NO", "con_id": "0" }
```

### Key Config Values to Set

| Key in config.json | What to set |
|---|---|
| `instance_id` | DB instance name, e.g. `RXEST01` |
| `oracle.env_file` | Full path to `rxecst01.sh` (sources Oracle env) |
| `oracle.auth_mode` | `"os"` (run on DB server) or `"network"` (remote) |
| `oracle.pdb_name` | PDB container name, e.g. `RXEST01` |
| `app.nodes` | App node list: `["node2","node3","node4","node5","node6","node7"]` |
| `app.base_dir` | EBS base path, e.g. `/db8000/app/oracle/r122rxest01` |
| `backup.dir` | Backup destination, e.g. `/iriscommon/backups/tars` |
| `demo.enabled` | `true` for demo/testing, `false` for live Oracle |
| `email.enabled` | `true` to send completion emails to the team |
| `operator_id` | Your name for the audit log, e.g. `jsmith` |

---

## 1. What This Tool Does

Oracle Flashback Automation is a **safety wrapper** for Oracle Database Flashback operations.

Instead of a DBA typing raw SQL commands directly into a database prompt (risky, error-prone),
this tool:

- Walks the operator through **multi-step confirmation gates** before any destructive action
- **Backs up application filesystems** (tar.gz archives) before touching the database
- Executes **Oracle Flashback SQL** via shell scripts
- **Streams script output** live to a GUI output panel
- **Writes a structured audit log** for every session (who, when, what)
- Optionally **emails the team** when a workflow completes or fails

```
Operator clicks button
  -> GUI shows what will happen
  -> Operator confirms (Yes/No + type "YES")
  -> Pre-flight checks run (shell available? scripts exist?)
  -> Shell scripts execute in sequence, output streamed live
  -> Audit log written
  -> Email sent
```

---

## 2. Architecture — The Two Layers

This is the most important design principle to understand:

```
PYTHON LAYER  (never touches Oracle directly)
-----------------------------------------------
  gui.py / cli.py                              <- entry points
    |
    v
  ui.py           -> GUI windows, buttons, output panel
  config.py       -> Load and validate config.json
  confirm.py      -> All confirmation dialogs
  validators.py   -> Pre-flight: is bash available? do scripts exist?
  shell_runner.py -> Run .sh files, stream output, timeout, abort
  logging_utils.py -> Structured audit log per session
  email_notify.py -> SMTP email on completion (non-blocking)
  workflows.py    -> Dry-run step text definitions
    |
    | passes args + env vars
    v
SHELL SCRIPT LAYER  (all Oracle / SSH / filesystem work here)
---------------------------------------------------------------
  scripts/oracle/test_connectivity.sh              -> SSH + sqlplus ping
  scripts/oracle/shutdown_app_services.sh          -> SSH all nodes, stop EBS services
  scripts/oracle/create_backup.sh                  -> parallel nohup tar of EBS filesystems
  scripts/oracle/create_flashback_restore_point.sh -> Oracle CREATE RESTORE POINT SQL
  scripts/oracle/list_restore_points.sh            -> query live V$RESTORE_POINT
  scripts/oracle/restore_backup.sh                 -> extract tar archives to app nodes
  scripts/oracle/flashback_to_restore_point.sh     -> FLASHBACK DATABASE SQL
```

**Rule**: Python never connects to Oracle. Shell scripts never show dialogs or write logs.
If you need to change how Oracle is accessed, edit the `.sh` files only.

---

## 3. Project File Structure

```
flashback/                           <- project root
|
+-- cli.py                           <- Launch CLI (entry point)
+-- gui.py                           <- Launch GUI (entry point)
+-- config.example.json              <- Template - copy to config.json
+-- pyproject.toml                   <- Python packaging + pytest config (PEP 517)
+-- requirements.txt                 <- Dev dependency: pytest
+-- README.md                        <- Setup and usage summary
+-- CHANGELOG.md                     <- Version history
+-- LICENSE                          <- Proprietary licence
+-- .env.example                     <- Environment variable template
|
+-- flashback/                       <- Python package (all the logic)
|   +-- __init__.py
|   +-- config.py                    <- Loads config.json, defines AppConfig dataclass
|   +-- confirm.py                   <- All Tkinter confirmation dialogs
|   +-- demo_data.py                 <- Reads tests/fixtures/*.json for demo mode
|   +-- email_notify.py              <- SMTP email sender (background thread)
|   +-- logging_utils.py             <- Per-session audit log + rotation
|   +-- shell_runner.py              <- Runs .sh files, timeout, abort
|   +-- ui.py                        <- Main GUI window (_ScriptQueue + FlashbackGUI)
|   +-- validators.py                <- Pre-flight checks
|   +-- workflows.py                 <- Dry-run step definitions
|
+-- scripts/                         <- All shell scripts
|   +-- oracle/                      <- Oracle DB / SSH operational scripts
|   |   +-- test_connectivity.sh
|   |   +-- shutdown_app_services.sh
|   |   +-- create_backup.sh
|   |   +-- create_flashback_restore_point.sh
|   |   +-- list_restore_points.sh
|   |   +-- restore_backup.sh
|   |   +-- flashback_to_restore_point.sh
|   +-- flashback.sh                 <- POSIX launcher (Linux/macOS/Git Bash)
|   +-- run_gui.sh                   <- POSIX alias for GUI
|   +-- run_cli.sh                   <- POSIX alias for CLI
|   +-- run_gui.bat                  <- Windows double-click launcher
|   +-- package.sh                   <- Linux/macOS: create client archive
|   +-- package.ps1                  <- Windows PowerShell: create client zip
|   +-- README.md                    <- Script usage + env var reference
|
+-- tests/                           <- Unit tests (pytest)
|   +-- __init__.py
|   +-- fixtures/                    <- Static JSON fixtures for demo mode
|   |   +-- restore_points.json      <- Fake restore points shown in dropdown
|   |   +-- active_sessions.json     <- Fake DB sessions for session-check demo
|   +-- test_config.py
|   +-- test_shell_runner.py
|   +-- test_validators.py
|   +-- test_workflows.py
|
+-- docs/                            <- Documentation
|   +-- DEVELOPER_GUIDE.md           <- This file
|   +-- HANDOVER.md                  <- Client delivery instructions
|   +-- oracle_flashback_v2_final.docx
|
+-- logs/                            <- Auto-created at runtime; gitignored
    +-- .gitkeep
    +-- flashback_YYYYMMDD_HHMMSS_<run_id>.log
```

---

## 4. How to Run It

### Prerequisites

| What | Where |
|---|---|
| Python 3.9+ | https://www.python.org/downloads/ (add to PATH) |
| Git for Windows | https://gitforwindows.org/ (provides Git Bash for .sh scripts) |
| pytest (tests only) | pip install pytest |

### Windows GUI (recommended)

Double-click `scripts\run_gui.bat`, OR from PowerShell:

```powershell
cd e:\Task\flashback
python gui.py
```

### Windows CLI (without GUI)

```powershell
python cli.py --dry-run          # show steps only
python cli.py --execute          # run real scripts
python cli.py --test-connectivity
python cli.py --help
```

### Linux / macOS / Git Bash

```sh
sh scripts/flashback.sh gui
sh scripts/flashback.sh dry-run
sh scripts/flashback.sh execute
sh scripts/flashback.sh test-connectivity
```

### First Time Setup

```sh
# 1. Create config
cp config.example.json config.json

# 2. Edit config.json with your settings (see Section 5)

# 3. Run
python gui.py
```

---

## 5. Configuration (config.json) Explained

`config.json` is the single source of truth for all runtime settings.
It is **gitignored** — never committed. Use `config.example.json` as the template.

```json
{
  "shell_mode": "auto",
```

`shell_mode` controls how `.sh` scripts are launched:
- `"auto"` — detects Git Bash, then WSL, then system sh automatically
- `"bash"` — use `bash_path` explicitly (required on some Windows setups)
- `"wsl"`  — use `wsl.exe` (if WSL is installed)

```json
  "bash_path": "C:/Program Files/Git/bin/bash.exe",
```

Only needed when `shell_mode = "bash"`.

```json
  "operator_id": "jsmith",
```

Written to every log line. Used for audit trail. Should be set to the
DBA's username or real name.

```json
  "demo": {
    "enabled": true,
```

`true` = demo mode ON. Scripts receive `FLASHBACK_DEMO=true` and simulate output.
`false` = production mode. Scripts run real Oracle operations.

```json
    "restore_points_file": "tests/fixtures/restore_points.json",
    "sessions_file": "tests/fixtures/active_sessions.json",
    "soa_action": "WARN"
  },
```

`soa_action`:
- `"WARN"` — show a warning if active sessions found, but allow proceed
- `"BLOCK"` — completely block the restore workflow until sessions are gone

```json
  "preflight": {
    "run_connectivity_before_execute": true,
    "abort_on_connectivity_failure": true
  },
```

When `true`, Python checks that the shell is available and all required script files
exist on disk before starting any Execute workflow.

```json
  "scripts": {
    "test_connectivity":     "scripts/oracle/test_connectivity.sh",
    "shutdown_app_services": "scripts/oracle/shutdown_app_services.sh",
    "list_restore_points":   "scripts/oracle/list_restore_points.sh",
    "create_backup":         "scripts/oracle/create_backup.sh",
    "restore_backup":        "scripts/oracle/restore_backup.sh",
    "create_flashback":      "scripts/oracle/create_flashback_restore_point.sh",
    "flashback_restore":     "scripts/oracle/flashback_to_restore_point.sh"
  },
```

Paths are relative to the project root directory. The defaults already point to
`scripts/oracle/`. Only change these if your scripts live elsewhere.

```json
  "email": {
    "enabled": false,
    "smtp_host": "",
    "smtp_port": 587,
    "smtp_user": "",
    "smtp_password": "",
    "from_addr": "flashback@example.com",
    "to_addrs": ["dba-team@example.com"],
    "subject_prefix": "[FLASHBACK] ",
    "use_tls": true
  },
  "logging": {
    "log_dir": "logs",
    "max_log_files": 30
  },
  "timeout": {
    "script_timeout_secs": 3600,
    "connectivity_timeout_secs": 30
  }
}
```

`script_timeout_secs`: if a script runs longer than this, it receives SIGTERM,
then SIGKILL after 5 seconds.

---

## 6. GUI Walkthrough — Button by Button

```
Dry-Run:  [ Create Flashback Request (Dry-Run) ]  [ Restore using Flashback GRP (Dry-Run) ]
Execute:  [ Create Flashback Request  >           ]  [ Restore using Flashback GRP  >      ]
Utility:  [ Test Connectivity ]  [ Show Restore Points ]              [ Abort ]
```

| Button | What it does |
|---|---|
| Create Flashback Request (Dry-Run) | Shows a text description of every step. Nothing executes. Safe to click anytime. |
| Restore using Flashback GRP (Dry-Run) | Same for restore. Asks you to pick a restore point so step descriptions use the correct name. |
| Create Flashback Request > | REAL — runs 2 shell scripts with 2-step confirmation. |
| Restore using Flashback GRP \> | REAL — runs 4 shell scripts with full confirmation + RP selection. |
| Test Connectivity | Runs test_connectivity.sh with 1 confirmation. |
| Show Restore Points | Prints the `tests/fixtures/restore_points.json` table to the output panel. |
| Abort | Sends SIGTERM to the running script. SIGKILL after 5s if still running. |
| Clear Output | Clears the dark output panel. |

The **dark output panel** uses colour coding:
- Blue — script start/run lines
- Teal — general info
- Green — success (exit code 0, workflow complete)
- Orange — warnings
- Red — errors

---

## 7. CREATE Workflow — What Happens Step by Step

**Click "Create Flashback Request >"**

### Step 1: Pre-flight check

Python checks:
- Is Git Bash / WSL / sh available? (shell detection from `shell_mode`)
- Do both required scripts exist on disk?
  - `scripts/oracle/create_backup.sh`
  - `scripts/oracle/create_flashback_restore_point.sh`

In DEMO mode — if scripts are missing, shows a "Proceed anyway?" dialog.
In PRODUCTION mode — fails hard with an error dialog if anything is missing.

### Step 2: Confirmation Dialog 1 (Yes / No)

A detailed dialog appears:

```
This will execute:
  Step 1/2: create_backup.sh — Backup application filesystems (tar.gz)
  Step 2/2: create_flashback_restore_point.sh — CREATE RESTORE POINT ... GUARANTEE FLASHBACK DATABASE on CDB and PDB

[DEMO MODE: Simulated output - no real DB operations]

This is a REAL database operation. Proceed?
    [Yes]  [No]
```

Clicking No cancels. Nothing has run yet.

### Step 3: Confirmation Dialog 2 (Type YES)

A text-input dialog appears:

```
Type  YES  to execute the Create Flashback workflow: [_______]
```

Operator must type exactly: `YES` (case-sensitive).
Cancel or wrong text: workflow cancelled.

### Step 4: Script 1 — create_backup.sh runs

Python calls `shell_runner.run_in_thread()` which:
- Builds the shell command (e.g. `bash.exe scripts/create_backup.sh`)
- Starts the process in a **background daemon thread**
- Every **100ms**, the GUI polls an `output_queue` and appends lines to the dark panel
- Also polls a `done_queue` — when the script exits, the result appears here

In DEMO mode (`FLASHBACK_DEMO=true` is passed as env var):

```
[create_backup] DEMO MODE: Simulating filesystem backup. Timestamp: 20260423_111819
[create_backup] DEMO: Archiving /fs_ne -> /backup/flashback/fs_ne_20260423_111819.tar.gz ...
[create_backup] DEMO: Backup complete  : fs_ne_20260423_111819.tar.gz (142 MB) (simulated)
[create_backup] DEMO: Archiving /fs1   -> /backup/flashback/fs1_20260423_111819.tar.gz ...
...
```

In REAL mode: actually creates `tar.gz` archives of your application filesystems.

If exit code != 0: red error line, workflow stops.
If exit code = 0: green `[exit] code=0  OK` appears, next script starts.

### Step 5: Script 2 — create_flashback_restore_point.sh runs

Same streaming mechanism.

In DEMO mode:

```
[create_flashback] DEMO: SQL> CREATE RESTORE POINT "GRP_20260423_111819" GUARANTEE FLASHBACK DATABASE;
[create_flashback] DEMO:   NAME                          CREATED_AT           GUARANTEE
[create_flashback] DEMO:   GRP_20260423_111819           2026-04-23 11:18:22  YES
[create_flashback] DEMO: CDB restore point created: GRP_20260423_111819 (simulated)
```

In REAL mode: connects via sqlplus as SYSDBA, creates the restore point on CDB, then PDB,
then queries `V$RESTORE_POINT` to verify it was created.

### Step 6: Completion

- Green: "Workflow completed successfully. OK"
- Status bar: "Done. OK"
- All buttons re-enabled
- Audit log line written: `Workflow 'Create Flashback Request': SUCCESS`
- Email sent in background (if `email.enabled = true`)

---

## 8. RESTORE Workflow — What Happens Step by Step

**Click "Restore using Flashback GRP >"**

### Step 1: Pre-flight check

Checks shell availability + these 4 scripts exist:
- `scripts/oracle/shutdown_app_services.sh`
- `scripts/oracle/create_backup.sh`
- `scripts/oracle/restore_backup.sh`
- `scripts/oracle/flashback_to_restore_point.sh`

### Step 2: Confirmation Dialog 1 (Yes / No)

```
This will execute:
  Step 1/3: create_backup.sh — Safety snapshot before restore
  Step 2/3: restore_backup.sh — Extract filesystem archives back
  Step 3/3: flashback_to_restore_point.sh — FLASHBACK DATABASE TO RESTORE POINT ...

WARNING: This ROLLS BACK the database. It cannot be undone.
Continue?
    [Yes]  [No]
```

### Step 3: Session check (demo mode)

Python reads `tests/fixtures/active_sessions.json`.
If active sessions found and `soa_action = "WARN"`: shows warning, allows proceed.
If `soa_action = "BLOCK"`: blocks until sessions are gone.

Example demo sessions file:

```json
[
  { "username": "SOA_APP", "status": "ACTIVE",   "program": "JDBC Thin Client" },
  { "username": "USER1",   "status": "INACTIVE",  "program": "sqlplus"         }
]
```

Output in GUI: `[demo] Session check: total=2, active=1 (soa_action=WARN)`

### Step 4: Select restore point (dropdown)

A modal window appears with a Combobox:

```
Select the restore point to flash back to:
  [FB_DEMO_20260422_1200       v]
  2 restore point(s) available
          [Cancel]  [OK]
```

In DEMO mode: options come from `tests/fixtures/restore_points.json`.
In REAL mode: operator types the restore point name in a free-text box
(no automatic lookup from Oracle — that would require a separate script).

### Step 5: Re-type restore point name

```
Re-type the restore point name to confirm:

  FB_DEMO_20260422_1200   <- shown in red bold

[__________________________]
                [Cancel]  [Confirm]
```

This prevents fat-finger mistakes on the restore target.
If the typed name does not match: a red error label appears inline.
The dialog stays open until correct or cancelled.

### Step 6: Script 1 — create_backup.sh (safety snapshot)

Identical to the CREATE workflow. Creates a backup of the **current** state
BEFORE restoring. If the restore goes wrong, this lets you recover.

### Step 7: Script 2 — restore_backup.sh

The selected restore point name is passed as argument:

```sh
bash.exe scripts/restore_backup.sh FB_DEMO_20260422_1200
```

In DEMO mode: simulates extracting 3 filesystems from archive:

```
[restore_backup] DEMO: Extracting : fs_ne_20260423_100000.tar.gz -> / (142 MB)
[restore_backup] DEMO: Extracting : fs1_20260423_100000.tar.gz -> / (89 MB)
...
```

In REAL mode: finds the most recent `.tar.gz` for each filesystem and extracts it
to the original mount point. Rolls back filesystem state.

### Step 8: Script 3 — flashback_to_restore_point.sh

Most critical script. Name passed as argument.

In DEMO mode — full simulated Oracle sequence:

```
[flashback_restore] Step 1/4: Verifying restore point 'FB_DEMO_20260422_1200'...
[flashback_restore]   NAME                    CREATED_AT           GUARANTEE
[flashback_restore]   FB_DEMO_20260422_1200   2026-04-22 12:00:00  YES
[flashback_restore] Step 2/4: Closing all PDBs...
[flashback_restore]   SQL> ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE;
[flashback_restore] Step 3/4: Executing FLASHBACK DATABASE TO RESTORE POINT ...
[flashback_restore]   SQL> FLASHBACK DATABASE TO RESTORE POINT "FB_DEMO_20260422_1200";
[flashback_restore]   SQL> ALTER DATABASE OPEN RESETLOGS;
[flashback_restore] Step 4/4: Opening all PDBs...
[flashback_restore]   CON_ID  NAME   OPEN_MODE
[flashback_restore]   2       MYPDB  READ WRITE
```

In REAL mode — actual Oracle sequence:
1. Query `V$RESTORE_POINT` to verify the restore point exists and is GUARANTEED
2. `ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE` — close PDBs
3. `FLASHBACK DATABASE TO RESTORE POINT "..."` — move DB state back in time
4. `ALTER DATABASE OPEN RESETLOGS` — mandatory after flashback
5. `ALTER PLUGGABLE DATABASE ALL OPEN` — reopen PDBs
6. Verify PDBs are in `READ WRITE` mode

### Step 9: Completion

Same as CREATE workflow — success message, log, email.

---

## 9. Demo Mode Explained (Why Only 3 Restore Points?)

### Why exactly 3 restore points appear in the dropdown

The restore points in the dropdown come from a **static JSON file**:

```
tests/fixtures/restore_points.json
```

This file has exactly 3 hardcoded entries:

```json
[
  { "name": "FB_DEMO_20260422_1200", "time": "2026-04-22 12:00:00", "guaranteed": "YES" },
  { "name": "FB_DEMO_20260421_2315", "time": "2026-04-21 23:15:00", "guaranteed": "YES" },
  { "name": "FB_DEMO_20260420_0910", "time": "2026-04-20 09:10:00", "guaranteed": "NO"  }
]
```

They are there **purely for demonstration** — to show the client what the
restore point dropdown looks like with real-looking data.

### Why doesn't "Create Flashback Request" add a new restore point to the dropdown?

In DEMO mode, when you click "Create Flashback Request", the script runs with
`FLASHBACK_DEMO=true`. It prints what SQL *would* run, but:

- It does **NOT** connect to Oracle (there is no Oracle on this machine)
- It does **NOT** write anything to `tests/fixtures/restore_points.json`
- The JSON file is a static fixture — nothing auto-updates it

In REAL mode (Oracle installed on target machine):
- The script actually creates a restore point in Oracle's `V$RESTORE_POINT`
- Python never reads `V$RESTORE_POINT` — that is the shell script's job
- The restore point selection would be enhanced by a script that queries
  `V$RESTORE_POINT` and returns the list (this is a client customisation task)

### How to add a restore point to the demo list

Edit `tests/fixtures/restore_points.json`:

```json
[
  { "name": "MY_NEW_RP_20260423_1100", "time": "2026-04-23 11:00:00", "guaranteed": "YES" },
  { "name": "FB_DEMO_20260422_1200",   "time": "2026-04-22 12:00:00", "guaranteed": "YES" },
  { "name": "FB_DEMO_20260421_2315",   "time": "2026-04-21 23:15:00", "guaranteed": "YES" }
]
```

Then click **Show Restore Points** — the new entry appears immediately.
Or click **Restore using Flashback GRP** — the dropdown will include it.

### How to disable demo mode (production)

In `config.json`:

```json
"demo": { "enabled": false }
```

With demo off:
- Session check is skipped
- Restore point dropdown replaced with free-text input
- Scripts no longer receive `FLASHBACK_DEMO=true` — they run real Oracle commands
- All `FLASHBACK_DB_HOST`, `FLASHBACK_DB_PASS`, etc. must be set in the scripts

---

## 10. Shell Scripts Explained

All 7 scripts share the same structure:

```sh
#!/usr/bin/env sh
set -eu   # exit on error; unset vars are errors

# --- DEMO MODE at the very top ---
if [ "${FLASHBACK_DEMO:-false}" = "true" ]; then
    log "DEMO MODE: ..."
    exit 0       # exit 0 = success; Python sees green "code=0 OK"
fi

# --- REAL MODE below ---
DB_HOST="${FLASHBACK_DB_HOST:-db-host.example.com}"
# ... real Oracle/SSH logic ...
```

### Environment variables used by scripts (set inside each script for production)

| Variable | Scripts | Meaning |
|---|---|---|
| `FLASHBACK_DEMO` | All | Set by GUI when demo=true. Do not edit manually. |
| `FLASHBACK_DB_HOST` | connectivity, create_flashback, flashback_restore | Oracle hostname |
| `FLASHBACK_DB_PORT` | Same | Listener port (default 1521) |
| `FLASHBACK_DB_SERVICE` | Same | CDB service name |
| `FLASHBACK_PDB_NAME` | create_flashback | PDB service name |
| `FLASHBACK_DB_USER` | Same | DBA user (sys) |
| `FLASHBACK_DB_PASS` | Same | Password (leave blank for wallet) |
| `FLASHBACK_APP_NODES` | connectivity, backups | SSH node list (space-separated) |
| `FLASHBACK_SSH_USER` | Same | SSH username |
| `FLASHBACK_SSH_KEY` | Same | Path to SSH private key |
| `FLASHBACK_BACKUP_DIR` | create_backup, restore_backup | Where tar.gz are stored |
| `FLASHBACK_FS_LIST` | create_backup, restore_backup | Filesystems to archive |

### Script exit codes

| Code | Meaning |
|---|---|
| 0 | Success — Python shows green "code=0 OK" and moves to next script |
| 1 | Operational failure (SSH fail, tar fail, SQL error) |
| 2 | Secondary failure (PDB issue, second sqlplus call failed) |
| 3 | Configuration error (backup dir missing, DB not in ARCHIVELOG) |
| 9 | Usage error (missing required argument) |

Non-zero exit always shows a red error line and stops the entire workflow.

---

## 11. How to Run Unit Tests

### Install test dependency

```powershell
pip install pytest
```

### Run all tests

```powershell
cd e:\Task\flashback
python -m pytest tests/ -v
```

### Expected output (Windows)

```
tests/test_config.py::TestDefaultConfig::test_shell_mode_is_auto PASSED
tests/test_config.py::TestDefaultConfig::test_demo_enabled_by_default PASSED
tests/test_config.py::TestDefaultConfig::test_soa_action_default_warn PASSED
...
tests/test_shell_runner.py::TestBuildCommandPosix::test_returns_list SKIPPED
tests/test_shell_runner.py::TestRunInThread::test_simple_echo_script SKIPPED
...
======================== 71 passed, 5 skipped in 5.11s
```

**Why 5 skipped?** Those tests actually execute `.sh` scripts in a subprocess.
They are marked `skipif(os.name == 'nt')` because Windows cannot run `.sh` natively
without Git Bash. They run fully on Linux/macOS.

### What each test file covers

| File | What it tests |
|---|---|
| `test_config.py` | Default values, JSON overrides, malformed JSON fallback, email/timeout section parsing, _coerce_soa helper |
| `test_shell_runner.py` | RunResult dataclass, WSL path conversion, command building, script execution (POSIX only) |
| `test_validators.py` | ValidationResult merge/error/warning, validate_config(), validate_scripts(), run_preflight() |
| `test_workflows.py` | Step count, sequential numbering, restore point in step details, Step dataclass immutability |

### Useful test commands

```powershell
# Run one file
python -m pytest tests/test_config.py -v

# Run one specific test
python -m pytest tests/test_config.py::TestConfigJsonOverrides::test_email_section_parsed -v

# Short failure info
python -m pytest tests/ --tb=short

# Quick pass/fail summary
python -m pytest tests/ -q
```

---

## 12. How Logging Works

Every time the GUI or CLI starts, `logging_utils.init_logging()` is called. It:

1. Generates a unique **run_id** (8 hex chars, e.g. `c1dade5c`)
2. Creates a new log file: `logs/flashback_20260423_112044_c1dade5c.log`
3. Writes a **structured header** to every log session:

```
========================================================================
Oracle Flashback Automation - Session Log
  Run ID    : c1dade5c
  Tool vers : 2.0.0
  Operator  : jsmith
  Hostname  : prod-server-01
  Platform  : Windows 11
  Python    : 3.13.1
  Log file  : flashback_20260423_112044_c1dade5c.log
  Started   : 2026-04-23 11:20:44
========================================================================
```

4. Every log line carries the run_id:

```
2026-04-23 11:20:44 | INFO     | [run:c1dade5c] Pre-flight check passed.
2026-04-23 11:20:46 | INFO     | [run:c1dade5c] Workflow 'Create Flashback Request': SUCCESS
```

5. **Log rotation**: when there are more than `max_log_files` (default 30) log files,
   the oldest ones are automatically deleted.

### Finding a specific run

```powershell
# List all logs
Get-ChildItem logs\

# Search for all failures across all logs
Select-String -Path "logs\*.log" -Pattern "FAILED"

# Find everything for a specific run
Select-String -Path "logs\*.log" -Pattern "run:c1dade5c"
```

---

## 13. How Email Notification Works

When a workflow completes, `email_notify.send_completion_email()` fires in a
**background daemon thread** — it never blocks the GUI.

If email sending fails, the error is **logged** but does NOT fail the workflow.

### Enable email in config.json

```json
"email": {
    "enabled": true,
    "smtp_host": "smtp.office365.com",
    "smtp_port": 587,
    "smtp_user": "flashback-tool@yourcompany.com",
    "smtp_password": "your-app-password",
    "from_addr": "flashback-tool@yourcompany.com",
    "to_addrs": ["dba-team@yourcompany.com", "ops@yourcompany.com"],
    "subject_prefix": "[FLASHBACK] ",
    "use_tls": true
}
```

- Email subject: `[FLASHBACK] Create Flashback Request -- SUCCESS`
- Body: operator, run_id, workflow name, status, timestamp
- Attachment: the session log file

---

## 14. How to Package for Client Delivery

```powershell
cd e:\Task\flashback
PowerShell -ExecutionPolicy Bypass -File scripts\package.ps1
```

Output: `e:\Task\flashback_20260423_112500.zip`

**Included**: all Python code, shell scripts, config.example.json, tests/fixtures/, README.md, docs/

**Excluded** (never shipped):
- `logs/` — runtime output, client-specific
- `config.json` — must be created by client from example
- `tests/` — dev-only
- `__pycache__/`, `_cache_tmp/`, `.cache/`, `.pytest_cache/`

### What the client does after unzipping

```
1. cp config.example.json config.json
2. Edit config.json:              set shell_mode, demo, email, operator_id
3. Edit scripts/oracle/*.sh:      set Oracle env file, SSH details, backup paths
4. Run: scripts\run_gui.bat       (Windows) OR sh scripts/flashback.sh gui (Linux)
5. Click Test Connectivity        to verify SSH + Oracle access works
6. Click Dry-Run buttons          to review what will happen
7. Click Execute buttons          to run for real
```

---

## 15. Common Questions and Troubleshooting

### Q: Why does "Create Flashback Request" not add a new restore point to the dropdown?

In demo mode, the create script only simulates — it does not update `tests/fixtures/restore_points.json`.
To add demo entries, edit that file manually. See Section 9.

### Q: The tool says "No usable shell found"

Git for Windows is not installed or not on PATH. Install it, or set `bash_path` in config.json:

```json
"shell_mode": "bash",
"bash_path": "C:/Program Files/Git/bin/bash.exe"
```

### Q: Pre-flight fails "script not found"

The paths in `scripts.*` in config.json don't resolve to actual files.
Check that paths are relative to the project root and the files exist under `scripts/oracle/`.

### Q: Second or third script never starts — workflow seems stuck after first script

This was a poll loop bug (fixed): after a script exits with code 0, `_poll()` must
re-schedule itself for the next script. Without this, the second script starts in a
background thread but the GUI never reads its output. Fixed in current code.

### Q: sqlplus not found (exit code 127)

Only happens in real mode. In demo mode this is handled by `FLASHBACK_DEMO=true`.
In production, install Oracle Instant Client and ensure `sqlplus` is on PATH.

### Q: I want to add another restore point to the demo dropdown

Edit `tests/fixtures/restore_points.json` and add a JSON object with `name`, `time`, `guaranteed`.
The GUI reads this file fresh each time the Restore dialog is opened.

### Q: I want to add a new script step to a workflow

1. Add `.sh` script to `scripts/oracle/`
2. Add its key to `config.json` under `scripts`
3. In `ui.py`, append a new tuple to the `tasks` list in `_on_create_exec()` or `_on_restore_exec()`
4. In `workflows.py`, add a new `Step` to `dry_run_create_steps()` or `dry_run_restore_steps()`

### Q: How do I change the per-script timeout?

```json
"timeout": { "script_timeout_secs": 7200 }
```

Default 3600 (1 hour). Script receives SIGTERM then SIGKILL after 5s grace.

### Q: "Flashback Database is DISABLED" error in real mode

A DBA must enable it on the Oracle instance:

```sql
-- Must be in ARCHIVELOG mode first
ALTER DATABASE FLASHBACK ON;
```

---

## 16. Module Reference

### config.py
Loads `config.json` and returns a typed `AppConfig` dataclass.

Key functions:
- `load_config(root_dir)` returns `AppConfig` — loads JSON, merges defaults, resolves script paths
- `_default_config(root_dir)` returns `AppConfig` — returns all defaults with no JSON file present

### confirm.py
All modal confirmation dialogs with proper Tkinter focus management.

Key functions:
- `confirm_yes_no(title, message)` returns `bool`
- `require_typed_value(title, prompt, expected)` returns `bool`
- `select_restore_point_from_list(title, prompt, options)` returns `str or None` — dropdown
- `confirm_retype_value(title, expected)` returns `bool` — retype with inline error label
- `confirm_restore_point_flow(options)` returns `RestoreSelection or None` — select + retype

### shell_runner.py
Launches `.sh` scripts, streams output via queues, supports timeout and abort.

Key members:
- `ShellRunner(shell_mode, bash_path)` — detects shell, manages per-instance abort state
- `ShellRunner.run_in_thread(path, args, output_q, done_q, env, timeout_secs)` — runs script in daemon thread
- `ShellRunner.abort()` — SIGTERM current process, SIGKILL after 5s
- `RunResult` — frozen dataclass with fields `exit_code`, `ok`, `aborted`, `timed_out`

### validators.py
Pre-flight checks before any execute workflow.

Key functions:
- `validate_config(cfg)` returns `ValidationResult` — checks shell_mode, soa_action, bash_path
- `validate_scripts(cfg, keys)` returns `ValidationResult` — checks scripts exist and are non-empty
- `run_preflight(cfg, keys)` returns `ValidationResult` — combined shell + script check

### logging_utils.py
One-call logging setup with run_id, structured header block, and log rotation.

Key function:
- `init_logging(log_dir, operator_id, tool_version, max_log_files)` returns `(Path, str)` — the `(log_path, run_id)` pair

### email_notify.py
Non-blocking SMTP email notification on workflow completion.

Key function:
- `send_completion_email(cfg, workflow, status, run_id, operator_id, log_path)` — fires in a background daemon thread

### workflows.py
Dry-run step text definitions. Returns lists of frozen `Step` dataclasses.

Key functions:
- `dry_run_create_steps()` returns `list[Step]` — 6 steps for the Create workflow
- `dry_run_restore_steps(restore_point)` returns `list[Step]` — 10 steps for the Restore workflow

### demo_data.py
Loads JSON fixture files for demo mode.

Key functions:
- `load_restore_points(path)` returns `list[RestorePoint]` — reads `tests/fixtures/restore_points.json`
- `load_active_sessions(path)` returns `list[dict]` — reads `tests/fixtures/active_sessions.json`
- `format_restore_points_table(points)` returns `list[str]` — ASCII table for display

### ui.py
Main GUI. Contains `FlashbackGUI` (window) and `_ScriptQueue` (executor).

Key members:
- `FlashbackGUI` — builds all widgets, handles button clicks, manages config and log init
- `_ScriptQueue` — manages sequential script execution, polls output every 100ms
- `_ScriptQueue.start(tasks, workflow_name, env)` — begin executing a task list
- `_ScriptQueue.abort()` — cancel via `ShellRunner.abort()`
- `run_gui()` — entry point: creates Tk root and calls mainloop()

---

*Zero external runtime dependencies. Pure Python standard library.*
*Tested on Python 3.9, 3.11, 3.13 on Windows 11 and Ubuntu 22.04.*
