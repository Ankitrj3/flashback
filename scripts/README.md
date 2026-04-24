# Oracle Flashback Automation — Scripts Directory

This directory contains all launcher, packager, and Oracle shell scripts.

---

## Directory Layout

```
scripts/
├── oracle/                          ← Oracle DB / SSH operational scripts
│   ├── test_connectivity.sh         ← Verify DB and SSH connectivity
│   ├── create_backup.sh             ← Parallel nohup tar of EBS filesystems
│   ├── create_flashback_restore_point.sh  ← Create CDB + PDB guaranteed restore points
│   ├── list_restore_points.sh       ← Query live V$RESTORE_POINT (JSON output)
│   ├── restore_backup.sh            ← Restore .tar archives to app nodes
│   ├── flashback_to_restore_point.sh ← FLASHBACK DATABASE + RESETLOGS + open PDBs
│   └── shutdown_app_services.sh     ← SSH to all nodes, stop EBS services
├── flashback.sh                     ← Main POSIX launcher (gui / dry-run / execute)
├── run_gui.sh                       ← POSIX alias: launches GUI via flashback.sh
├── run_cli.sh                       ← POSIX alias: launches CLI via flashback.sh
├── run_gui.bat                      ← Windows native GUI launcher
├── package.sh                       ← Linux/macOS: create client delivery archive
└── package.ps1                      ← Windows PowerShell: create client delivery zip
```

---

## Launcher Scripts

### `flashback.sh` — Main Entrypoint (POSIX)

Run from the project root:

```sh
sh scripts/flashback.sh gui               # Launch Tkinter GUI
sh scripts/flashback.sh dry-run           # CLI dry-run (no DB operations)
sh scripts/flashback.sh execute           # CLI execute (real DB operations)
sh scripts/flashback.sh test-connectivity # Run connectivity test script
```

### `run_gui.sh` / `run_cli.sh`

Convenience aliases — equivalent to `flashback.sh gui` and `flashback.sh`:

```sh
sh scripts/run_gui.sh
sh scripts/run_cli.sh --dry-run
```

### `run_gui.bat` — Windows GUI Launcher

Double-click or run from CMD/PowerShell:

```bat
scripts\run_gui.bat
```

---

## Oracle Scripts (`oracle/`)

All scripts are invoked by Python via `ShellRunner`. They receive configuration
through environment variables set by the Python layer.

### Environment Variables (set by Python)

| Variable | Description |
|---|---|
| `FLASHBACK_DEMO` | `true` = run in simulation mode (no real DB ops) |
| `FLASHBACK_INSTANCE_ID` | e.g. `RXEST01` |
| `FLASHBACK_ORACLE_ENV` | Path to Oracle env file (e.g. `rxecst01.sh`) |
| `FLASHBACK_DB_AUTH` | `os` or `network` |
| `FLASHBACK_PDB_NAME` | PDB container name (e.g. `RXEST01`) |
| `FLASHBACK_APP_NODES` | Space-separated app node hostnames |
| `FLASHBACK_SSH_USER` | SSH username (e.g. `oracle`) |
| `FLASHBACK_SSH_KEY` | Path to SSH private key |
| `FLASHBACK_APP_BASE_DIR` | Base dir on app node (e.g. `/db8000/app/oracle/r122rxest01`) |
| `FLASHBACK_BACKUP_DIR` | Backup destination (e.g. `/iriscommon/backups/tars`) |
| `FLASHBACK_FS_LIST` | Space-separated filesystem names (e.g. `fs_ne fs1 fs2`) |

### Script Execution Order

**Create Flashback Workflow:**
1. `create_backup.sh` — backup current filesystem state
2. `create_flashback_restore_point.sh` — create guaranteed DB restore point

**Restore Flashback Workflow:**
1. `shutdown_app_services.sh` — SSH all nodes, stop EBS services
2. `create_backup.sh` — safety snapshot before restore
3. `restore_backup.sh <RESTORE_POINT>` — extract archives to app nodes
4. `flashback_to_restore_point.sh <RESTORE_POINT>` — FLASHBACK DATABASE + RESETLOGS

**Utility:**
- `test_connectivity.sh` — verify Oracle DB + SSH connectivity
- `list_restore_points.sh` — list available V$RESTORE_POINT entries

---

## Packaging Scripts

### `package.ps1` (Windows PowerShell)

Creates a timestamped `.zip` for client delivery. Run from `scripts/`:

```powershell
PowerShell -ExecutionPolicy Bypass -File scripts\package.ps1
```

Output: `../flashback_YYYYMMDD_HHMMSS.zip`

### `package.sh` (Linux/macOS)

```sh
sh scripts/package.sh
```

Output: `flashback_YYYYMMDD_HHMMSS.zip` (or `.tar.gz` if zip not available)

**Both exclude:** `logs/`, `tests/`, `config.json`, `__pycache__/`, `.pytest_cache/`
