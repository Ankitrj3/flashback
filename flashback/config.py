from __future__ import annotations

"""
config.py — Configuration loader with full schema support.

Reads `config.json` from the project root directory and merges it with
safe defaults. The returned AppConfig is the single source of truth for
all settings used by the GUI, CLI, and shell runner.

Sections in config.json (v2.1 — aligned with client RXEST01 environment):
  - shell_mode / bash_path     : how to invoke .sh scripts
  - operator_id                : name logged with every action
  - oracle                     : DB connection (env file, auth mode, host, PDB)
  - instance_id                : prefix used in restore-point naming (e.g. RXEST01)
  - app                        : application nodes, base dir, SSH settings
  - backup                     : backup directory and filesystem list
  - demo                       : demo/dry-run mode settings
  - scripts                    : paths to all operational scripts
  - preflight                  : auto-run connectivity before execute
  - email                      : SMTP notification settings
  - logging                    : log directory and rotation
  - timeout                    : per-script and connectivity timeouts
"""

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Dataclasses (one per config section)
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class OracleConfig:
    """
    Oracle database connection settings.

    auth_mode = "os"      : connect as 'sqlplus / as sysdba'  (OS authentication)
                            Requires the tool to run on the DB server or via SSH.
    auth_mode = "network" : connect as 'user/pass@host:port/service as sysdba'
                            Requires FLASHBACK_DB_HOST, FLASHBACK_DB_USER, FLASHBACK_DB_PASS.
    """
    env_file: str          # Path to the Oracle env sourcing script (e.g. rxecst01.sh)
    auth_mode: str         # "os" (default) or "network"
    db_host: str           # Oracle DB hostname (network mode only)
    db_port: str           # Listener port, default "1521"
    db_service: str        # CDB service name (network mode only)
    pdb_name: str          # PDB name for ALTER SESSION SET CONTAINER (e.g. RXEST01)
    db_user: str           # DB username, default "sys"
    db_pass: str           # DB password (leave blank for OS auth or wallet)


@dataclass(frozen=True)
class AppNodeConfig:
    """
    Application server node settings for SSH operations (EBS app nodes).
    The tool SSHes to these nodes to backup filesystems and shutdown services.
    """
    nodes: list[str]       # List of app node hostnames, e.g. ["node2","node3"]
    ssh_user: str          # SSH username (e.g. "oracle")
    ssh_key: str           # Path to SSH private key (empty = use default key)
    base_dir: str          # Base directory on app node, e.g. /db8000/app/oracle/r122rxest01


@dataclass(frozen=True)
class BackupConfig:
    """
    Filesystem backup configuration matching client's environment.
    Filesystems are relative names under app.base_dir (e.g. fs_ne, fs1, fs2).
    """
    dir: str               # Backup destination, e.g. /iriscommon/backups/tars
    filesystems: list[str] # Relative names: ["fs_ne", "fs1", "fs2"]


@dataclass(frozen=True)
class DemoConfig:
    """Settings for demo / offline mode."""
    enabled: bool
    restore_points_file: Path
    sessions_file: Path
    soa_action: str        # "WARN" | "BLOCK"


@dataclass(frozen=True)
class PreflightConfig:
    """Controls whether pre-flight checks run automatically before execute."""
    run_connectivity_before_execute: bool = True
    abort_on_connectivity_failure: bool = True


@dataclass(frozen=True)
class EmailConfig:
    """SMTP notification settings. Matches email_notify.EmailConfig interface."""
    enabled: bool = False
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    from_addr: str = ""
    to_addrs: list[str] = field(default_factory=list)
    subject_prefix: str = "[FLASHBACK] "
    use_tls: bool = True


@dataclass(frozen=True)
class LoggingConfig:
    """Log file settings."""
    log_dir: str = "logs"      # relative to root_dir
    max_log_files: int = 30    # oldest files pruned when exceeded


@dataclass(frozen=True)
class TimeoutConfig:
    """Per-operation timeout values (seconds). 0 = no timeout."""
    script_timeout_secs: int = 7200    # 2 hours (large EBS tars take time)
    connectivity_timeout_secs: int = 30


@dataclass(frozen=True)
class AppConfig:
    """Complete application configuration."""
    root_dir: Path
    shell_mode: str                  # "auto" | "bash" | "wsl"
    bash_path: str | None            # explicit path to bash.exe (Windows)
    operator_id: str                 # operator name/ID for audit logging
    tool_version: str                # set in code, not config.json
    instance_id: str                 # DB/env identifier, e.g. "RXEST01"
    oracle: OracleConfig
    app: AppNodeConfig
    backup: BackupConfig
    demo: DemoConfig
    preflight: PreflightConfig
    scripts: dict[str, Path]
    email: EmailConfig
    logging: LoggingConfig
    timeout: TimeoutConfig


