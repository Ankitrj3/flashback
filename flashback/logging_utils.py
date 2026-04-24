from __future__ import annotations

"""
logging_utils.py — Structured audit logging for Oracle Flashback Automation.

Each invocation gets a unique run_id (8-char hex). Every log line includes
this run_id so multi-session logs can be grepped cleanly:

    grep "run:3f8a1c2d" logs/flashback_*.log

Unicode / Windows console:
  - The FileHandler always uses UTF-8 (no encoding issues in the .log file).
  - The StreamHandler (stderr) forces UTF-8 via sys.stderr.reconfigure() when
    running on Windows, or falls back to 'replace' error handling so no line
    is ever lost due to a cp1252 codec error.

Log rotation:
  - After each new log is created, logs older than `max_log_files` are deleted.
"""

import logging
import os
import platform
import socket
import sys
from datetime import datetime
from pathlib import Path


def init_logging(
    log_dir: Path,
    operator_id: str = "",
    tool_version: str = "",
    max_log_files: int = 30,
) -> tuple[Path, str]:
    """
    Initialise the root logger for a new session.

    Creates a per-session log file named:
        flashback_<YYYYMMDD_HHMMSS>_<run_id>.log

    Args:
        log_dir:       Directory to write log files to (created if absent).
        operator_id:   Operator name/username for audit trail.
        tool_version:  Tool version string (e.g. "2.0.0").
        max_log_files: Maximum log files to keep; oldest pruned automatically.

    Returns:
        (log_path, run_id):
          log_path – Path of the new log file.
          run_id   – 8-character hex string uniquely identifying this run.
    """
    import secrets
    run_id = secrets.token_hex(4)   # e.g. "3f8a1c2d"

    log_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = log_dir / f"flashback_{ts}_{run_id}.log"

    fmt = f"%(asctime)s | %(levelname)-8s | [run:{run_id}] %(message)s"
    formatter = logging.Formatter(fmt, datefmt="%Y-%m-%d %H:%M:%S")

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.INFO)
    root_logger.handlers.clear()

    # ── File handler — always UTF-8, no encoding surprises ──
    fh = logging.FileHandler(log_path, encoding="utf-8")
    fh.setLevel(logging.INFO)
    fh.setFormatter(formatter)
    root_logger.addHandler(fh)

    # ── Stream handler (stderr) — force UTF-8 on Windows ──
    # Python 3.7+ supports reconfigure(); earlier versions use errors='replace'.
    try:
        # This prevents UnicodeEncodeError on Windows cp1252 consoles.
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
    except (AttributeError, OSError):
        pass  # Not available in all environments; fall back silently

    sh = logging.StreamHandler(sys.stderr)
    sh.setLevel(logging.INFO)
    sh.setFormatter(formatter)
    sh.stream = open(  # noqa: WPS515  # wrap stderr with explicit utf-8
        sys.stderr.fileno(), mode="w", encoding="utf-8", errors="replace", closefd=False,
    ) if hasattr(sys.stderr, "fileno") else sys.stderr
    root_logger.addHandler(sh)

    # Structured header block at the top of every log session
    _write_header(run_id, operator_id, tool_version, log_path)

    # Prune old log files
    _prune_old_logs(log_dir, max_log_files)

    return log_path, run_id


# ---------------------------------------------------------------------------
# Header writer
# ---------------------------------------------------------------------------

def _write_header(run_id: str, operator_id: str, tool_version: str, log_path: Path) -> None:
    """Emit a structured header block at the start of the log session."""
    sep = "=" * 72
    logging.info(sep)
    logging.info("Oracle Flashback Automation - Session Log")          # ASCII dash, no em dash
    logging.info("  Run ID    : %s", run_id)
    logging.info("  Tool vers : %s", tool_version or "(unknown)")
    logging.info(
        "  Operator  : %s",
        operator_id or os.environ.get("USERNAME", os.environ.get("USER", "(unknown)")),
    )
    logging.info("  Hostname  : %s", socket.gethostname())
    logging.info("  Platform  : %s %s", platform.system(), platform.release())
    logging.info("  Python    : %s", sys.version.split()[0])
    logging.info("  Log file  : %s", log_path.name)
    logging.info("  Started   : %s", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    logging.info(sep)


# ---------------------------------------------------------------------------
# Log rotation
# ---------------------------------------------------------------------------

def _prune_old_logs(log_dir: Path, max_keep: int) -> None:
    """
    Delete the oldest log files if the count exceeds max_keep.

    Files are sorted by modification time (newest first). Any files beyond
    position max_keep are removed.
    """
    if max_keep <= 0:
        return

    log_files = sorted(
        log_dir.glob("flashback_*.log"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,   # newest first
    )

    for old_file in log_files[max_keep:]:
        try:
            old_file.unlink()
            logging.info("Log rotation: removed old log %s", old_file.name)
        except OSError as exc:
            logging.warning("Log rotation: could not remove %s: %s", old_file.name, exc)
