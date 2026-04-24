# Oracle Flashback Automation v2.0.0

> Python GUI + CLI wrapper that safely orchestrates Oracle Flashback Database operations via operator-owned shell scripts.

---

## Design Principles

| Layer | Responsibility |
|---|---|
| **Python (GUI / CLI)** | Confirmation gates, pre-flight checks, logging, email, UX |
| **Shell scripts (`.sh`)** | All SSH / Oracle SQLPlus / RMAN / tar operations |

Python never touches Oracle directly. The shell scripts are fully client-owned and replaceable.

---

## What Works in v2.0.0

| Feature | Status |
|---|---|
| Tkinter GUI (dark-themed, colour-coded output) | ✅ |
| CLI modes: `--dry-run` / `--execute` / `--test-connectivity` | ✅ |
| Dual-YES confirmation gates (GUI dialogs + CLI prompts) | ✅ |
| Restore point type-to-confirm (GUI + CLI) | ✅ |
| Pre-flight validation before every execute workflow | ✅ |
| Config validation on startup (warns on bad config.json) | ✅ |
| Abort button (SIGTERM + SIGKILL with 5s grace) | ✅ |
| Structured logging with run_id, operator, hostname | ✅ |
| Log rotation (max_log_files configurable) | ✅ |
| Email notification on workflow completion | ✅ |
| Demo mode (offline, restore points from JSON) | ✅ |
| Shell detection: Git Bash / WSL / POSIX sh | ✅ |
| Per-script timeout | ✅ |
| Unit tests (pytest) | ✅ |

---

## Prerequisites

- Python 3.9+
- To run `.sh` scripts on Windows:
  - Git for Windows (Git Bash) — **recommended**, or
  - WSL (`wsl.exe`)
- To run tests: `pip install pytest`

---

## Run

**Windows GUI:**
```
flashback\run_gui.bat
```
or from PowerShell:
```powershell
python .\flashback\flashback_gui.py
```

**From sh (Linux / macOS / WSL / Git Bash):**
```sh
sh ./flashback/flashback.sh gui               # Launch GUI
sh ./flashback/flashback.sh dry-run           # CLI dry-run
sh ./flashback/flashback.sh execute           # CLI execute
sh ./flashback/flashback.sh test-connectivity # Test SSH + DB
```

---

## Configure

1. Copy `config.example.json` → `config.json`
2. Edit values for your environment:

```json
{
  "shell_mode": "bash",
  "bash_path": "C:/Program Files/Git/bin/bash.exe",
  "operator_id": "jsmith",
  "demo": { "enabled": false },
  "preflight": {
    "run_connectivity_before_execute": true,
    "abort_on_connectivity_failure": true
  },
  "scripts": {
    "test_connectivity": "scripts/test_connectivity.sh",
    "create_backup":     "scripts/create_backup.sh",
    "restore_backup":    "scripts/restore_backup.sh",
    "create_flashback":  "scripts/create_flashback_restore_point.sh",
    "flashback_restore": "scripts/flashback_to_restore_point.sh"
  },
  "email": {
    "enabled": true,
    "smtp_host": "smtp.example.com",
    "smtp_port": 587,
    "smtp_user": "flashback@example.com",
    "smtp_password": "secret",
    "from_addr": "flashback@example.com",
    "to_addrs": ["dba@example.com"],
    "use_tls": true
  },
  "timeout": {
    "script_timeout_secs": 3600,
    "connectivity_timeout_secs": 30
  }
}
```

---

## Configure Shell Scripts

The 5 scripts under `scripts/` are **production-grade templates**. Edit them to target your environment:

| Script | Called by | Purpose |
|---|---|---|
| `test_connectivity.sh` | Test Connectivity | SSH probe + sqlplus ping |
| `create_backup.sh` | Create + Restore workflows | tar.gz snapshot of app filesystems |
| `create_flashback_restore_point.sh` | Create workflow | `CREATE RESTORE POINT ... GUARANTEE FLASHBACK DATABASE` on CDB + PDB |
| `restore_backup.sh` | Restore workflow | Extract most recent tar.gz archives |
| `flashback_to_restore_point.sh` | Restore workflow | `FLASHBACK DATABASE TO RESTORE POINT` + RESETLOGS + open PDB |

**Configuration is via environment variables** set in each script's header block:

```sh
FLASHBACK_DB_HOST    db-prod.corp.com
FLASHBACK_DB_PORT    1521
FLASHBACK_DB_SERVICE ORCL
FLASHBACK_PDB_NAME   MYPDB
FLASHBACK_DB_USER    sys
FLASHBACK_DB_PASS    (use wallet for production)
FLASHBACK_APP_NODES  appnode1 appnode2
FLASHBACK_SSH_USER   oracle
FLASHBACK_SSH_KEY    /home/oracle/.ssh/flashback_key
FLASHBACK_BACKUP_DIR /backup/flashback
FLASHBACK_FS_LIST    /fs_ne /fs1 /fs2
```

---

## Run Tests

```sh
cd flashback
python -m pytest tests/ -v
```

---

## File Structure

```
flashback/
├── flashback_gui.py             # GUI entrypoint
├── flashback_automation.py      # CLI entrypoint
├── flashback.sh                 # POSIX launcher
├── run_gui.bat                  # Windows GUI launcher
├── config.example.json          # Config template
├── HANDOVER.md                  # Client delivery guide
│
├── flashback_app/               # Python package
│   ├── config.py                # Full config loader
│   ├── confirm.py               # Confirmation dialogs
│   ├── demo_data.py             # Demo JSON loader
│   ├── email_notify.py          # SMTP email (non-blocking)
│   ├── logging_utils.py         # Structured logging + rotation
│   ├── shell_runner.py          # Script execution + abort + timeout
│   ├── ui.py                    # Tkinter GUI
│   ├── validators.py            # Pre-flight config + script checks
│   └── workflows.py             # Dry-run step definitions
│
├── scripts/                     # .sh script templates (client edits these)
│   ├── test_connectivity.sh
│   ├── create_backup.sh
│   ├── create_flashback_restore_point.sh
│   ├── restore_backup.sh
│   └── flashback_to_restore_point.sh
│
├── demo/                        # Demo mode fixtures
│   ├── restore_points.json
│   └── active_sessions.json
│
└── tests/                       # Unit tests (pytest)
    ├── test_config.py
    ├── test_shell_runner.py
    ├── test_validators.py
    └── test_workflows.py
```