# ---------------------------------------------------------------------------
# Tool version — single place to bump
# ---------------------------------------------------------------------------

TOOL_VERSION = "2.1.0"


# ---------------------------------------------------------------------------
# Defaults (safe for demo / first-run)
# ---------------------------------------------------------------------------

def _default_config(root_dir: Path) -> AppConfig:
    """Return a fully-populated AppConfig with safe defaults."""
    return AppConfig(
        root_dir=root_dir,
        shell_mode="auto",
        bash_path=None,
        operator_id=os.environ.get("USERNAME", os.environ.get("USER", "")),
        tool_version=TOOL_VERSION,
        instance_id="RXEST01",
        oracle=OracleConfig(
            env_file="",
            auth_mode="os",
            db_host="",
            db_port="1521",
            db_service="",
            pdb_name="RXEST01",
            db_user="sys",
            db_pass="",
        ),
        app=AppNodeConfig(
            nodes=[],
            ssh_user="oracle",
            ssh_key="",
            base_dir="/db8000/app/oracle/r122rxest01",
        ),
        backup=BackupConfig(
            dir="/iriscommon/backups/tars",
            filesystems=["fs_ne", "fs1", "fs2"],
        ),
        demo=DemoConfig(
            enabled=True,
            restore_points_file=root_dir / "tests" / "fixtures" / "restore_points.json",
            sessions_file=root_dir / "tests" / "fixtures" / "active_sessions.json",
            soa_action="WARN",
        ),
        preflight=PreflightConfig(
            run_connectivity_before_execute=True,
            abort_on_connectivity_failure=True,
        ),
        scripts={
            "test_connectivity":    root_dir / "scripts" / "oracle" / "test_connectivity.sh",
            "shutdown_app_services": root_dir / "scripts" / "oracle" / "shutdown_app_services.sh",
            "list_restore_points":  root_dir / "scripts" / "oracle" / "list_restore_points.sh",
            "create_backup":        root_dir / "scripts" / "oracle" / "create_backup.sh",
            "restore_backup":       root_dir / "scripts" / "oracle" / "restore_backup.sh",
            "create_flashback":     root_dir / "scripts" / "oracle" / "create_flashback_restore_point.sh",
            "flashback_restore":    root_dir / "scripts" / "oracle" / "flashback_to_restore_point.sh",
        },
        email=EmailConfig(),
        logging=LoggingConfig(),
        timeout=TimeoutConfig(),
    )


# ---------------------------------------------------------------------------
# Loader
# ---------------------------------------------------------------------------

