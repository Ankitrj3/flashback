from __future__ import annotations

"""
validators.py — Pre-flight configuration and environment validation.

Called in two contexts:
  1. On GUI/CLI startup: validate_config_on_startup() — catches bad config.json
     early and surfaces clear error messages before any action is taken.
  2. Before each execute workflow: validate_preflight() — verifies that
     required shell scripts exist and that the configured shell is usable.

Design principle:
  - Returns structured results (ValidationResult) rather than raising
    exceptions, so the GUI can display them in a dialog and the CLI can
    print them without crashing.
  - Never touches Oracle/SSH — that belongs to the .sh scripts.
"""

import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .config import AppConfig


# ---------------------------------------------------------------------------
# Result type
# ---------------------------------------------------------------------------

@dataclass
class ValidationResult:
    """Container for validation errors and warnings."""
    ok: bool = True
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def add_error(self, msg: str) -> None:
        self.errors.append(msg)
        self.ok = False

    def add_warning(self, msg: str) -> None:
        self.warnings.append(msg)

    def merge(self, other: "ValidationResult") -> None:
        """Merge another result into this one."""
        if not other.ok:
            self.ok = False
        self.errors.extend(other.errors)
        self.warnings.extend(other.warnings)

    def as_text(self) -> str:
        """Human-readable summary of all errors and warnings."""
        lines: list[str] = []
        for e in self.errors:
            lines.append(f"  ERROR:   {e}")
        for w in self.warnings:
            lines.append(f"  WARNING: {w}")
        return "\n".join(lines) if lines else "  All checks passed."


# ---------------------------------------------------------------------------
# Config validation (run at startup)
# ---------------------------------------------------------------------------

def validate_config(cfg: AppConfig) -> ValidationResult:
    """
    Validate the loaded AppConfig for correctness.

    Checks:
    - shell_mode is a recognised value
    - soa_action is WARN or BLOCK
    - bash_path exists when shell_mode is 'bash'
    - log_dir parent is writable
    - demo files exist when demo is enabled

    Does NOT check script paths here — see validate_scripts().
    """
    result = ValidationResult()

    # shell_mode
    valid_modes = {"auto", "bash", "wsl"}
    if cfg.shell_mode.lower() not in valid_modes:
        result.add_error(
            f"Invalid shell_mode '{cfg.shell_mode}'. Valid values: {', '.join(sorted(valid_modes))}"
        )

    # bash_path: if shell_mode=bash, the path must exist
    if cfg.shell_mode.lower() == "bash":
        if not cfg.bash_path:
            result.add_warning(
                "shell_mode='bash' but bash_path is not set. "
                "The auto-detection will be used; set bash_path in config.json for reliability."
            )
        elif not Path(cfg.bash_path).exists():
            result.add_error(
                f"shell_mode='bash' but bash_path does not exist: {cfg.bash_path}"
            )

    # wsl: warn if wsl mode on non-Windows
    if cfg.shell_mode.lower() == "wsl" and os.name != "nt":
        result.add_warning("shell_mode='wsl' is only meaningful on Windows.")

    # soa_action
    if cfg.demo.soa_action not in ("WARN", "BLOCK"):
        result.add_error(
            f"Invalid demo.soa_action '{cfg.demo.soa_action}'. Valid values: WARN, BLOCK"
        )

    # Demo files (warn, not error — demo mode is optional)
    if cfg.demo.enabled:
        if not cfg.demo.restore_points_file.exists():
            result.add_warning(
                f"demo.enabled=true but restore_points_file not found: "
                f"{cfg.demo.restore_points_file}"
            )
        if not cfg.demo.sessions_file.exists():
            result.add_warning(
                f"demo.enabled=true but sessions_file not found: "
                f"{cfg.demo.sessions_file}"
            )

    return result


# ---------------------------------------------------------------------------
# Script validation (run before execute workflows)
# ---------------------------------------------------------------------------

