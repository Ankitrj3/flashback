# Client Handover Guide — Oracle Flashback Automation v2.0.0

This guide explains how to deliver, configure, and validate the tool in your environment.

---

## What to Give the Client

Zip and deliver the `flashback/` folder. Contents to include:

| Path | Required |
|---|---|
| `flashback_gui.py` | ✅ Yes |
| `flashback_automation.py` | ✅ Yes |
| `flashback.sh` | ✅ Yes (Linux/macOS) |
| `run_gui.bat` | ✅ Yes (Windows) |
| `flashback_app/` | ✅ Yes (entire directory) |
| `scripts/` | ✅ Yes (with client's real script content) |
| `config.json` | ✅ Yes (filled in for client environment) |
| `config.example.json` | ✅ Yes |
| `demo/` | ✅ Recommended for initial validation |
| `tests/` | ✅ Recommended |
| `logs/` | ❌ Exclude (generated at runtime) |
| `__pycache__/` | ❌ Exclude |

---

## Client Prerequisites

**Windows:**
- Python 3.9+ (add to PATH)
- Git for Windows (Git Bash) — **required** to run `.sh` scripts

**Linux / macOS / WSL:**
- Python 3.9+
- `sh` (standard POSIX shell)

---

## Production Checklist (Client Steps)

### 1. Configure Environment

```sh
cp config.example.json config.json
```

Edit `config.json`:
- Set `shell_mode` and `bash_path` for Windows (or leave `auto` for Linux)
- Set `operator_id` to the DBA's name (for audit logging)
- Disable `demo.enabled` for production
- Fill in `email.*` section if email notifications are required

### 2. Configure Shell Scripts

Edit each script under `scripts/` and set the environment variables at the top:

| Variable | What to set |
|---|---|
| `FLASHBACK_DB_HOST` | Oracle CDB hostname |
| `FLASHBACK_DB_PORT` | Listener port (usually 1521) |
| `FLASHBACK_DB_SERVICE` | CDB service name |
| `FLASHBACK_PDB_NAME` | PDB service name |
| `FLASHBACK_DB_USER` | DBA user (sys) |
| `FLASHBACK_DB_PASS` | DBA password (use OS auth + wallet for production) |
| `FLASHBACK_APP_NODES` | Space-separated hostnames of app tier nodes |
| `FLASHBACK_SSH_USER` | SSH user for app nodes |
| `FLASHBACK_SSH_KEY` | Path to SSH private key |
| `FLASHBACK_BACKUP_DIR` | Directory to write tar archives |
| `FLASHBACK_FS_LIST` | Space-separated filesystem paths to archive |

> **Security:** Do not hard-code passwords in scripts. Use Oracle Wallet (`mkstore`) or
> OS authentication, and leave `FLASHBACK_DB_PASS` blank.

### 3. Validate Connectivity

```sh
sh flashback/flashback.sh test-connectivity
```

Or from the GUI: click **Test Connectivity**.

Expected output:
```
[test_connectivity] SSH OK    : appnode1
[test_connectivity] SSH OK    : appnode2
[test_connectivity] DB OK     : db-prod/ORCL
[test_connectivity] Flashback mode: ENABLED ✓
[test_connectivity] All connectivity checks passed.
```

### 4. Dry-Run First

```sh
sh flashback/flashback.sh dry-run
```

Review the step output carefully. This is non-destructive — nothing runs.

### 5. Execute in Staging

Before running in production, validate the full workflow in a non-production environment.

### 6. Execute in Production

From the GUI, click **Create Flashback Request (▶)** or **Restore using Flashback GRP (▶)**.

Follow the confirmation prompts carefully. You will be required to:
1. Confirm twice with YES
2. Re-type the restore point name exactly

---

## How Oracle DB Work Is Executed

The Python tool passes user inputs (such as the restore point name) as arguments to the `.sh` scripts.

```
GUI / CLI  →  config.json  →  scripts/*.sh  →  sqlplus / RMAN / SSH
```

Python never connects to Oracle. The DB connection details are embedded in the shell scripts.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Startup config warning dialog | Bad values in `config.json` | Read the dialog message and fix `config.json` |
| "No usable shell found" | Git Bash not installed or `bash_path` wrong | Install Git for Windows or set `bash_path` |
| Pre-flight fails "script not found" | `scripts.*` paths wrong in `config.json` | Fix relative path, re-check |
| `FLASHBACK_CONN_OK` not in output | sqlplus connection failed | Check DB host, port, credentials, listener status |
| "Flashback Database is DISABLED" | DB not set up for flashback | Run `ALTER DATABASE FLASHBACK ON;` as SYSDBA |
| Workflow aborted by timeout | Script exceeded `timeout.script_timeout_secs` | Increase timeout or investigate why the script is slow |
| Email not delivered | `smtp_host` unreachable or credentials wrong | Check SMTP settings; error is logged but does not fail workflow |

---

## Files the Client Should NEVER Modify

- `flashback_gui.py`
- `flashback_automation.py`
- `flashback.sh`
- `flashback_app/` (entire package)

All environment-specific configuration belongs in `config.json` and `scripts/*.sh`.