def load_config(root_dir: Path) -> AppConfig:
    """
    Load config.json from root_dir and merge with defaults.

    If config.json doesn't exist, returns the default config (safe for
    first-run and demo mode).

    Args:
        root_dir: Project root directory (parent of flashback/ package).

    Returns:
        Populated AppConfig. Never raises — invalid values are replaced with
        defaults and should be caught by validators.validate_config().
    """
    cfg_path = root_dir / "config.json"
    defaults = _default_config(root_dir)

    if not cfg_path.exists():
        return defaults

    try:
        raw: dict[str, Any] = json.loads(cfg_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        import logging as _logging
        _logging.warning("config.json could not be parsed (%s); using defaults.", exc)
        return defaults

    # ---- top-level scalars ----
    shell_mode  = str(raw.get("shell_mode", "auto")).strip() or "auto"
    bash_path   = str(raw.get("bash_path", "")).strip() or None
    operator_id = str(raw.get("operator_id", defaults.operator_id)).strip()
    instance_id = str(raw.get("instance_id", defaults.instance_id)).strip() or "RXEST01"

    # ---- oracle ----
    oc = raw.get("oracle", {}) or {}
    oracle = OracleConfig(
        env_file=str(oc.get("env_file", defaults.oracle.env_file)).strip(),
        auth_mode=_coerce_auth_mode(str(oc.get("auth_mode", "os"))),
        db_host=str(oc.get("db_host", defaults.oracle.db_host)).strip(),
        db_port=str(oc.get("db_port", defaults.oracle.db_port)).strip() or "1521",
        db_service=str(oc.get("db_service", defaults.oracle.db_service)).strip(),
        pdb_name=str(oc.get("pdb_name", defaults.oracle.pdb_name)).strip() or "RXEST01",
        db_user=str(oc.get("db_user", defaults.oracle.db_user)).strip() or "sys",
        db_pass=str(oc.get("db_pass", defaults.oracle.db_pass)).strip(),
    )

    # ---- app nodes ----
    ap = raw.get("app", {}) or {}
    nodes_raw = ap.get("nodes", defaults.app.nodes)
    if isinstance(nodes_raw, str):
        nodes_raw = [n.strip() for n in nodes_raw.split(",") if n.strip()]
    app = AppNodeConfig(
        nodes=[str(n).strip() for n in (nodes_raw or []) if str(n).strip()],
        ssh_user=str(ap.get("ssh_user", defaults.app.ssh_user)).strip() or "oracle",
        ssh_key=str(ap.get("ssh_key", defaults.app.ssh_key)).strip(),
        base_dir=str(ap.get("base_dir", defaults.app.base_dir)).strip(),
    )

    # ---- backup ----
    bk = raw.get("backup", {}) or {}
    fs_raw = bk.get("filesystems", defaults.backup.filesystems)
    if isinstance(fs_raw, str):
        fs_raw = [f.strip() for f in fs_raw.split(",") if f.strip()]
    backup = BackupConfig(
        dir=str(bk.get("dir", defaults.backup.dir)).strip() or "/iriscommon/backups/tars",
        filesystems=[str(f).strip() for f in (fs_raw or []) if str(f).strip()],
    )

    # ---- demo ----
    d = raw.get("demo", {}) or {}
    demo = DemoConfig(
        enabled=bool(d.get("enabled", True)),
        restore_points_file=(
            root_dir / str(d.get("restore_points_file", "tests/fixtures/restore_points.json"))
        ).resolve(),
        sessions_file=(
            root_dir / str(d.get("sessions_file", "tests/fixtures/active_sessions.json"))
        ).resolve(),
        soa_action=_coerce_soa(str(d.get("soa_action", "WARN"))),
    )

    # ---- preflight ----
    pf = raw.get("preflight", {}) or {}
    preflight = PreflightConfig(
        run_connectivity_before_execute=bool(
            pf.get("run_connectivity_before_execute", True)
        ),
        abort_on_connectivity_failure=bool(
            pf.get("abort_on_connectivity_failure", True)
        ),
    )

    # ---- scripts ----
    scripts_raw = raw.get("scripts", {}) or {}
    scripts: dict[str, Path] = {}
    for key, rel in scripts_raw.items():
        scripts[str(key)] = (root_dir / str(rel)).resolve()
    for k, p in defaults.scripts.items():
        scripts.setdefault(k, p)

    # ---- email ----
    em = raw.get("email", {}) or {}
    to_addrs_raw = em.get("to_addrs", [])
    if isinstance(to_addrs_raw, str):
        to_addrs_raw = [to_addrs_raw]
    email = EmailConfig(
        enabled=bool(em.get("enabled", False)),
        smtp_host=str(em.get("smtp_host", "")).strip(),
        smtp_port=int(em.get("smtp_port", 587)),
        smtp_user=str(em.get("smtp_user", "")).strip(),
        smtp_password=str(em.get("smtp_password", "")).strip(),
        from_addr=str(em.get("from_addr", "")).strip(),
        to_addrs=[str(a).strip() for a in to_addrs_raw if str(a).strip()],
        subject_prefix=str(em.get("subject_prefix", "[FLASHBACK] ")),
        use_tls=bool(em.get("use_tls", True)),
    )

    # ---- logging ----
    lg = raw.get("logging", {}) or {}
    logging_cfg = LoggingConfig(
        log_dir=str(lg.get("log_dir", "logs")).strip() or "logs",
        max_log_files=max(1, int(lg.get("max_log_files", 30))),
    )

    # ---- timeout ----
    to = raw.get("timeout", {}) or {}
    timeout = TimeoutConfig(
        script_timeout_secs=max(0, int(to.get("script_timeout_secs", 7200))),
        connectivity_timeout_secs=max(1, int(to.get("connectivity_timeout_secs", 30))),
    )

    return AppConfig(
        root_dir=root_dir,
        shell_mode=shell_mode,
        bash_path=bash_path,
        operator_id=operator_id,
        tool_version=TOOL_VERSION,
        instance_id=instance_id,
        oracle=oracle,
        app=app,
        backup=backup,
        demo=demo,
        preflight=preflight,
        scripts=scripts,
        email=email,
        logging=logging_cfg,
        timeout=timeout,
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _coerce_soa(value: str) -> str:
    """Normalise and validate soa_action; default to WARN on invalid input."""
    v = value.strip().upper()
    return v if v in ("WARN", "BLOCK") else "WARN"


def _coerce_auth_mode(value: str) -> str:
    """Normalise db_auth_mode; default to 'os' on invalid input."""
    v = value.strip().lower()
    return v if v in ("os", "network") else "os"