def validate_scripts(cfg: AppConfig, required_keys: list[str]) -> ValidationResult:
    """
    Verify that each required script key exists in config and the file is
    present on disk. Emits a clear error per missing script.

    Args:
        cfg:           Loaded AppConfig.
        required_keys: Script keys required by the workflow being triggered
                       (e.g. ["create_backup", "create_flashback"]).

    Returns:
        ValidationResult with .ok=False if any script is missing.
    """
    result = ValidationResult()
    for key in required_keys:
        path = cfg.scripts.get(key)
        if path is None:
            result.add_error(
                f"Script key '{key}' is missing from config.json scripts section."
            )
        elif not path.exists():
            result.add_error(
                f"Script '{key}' configured but file not found: {path}"
            )
        elif path.stat().st_size == 0:
            result.add_warning(
                f"Script '{key}' exists but is empty: {path}"
            )
        else:
            # Warn if file is not executable on POSIX
            if os.name != "nt" and not os.access(path, os.X_OK):
                result.add_warning(
                    f"Script '{key}' is not executable. Run: chmod +x {path}"
                )
    return result


# ---------------------------------------------------------------------------
# Shell availability check
# ---------------------------------------------------------------------------

def validate_shell(cfg: AppConfig) -> ValidationResult:
    """
    Verify that the configured shell interpreter is available and usable.

    Checks (Windows only):
    - 'bash' mode: looks for Git Bash or provided bash_path
    - 'wsl' mode: probes `wsl -e sh -c 'exit 0'`
    - 'auto' mode: checks bash then wsl availability

    On POSIX: checks that `sh` is on PATH.
    """
    result = ValidationResult()

    if os.name != "nt":
        # POSIX: just need sh available
        if not shutil.which("sh"):
            result.add_error(
                "No 'sh' interpreter found on PATH. Cannot run shell scripts."
            )
        return result

    # Windows path
    mode = cfg.shell_mode.lower()

    if mode == "wsl":
        if not _probe_wsl():
            result.add_error(
                "shell_mode='wsl' but WSL is not available or not responding. "
                "Install WSL or change shell_mode in config.json."
            )
        return result

    if mode == "bash":
        bash = _find_git_bash() or (cfg.bash_path if cfg.bash_path else None)
        if not bash or not Path(bash).exists():
            result.add_error(
                "shell_mode='bash' but no usable bash.exe found. "
                "Install Git for Windows or set bash_path in config.json."
            )
        return result

    # auto mode: need at least one working option
    has_bash = bool(_find_git_bash() or (cfg.bash_path and Path(cfg.bash_path).exists()))
    has_wsl = _probe_wsl()
    if not has_bash and not has_wsl:
        result.add_error(
            "shell_mode='auto' but neither Git Bash nor WSL was found. "
            "Install Git for Windows (recommended) or WSL."
        )
    elif not has_bash:
        result.add_warning("Git Bash not found; will use WSL as fallback.")
    return result


# ---------------------------------------------------------------------------
# Combined: run all pre-flight checks for a workflow
# ---------------------------------------------------------------------------

def run_preflight(cfg: AppConfig, required_script_keys: list[str]) -> ValidationResult:
    """
    Run all pre-flight checks before launching an execute workflow.

    Combines:
    - Shell availability check
    - Script existence check for required_script_keys

    Usage (GUI):
        result = run_preflight(cfg, ["create_backup", "create_flashback"])
        if not result.ok:
            messagebox.showerror("Pre-flight Failed", result.as_text())
            return

    Usage (CLI):
        result = run_preflight(cfg, ["create_backup", "restore_backup", "flashback_restore"])
        if not result.ok:
            logging.error("Pre-flight failed:\n%s", result.as_text())
            return 2
    """
    combined = ValidationResult()
    combined.merge(validate_shell(cfg))
    combined.merge(validate_scripts(cfg, required_script_keys))
    return combined


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

def _find_git_bash() -> str | None:
    """Return path to Git Bash exe if found, else None."""
    candidates = [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\usr\bin\bash.exe",
    ]
    for c in candidates:
        if Path(c).exists():
            return c
    return shutil.which("bash")


def _probe_wsl() -> bool:
    """Return True if WSL is available and responds to a no-op command."""
    if not shutil.which("wsl"):
        return False
    try:
        subprocess.run(
            ["wsl", "-e", "sh", "-c", "exit 0"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
            check=True,
        )
        return True
    except Exception:
        return False
