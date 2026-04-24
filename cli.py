from __future__ import annotations

"""
cli.py — CLI entrypoint for Oracle Flashback Automation.

Modes (mutually exclusive):
  --dry-run           Print workflow steps only. No SSH / SQL / tar executed.
  --execute           Run configured .sh scripts (interactive confirmation gates).
  --test-connectivity Run the test_connectivity script.

Usage:
  python cli.py --dry-run
  python cli.py --execute
  python cli.py --test-connectivity

The actual Oracle / SSH / tar logic lives in the .sh scripts referenced in
config.json. This file only orchestrates user input and calls those scripts.
"""

import argparse
import logging
import subprocess
import sys
from pathlib import Path

from flashback.config import load_config
from flashback.email_notify import EmailConfig as _EmailCfg, send_completion_email
from flashback.logging_utils import init_logging
from flashback.shell_runner import ShellRunner
from flashback.validators import run_preflight, validate_config
from flashback.workflows import dry_run_create_steps, dry_run_restore_steps

sys.dont_write_bytecode = True


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def _print_step(n: int, title: str, detail: str) -> None:
    logging.info("STEP %02d | %s", n, title)
    for line in detail.splitlines():
        logging.info("        %s", line)


def _ask_yes(prompt: str) -> bool:
    val = input(f"{prompt} Type YES to continue: ").strip()
    return val == "YES"


def _ask_restore_point() -> str | None:
    rp = input("Enter restore point name: ").strip()
    return rp or None


def _ask_retype(expected: str) -> bool:
    typed = input(f"Re-type restore point name to confirm [{expected}]: ").strip()
    return typed == expected


def _run_script_cli(
    runner: ShellRunner,
    script_path: Path,
    args: list[str],
    timeout_secs: int = 0,
) -> int:
    """
    Run a script and stream its output to stdout.

    Returns:
        Exit code of the script (0 = success).
    """
    cmd = runner.build_command(script_path, args)
    logging.info("Running: %s", " ".join(str(c) for c in cmd))
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        print(line, end="", flush=True)
    return proc.wait()


# ---------------------------------------------------------------------------
# CLI dry-run workflows
# ---------------------------------------------------------------------------

def _dry_run_create(root_dir: Path) -> int:
    if not _ask_yes("Create Flashback Request selected (DRY-RUN)."):
        logging.info("Cancelled by user.")
        return 1
    if not _ask_yes("Final confirmation."):
        logging.info("Cancelled by user.")
        return 1

    for step in dry_run_create_steps():
        _print_step(step.number, step.title, step.detail)

    logging.info("Dry-run complete. No SSH/SQL/tar executed.")
    return 0


def _dry_run_restore(root_dir: Path) -> int:
    if not _ask_yes("Restore using Flashback GRP selected (DRY-RUN)."):
        logging.info("Cancelled by user.")
        return 1

    rp = _ask_restore_point()
    if not rp:
        logging.info("Cancelled: restore point is required.")
        return 1

    logging.info("Selected restore point: %s", rp)
    if not _ask_yes("Final confirmation."):
        logging.info("Cancelled by user.")
        return 1
    if not _ask_retype(rp):
        logging.info("Cancelled: typed restore point did not match.")
        return 1

    for step in dry_run_restore_steps(rp):
        _print_step(step.number, step.title, step.detail)

    logging.info("Dry-run complete. No SSH/SQL/tar executed.")
    return 0


# ---------------------------------------------------------------------------
# CLI execute workflows
# ---------------------------------------------------------------------------

def _execute_create(root_dir: Path) -> int:
    cfg = load_config(root_dir)
    runner = ShellRunner(cfg.shell_mode, cfg.bash_path)

    # Pre-flight
    required = ["create_backup", "create_flashback"]
    preflight = run_preflight(cfg, required)
    if not preflight.ok:
        logging.error("Pre-flight failed:\n%s", preflight.as_text())
        return 2
    if preflight.warnings:
        logging.warning("Pre-flight warnings:\n%s", preflight.as_text())

    if not _ask_yes("Create Flashback Request selected (EXECUTE — real DB operation)."):
        logging.info("Cancelled by user.")
        return 1
    if not _ask_yes("Final confirmation."):
        logging.info("Cancelled by user.")
        return 1

    status = "SUCCESS"
    for key, args in (("create_backup", []), ("create_flashback", [])):
        exit_code = _run_script_cli(runner, cfg.scripts[key], args, cfg.timeout.script_timeout_secs)
        if exit_code != 0:
            logging.error("Script failed (%s): exit_code=%s", key, exit_code)
            status = "FAILED"
            _notify(cfg, "Create Flashback Request", status)
            return exit_code

    _notify(cfg, "Create Flashback Request", status)
    return 0


