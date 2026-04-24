from __future__ import annotations

"""
email_notify.py — Send workflow completion email notifications.

Design principles:
  - Email is ALWAYS non-blocking: sent via a daemon background thread.
  - A failed email NEVER crashes or blocks the workflow.
  - Errors are logged (not raised) so operators see them in the log file.
  - Supports plain SMTP with optional STARTTLS (port 587) or SSL (port 465).
  - Log file is attached as a plain-text attachment when provided.

Configuration is driven by the 'email' section of config.json.
If email.enabled is false (default), all calls are no-ops.
"""

import logging
import smtplib
import socket
import threading
from dataclasses import dataclass, field
from email import encoders
from email.mime.base import MIMEBase
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path


# ---------------------------------------------------------------------------
# Configuration dataclass
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class EmailConfig:
    """
    Maps to the 'email' section of config.json.

    Example config.json entry:
        "email": {
            "enabled": true,
            "smtp_host": "smtp.example.com",
            "smtp_port": 587,
            "smtp_user": "flashback-tool@example.com",
            "smtp_password": "s3cr3t",
            "from_addr": "flashback-tool@example.com",
            "to_addrs": ["dba@example.com", "ops@example.com"],
            "subject_prefix": "[FLASHBACK] ",
            "use_tls": true
        }
    """
    enabled: bool = False
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    from_addr: str = ""
    to_addrs: list[str] = field(default_factory=list)
    subject_prefix: str = "[FLASHBACK] "
    use_tls: bool = True  # True = STARTTLS (port 587); False = plain SMTP


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def send_completion_email(
    cfg: EmailConfig,
    *,
    workflow: str,
    status: str,
    run_id: str,
    operator_id: str,
    detail_lines: list[str] | None = None,
    log_path: Path | None = None,
) -> None:
    """
    Send a workflow completion notification email in a daemon thread.

    Args:
        cfg:          EmailConfig loaded from config.json.
        workflow:     Human-readable workflow name, e.g. "Create Flashback Request".
        status:       "SUCCESS" | "FAILED" | "CANCELLED" | "ABORTED".
        run_id:       Short unique run identifier (8 hex chars).
        operator_id:  Username or ID of the operator who triggered the workflow.
        detail_lines: Optional additional lines to include in the email body.
        log_path:     If provided and the file exists, it is attached to the email.

    The call returns immediately; the email is sent in the background.
    If email is disabled or config is incomplete, this is a no-op.
    """
    if not cfg.enabled:
        return

    if not _is_config_usable(cfg):
        logging.warning(
            "[email] Notification skipped: email.enabled=true but config "
            "is incomplete (check smtp_host, from_addr, to_addrs)."
        )
        return

    thread = threading.Thread(
        target=_send_blocking,
        args=(cfg, workflow, status, run_id, operator_id, detail_lines or [], log_path),
        daemon=True,
        name=f"email-notify-{run_id}",
    )
    thread.start()
    logging.info("[email] Notification queued (run_id=%s, status=%s).", run_id, status)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _is_config_usable(cfg: EmailConfig) -> bool:
    """Return True if the minimum required fields are present."""
    return bool(cfg.smtp_host and cfg.from_addr and cfg.to_addrs)


def _send_blocking(
    cfg: EmailConfig,
    workflow: str,
    status: str,
    run_id: str,
    operator_id: str,
    detail_lines: list[str],
    log_path: Path | None,
) -> None:
    """
    Blocking SMTP send. Called in a daemon thread.
    All exceptions are caught and logged — this must NEVER propagate.
    """
    try:
        msg = _build_message(cfg, workflow, status, run_id, operator_id, detail_lines, log_path)
        _smtp_send(cfg, msg)
        logging.info(
            "[email] Notification delivered to %s (run_id=%s).",
            ", ".join(cfg.to_addrs),
            run_id,
        )
    except Exception as exc:
        logging.error(
            "[email] Failed to send notification (run_id=%s): %s",
            run_id,
            exc,
            exc_info=True,
        )


def _build_message(
    cfg: EmailConfig,
    workflow: str,
    status: str,
    run_id: str,
    operator_id: str,
    detail_lines: list[str],
    log_path: Path | None,
) -> MIMEMultipart:
    """Build the MIMEMultipart email message."""
    subject = f"{cfg.subject_prefix}{status}: {workflow} [run:{run_id}]"

    hostname = socket.gethostname()
    body_lines = [
        f"Oracle Flashback Automation — Workflow Completion Report",
        f"",
        f"  Workflow  : {workflow}",
        f"  Status    : {status}",
        f"  Run ID    : {run_id}",
        f"  Operator  : {operator_id or '(unknown)'}",
        f"  Host      : {hostname}",
        f"",
    ]
    if detail_lines:
        body_lines.append("Details:")
        body_lines.extend(f"  {line}" for line in detail_lines)
        body_lines.append("")

    if log_path and log_path.exists():
        body_lines.append(f"Log file attached: {log_path.name}")
    else:
        body_lines.append("(No log file attached.)")

    body_lines += [
        "",
        "---",
        "This message was generated automatically by Oracle Flashback Automation.",
    ]

    msg = MIMEMultipart()
    msg["Subject"] = subject
    msg["From"] = cfg.from_addr
    msg["To"] = ", ".join(cfg.to_addrs)
    msg.attach(MIMEText("\n".join(body_lines), "plain", "utf-8"))

    # Attach log file if available
    if log_path and log_path.exists():
        try:
            part = MIMEBase("application", "octet-stream")
            part.set_payload(log_path.read_bytes())
            encoders.encode_base64(part)
            part.add_header(
                "Content-Disposition",
                "attachment",
                filename=log_path.name,
            )
            msg.attach(part)
        except Exception as exc:
            logging.warning("[email] Could not attach log file: %s", exc)

    return msg


def _smtp_send(cfg: EmailConfig, msg: MIMEMultipart) -> None:
    """
    Connect to SMTP server and send the message.

    Prefers STARTTLS (port 587). Falls back to plain SMTP if use_tls=False.
    SSL-wrapped connections (port 465 / SMTP_SSL) can be enabled by setting
    smtp_port=465 and use_tls=False (SMTP_SSL is handled in the else branch
    via smtplib.SMTP_SSL when port==465).
    """
    recipients = cfg.to_addrs

    if cfg.use_tls:
        # STARTTLS: plain connection upgraded with EHLO+STARTTLS
        with smtplib.SMTP(cfg.smtp_host, cfg.smtp_port, timeout=15) as server:
            server.ehlo()
            server.starttls()
            server.ehlo()
            if cfg.smtp_user and cfg.smtp_password:
                server.login(cfg.smtp_user, cfg.smtp_password)
            server.sendmail(cfg.from_addr, recipients, msg.as_string())
    elif cfg.smtp_port == 465:
        # SSL-wrapped SMTP (port 465)
        with smtplib.SMTP_SSL(cfg.smtp_host, cfg.smtp_port, timeout=15) as server:
            if cfg.smtp_user and cfg.smtp_password:
                server.login(cfg.smtp_user, cfg.smtp_password)
            server.sendmail(cfg.from_addr, recipients, msg.as_string())
    else:
        # Plain SMTP (no encryption — only for internal relay servers)
        with smtplib.SMTP(cfg.smtp_host, cfg.smtp_port, timeout=15) as server:
            if cfg.smtp_user and cfg.smtp_password:
                server.login(cfg.smtp_user, cfg.smtp_password)
            server.sendmail(cfg.from_addr, recipients, msg.as_string())