def _execute_restore(root_dir: Path) -> int:
    cfg = load_config(root_dir)
    runner = ShellRunner(cfg.shell_mode, cfg.bash_path)

    # Pre-flight
    required = ["create_backup", "restore_backup", "flashback_restore"]
    preflight = run_preflight(cfg, required)
    if not preflight.ok:
        logging.error("Pre-flight failed:\n%s", preflight.as_text())
        return 2
    if preflight.warnings:
        logging.warning("Pre-flight warnings:\n%s", preflight.as_text())

    if not _ask_yes("Restore using Flashback GRP selected (EXECUTE — real DB operation)."):
        logging.info("Cancelled by user.")
        return 1

    rp = _ask_restore_point()
    if not rp:
        logging.info("Cancelled: restore point is required.")
        return 1

    logging.info("Selected restore point: %s", rp)
    if not _ask_yes("Final confirmation."):
        logging.info("Cancelled by user.")
        return 1
    if not _ask_retype(rp):
        logging.info("Cancelled: typed restore point did not match.")
        return 1

    status = "SUCCESS"
    for key, args in (
        ("create_backup",    []),
        ("restore_backup",   [rp]),
        ("flashback_restore",[rp]),
    ):
        exit_code = _run_script_cli(runner, cfg.scripts[key], args, cfg.timeout.script_timeout_secs)
        if exit_code != 0:
            logging.error("Script failed (%s): exit_code=%s", key, exit_code)
            status = "FAILED"
            _notify(cfg, f"Restore to '{rp}'", status)
            return exit_code

    _notify(cfg, f"Restore to '{rp}'", status)
    return 0


# ---------------------------------------------------------------------------
# Connectivity test
# ---------------------------------------------------------------------------

def _test_connectivity(root_dir: Path) -> int:
    cfg = load_config(root_dir)
    p = cfg.scripts.get("test_connectivity")
    if not p or not p.exists():
        logging.error("Missing script: test_connectivity (%s)", p)
        return 2
    runner = ShellRunner(cfg.shell_mode, cfg.bash_path)
    return _run_script_cli(runner, p, [], cfg.timeout.connectivity_timeout_secs)


# ---------------------------------------------------------------------------
# Menu helpers (interactive mode selection)
# ---------------------------------------------------------------------------

def _dry_run_menu(root_dir: Path) -> int:
    print("-" * 50)
    print("Oracle Flashback Automation - DRY-RUN mode")
    print("-" * 50)
    print("1) Create Flashback Request")
    print("2) Restore using Flashback GRP")
    choice = input("Select option [1-2]: ").strip()
    if choice == "1":
        return _dry_run_create(root_dir)
    if choice == "2":
        return _dry_run_restore(root_dir)
    logging.info("Invalid choice. Exiting.")
    return 2


def _execute_menu(root_dir: Path) -> int:
    print("-" * 50)
    print("Oracle Flashback Automation - EXECUTE mode")
    print("-" * 50)
    print("1) Create Flashback Request")
    print("2) Restore using Flashback GRP")
    choice = input("Select option [1-2]: ").strip()
    if choice == "1":
        return _execute_create(root_dir)
    if choice == "2":
        return _execute_restore(root_dir)
    logging.info("Invalid choice. Exiting.")
    return 2


# ---------------------------------------------------------------------------
# Email helper
# ---------------------------------------------------------------------------

def _notify(cfg, workflow: str, status: str) -> None:
    """Send completion email (non-blocking) if email is configured."""
    ec = cfg.email
    email_cfg = _EmailCfg(
        enabled=ec.enabled,
        smtp_host=ec.smtp_host,
        smtp_port=ec.smtp_port,
        smtp_user=ec.smtp_user,
        smtp_password=ec.smtp_password,
        from_addr=ec.from_addr,
        to_addrs=list(ec.to_addrs),
        subject_prefix=ec.subject_prefix,
        use_tls=ec.use_tls,
    )
    send_completion_email(
        email_cfg,
        workflow=workflow,
        status=status,
        run_id="cli",
        operator_id=cfg.operator_id,
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        prog="cli.py",
        description="Oracle Flashback Automation CLI. Use --dry-run, --execute, or --test-connectivity.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print workflow steps only. No SSH/SQL/tar executed.",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Run configured .sh scripts (interactive confirmation gates).",
    )
    parser.add_argument(
        "--test-connectivity",
        action="store_true",
        help="Run the configured test_connectivity script.",
    )
    parser.add_argument(
        "--skip-config-check",
        action="store_true",
        help="Skip startup config validation (not recommended).",
    )
    args = parser.parse_args()

    root_dir = Path(__file__).resolve().parent

    # Initialise logging (returns log_path, run_id)
    cfg = load_config(root_dir)
    log_dir = root_dir / cfg.logging.log_dir
    _log_path, _run_id = init_logging(
        log_dir,
        operator_id=cfg.operator_id,
        tool_version=cfg.tool_version,
        max_log_files=cfg.logging.max_log_files,
    )

    # Config validation (non-fatal — just prints warnings)
    if not args.skip_config_check:
        result = validate_config(cfg)
        if not result.ok:
            logging.warning("Config validation issues found:\n%s", result.as_text())
        elif result.warnings:
            logging.warning("Config validation warnings:\n%s", result.as_text())

    # Mutual exclusion
    modes = [args.dry_run, args.execute, args.test_connectivity]
    active = sum(bool(m) for m in modes)
    if active > 1:
        logging.error("Choose only one mode: --dry-run | --execute | --test-connectivity")
        return 2
    if active == 0:
        logging.error("Specify a mode: --dry-run | --execute | --test-connectivity")
        parser.print_help()
        return 2

    if args.test_connectivity:
        return _test_connectivity(root_dir)

    if args.dry_run:
        return _dry_run_menu(root_dir)

    # --execute
    return _execute_menu(root_dir)


if __name__ == "__main__":
    raise SystemExit(main())
