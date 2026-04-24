from __future__ import annotations

"""
ui.py — Tkinter GUI for Oracle Flashback Automation.

Design principles:
  - Python owns: confirmations, pre-flight checks, logging, UX.
  - Shell scripts own: all SSH / Oracle / tar operations.
  - The GUI is intentionally thin: it does not embed any SQL or SSH logic.

Confirmation flow (v2.1):
  CREATE workflow  : 1× rich Yes/No dialog → 1× type "YES"
  RESTORE workflow : 1× rich Yes/No dialog → session check →
                     select restore point (dropdown/text) → retype RP name

Features:
  - Dark-themed, colour-coded scrollable output panel
  - Status bar with current workflow state
  - Abort button (SIGTERM → SIGKILL with 5-second grace period)
  - Config validation warning on startup
  - Pre-flight script/shell check before every execute workflow
  - Demo mode: passes FLASHBACK_DEMO=true env var to all scripts when
    demo.enabled=true in config.json (scripts show simulated output)
  - Audit log: operator_id + run_id in every log line
  - Email notification on workflow completion (non-blocking thread)
"""

import logging
from pathlib import Path
from queue import Empty, Queue
import tkinter as tk
from tkinter import messagebox, ttk

from .config import load_config, AppConfig
from .confirm import (
    confirm_restore_point_flow,
    confirm_yes_no,
    require_typed_value,
)
from .demo_data import format_restore_points_table, load_active_sessions, load_restore_points
from .email_notify import EmailConfig as _EmailCfg, send_completion_email
from .logging_utils import init_logging
from .shell_runner import RunResult, ShellRunner
from .validators import run_preflight, validate_config
from .workflows import dry_run_create_steps, dry_run_restore_steps


# ---------------------------------------------------------------------------
# Output colour tag names
# ---------------------------------------------------------------------------
_TAG_INFO  = "tag_info"   # teal — general info
_TAG_RUN   = "tag_run"    # blue — script launch lines
_TAG_WARN  = "tag_warn"   # orange — warnings
_TAG_ERROR = "tag_error"  # red — errors
_TAG_STEP  = "tag_step"   # yellow-bold — dry-run step headers
_TAG_DIM   = "tag_dim"    # dark-grey — separators / metadata
_TAG_OK    = "tag_ok"     # bright green — success messages


# ---------------------------------------------------------------------------
# _ScriptQueue — sequential script execution with streaming output
# ---------------------------------------------------------------------------

class _ScriptQueue:
    """
    Manages sequential execution of (name, script_path, args) task lists.

    Each script runs in a daemon thread via ShellRunner.run_in_thread().
    Output lines are polled every 100 ms via root.after() and forwarded to
    the GUI text widget.

    Demo mode:
      If env contains FLASHBACK_DEMO=true, scripts receive that variable and
      can branch into simulated output without touching Oracle/SSH.
    """

    def __init__(self, gui: "FlashbackGUI") -> None:
        self.gui = gui
        self.output_queue: Queue[str] = Queue()
        self.done_queue: Queue[RunResult] = Queue()
        self.tasks: list[tuple[str, Path, list[str]]] = []
        self.running = False
        self._workflow_name = ""
        self._env: dict[str, str] = {}

        runner_cfg = gui.config
        self.runner = ShellRunner(runner_cfg.shell_mode, runner_cfg.bash_path)

    # ── Public ──────────────────────────────────────────────────────────────

    def start(
        self,
        tasks: list[tuple[str, Path, list[str]]],
        workflow_name: str = "",
        env: dict[str, str] | None = None,
    ) -> None:
        """Begin executing tasks sequentially. env is passed to every script."""
        if self.running:
            messagebox.showwarning("Busy", "A workflow is already running.")
            return

        self.tasks = list(tasks)
        self._workflow_name = workflow_name
        self._env = env or {}
        self.running = True

        self.gui._set_execute_buttons_enabled(False)
        self.gui._set_abort_enabled(True)
        self.gui._set_status(f"Running: {workflow_name}...")
        self.gui._append_line("-" * 62, _TAG_DIM)
        self.gui._append_line(f"  Starting workflow: {workflow_name}", _TAG_RUN)
        if self._env.get("FLASHBACK_DEMO") == "true":
            self.gui._append_line("  [demo] Scripts running in DEMO simulation mode.", _TAG_WARN)
        self._start_next()
        self.gui.root.after(100, self._poll)

    def abort(self) -> None:
        """Request abort of the currently running script."""
        if not self.running:
            return
        self.gui._append_line("[abort] Abort requested by operator.", _TAG_WARN)
        logging.warning("[abort] Operator requested abort.")
        self.runner.abort()
        self.tasks.clear()

    # ── Internal ─────────────────────────────────────────────────────────────

    def _start_next(self) -> None:
        if not self.tasks:
            self._finish()
            return

        name, path, args = self.tasks.pop(0)
        display = f"{path.name} {' '.join(args)}".rstrip()
        self.gui._append_line(f"[run] {name}: {display}", _TAG_RUN)

        timeout = self.gui.config.timeout.script_timeout_secs
        try:
            self.runner.run_in_thread(
                path, args, self.output_queue, self.done_queue,
                env=self._env, timeout_secs=timeout,
            )
        except Exception as exc:
            logging.exception("Failed to start script: %s", path)
            self.gui._append_line(f"[error] Failed to start '{name}': {exc}", _TAG_ERROR)
            self._finish(failed=True)

    def _poll(self) -> None:
        """Drain output + check completion every 100 ms."""
        while True:
            try:
                line = self.output_queue.get_nowait()
            except Empty:
                break
            self.gui._append_line(line, _classify_line(line))

        try:
            result: RunResult = self.done_queue.get_nowait()
        except Empty:
            result = None  # type: ignore[assignment]

        if result is not None:
            if result.aborted:
                self.gui._append_line("[abort] Script aborted by operator.", _TAG_WARN)
                self._finish(failed=True, aborted=True)
                return
            if result.timed_out:
                self.gui._append_line("[timeout] Script timed out and was terminated.", _TAG_ERROR)
                self._finish(failed=True)
                return
            if result.exit_code != 0:
                self.gui._append_line(
                    f"[exit] code={result.exit_code} — script failed. Stopping workflow.",
                    _TAG_ERROR,
                )
                self._finish(failed=True)
                return
            self.gui._append_line(f"[exit] code=0  OK", _TAG_OK)
            self._start_next()
            # Re-schedule _poll for the newly started script.
            # _start_next() either started a new script (self.running stays True)
            # or called _finish() with no more tasks (self.running set to False).
            # The check below handles both cases correctly.
            if self.running:
                self.gui.root.after(100, self._poll)
            return

        if self.running:
            self.gui.root.after(100, self._poll)

    def _finish(self, *, failed: bool = False, aborted: bool = False) -> None:
        self.running = False
        self.gui._set_execute_buttons_enabled(True)
        self.gui._set_abort_enabled(False)

        if aborted:
            status = "ABORTED"
            self.gui._append_line("  Workflow aborted by operator.", _TAG_WARN)
            self.gui._set_status("Aborted.")
        elif failed:
            status = "FAILED"
            self.gui._append_line("  Workflow FAILED — see errors above.", _TAG_ERROR)
            self.gui._set_status("Failed — check output for details.")
        else:
            status = "SUCCESS"
            self.gui._append_line("  Workflow completed successfully.  OK", _TAG_OK)
            self.gui._set_status("Done.  OK")

        logging.info("Workflow '%s': %s", self._workflow_name, status)

        # Email notification (non-blocking)
        _send_notify(self.gui.config, self._workflow_name, status, self.gui.run_id, self.gui.log_path)


# ---------------------------------------------------------------------------
# Main GUI class
# ---------------------------------------------------------------------------

class FlashbackGUI:
    """Main application window for Oracle Flashback Automation."""

    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Oracle Flashback Automation")
        self.root.geometry("980x620")
        self.root.minsize(800, 500)

        self.root_dir = Path(__file__).resolve().parents[1]
        self.config: AppConfig = load_config(self.root_dir)

        # Logging — returns (path, run_id)
        log_dir = self.root_dir / self.config.logging.log_dir
        self.log_path, self.run_id = init_logging(
            log_dir,
            operator_id=self.config.operator_id,
            tool_version=self.config.tool_version,
            max_log_files=self.config.logging.max_log_files,
        )

        self._scripts = _ScriptQueue(self)

        # Demo restore points cache
        self.demo_restore_points = []
        if self.config.demo.enabled:
            self.demo_restore_points = load_restore_points(self.config.demo.restore_points_file)

        self._build_ui()

        # Post-render: startup config validation
        self.root.after(200, self._startup_validation)

    # ── UI construction ──────────────────────────────────────────────────────

    def _build_ui(self) -> None:
        container = ttk.Frame(self.root, padding=12)
        container.pack(fill=tk.BOTH, expand=True)

        # ── Header ──
        hdr = ttk.Frame(container)
        hdr.pack(fill=tk.X, pady=(0, 8))

        ttk.Label(
            hdr, text="Oracle Flashback Automation",
            font=("Segoe UI", 15, "bold"),
        ).pack(side=tk.LEFT)

        op_label = self.config.operator_id or "unknown"
        ttk.Label(
            hdr,
            text=f"operator: {op_label}   run: {self.run_id}",
            font=("Segoe UI", 9), foreground="#555555",
        ).pack(side=tk.RIGHT)

        ttk.Label(
            hdr,
            text=f"log: {self.log_path.name}",
            font=("Segoe UI", 9), foreground="#555555",
        ).pack(side=tk.RIGHT, padx=(0, 20))

        # ── Workflow action buttons ──
        btn_frame = ttk.LabelFrame(container, text="Workflow Actions", padding=10)
        btn_frame.pack(fill=tk.X, pady=(0, 8))

        # Row 1: Dry-run
        dry_row = ttk.Frame(btn_frame)
        dry_row.pack(fill=tk.X, pady=(0, 6))
        ttk.Label(dry_row, text="Dry-Run:", font=("Segoe UI", 9, "bold"), width=9).pack(side=tk.LEFT)

        self.btn_create_dry = ttk.Button(
            dry_row, text="Create Flashback Request (Dry-Run)",
            command=self._on_create_dry,
        )
        self.btn_create_dry.pack(side=tk.LEFT, padx=(0, 8))

        self.btn_restore_dry = ttk.Button(
            dry_row, text="Restore using Flashback GRP (Dry-Run)",
            command=self._on_restore_dry,
        )
        self.btn_restore_dry.pack(side=tk.LEFT)

        # Row 2: Execute
        exec_row = ttk.Frame(btn_frame)
        exec_row.pack(fill=tk.X, pady=(0, 6))
        ttk.Label(exec_row, text="Execute:", font=("Segoe UI", 9, "bold"), width=9).pack(side=tk.LEFT)

        self.btn_create_exec = ttk.Button(
            exec_row, text="Create Flashback Request  >",
            command=self._on_create_exec,
        )
        self.btn_create_exec.pack(side=tk.LEFT, padx=(0, 8))

        self.btn_restore_exec = ttk.Button(
            exec_row, text="Restore using Flashback GRP  >",
            command=self._on_restore_exec,
        )
        self.btn_restore_exec.pack(side=tk.LEFT)

        # Row 3: Utilities
        util_row = ttk.Frame(btn_frame)
        util_row.pack(fill=tk.X)
        ttk.Label(util_row, text="Utility:", font=("Segoe UI", 9, "bold"), width=9).pack(side=tk.LEFT)

        self.btn_test = ttk.Button(
            util_row, text="Test Connectivity",
            command=self._on_test_connectivity,
        )
        self.btn_test.pack(side=tk.LEFT, padx=(0, 8))

        ttk.Button(
            util_row, text="Show Restore Points",
            command=self._on_show_restore_points,
        ).pack(side=tk.LEFT)

        self.btn_abort = ttk.Button(
            util_row, text="  Abort",
            command=self._on_abort, state="disabled",
        )
        self.btn_abort.pack(side=tk.RIGHT)

        # ── Output area ──
        out_frame = ttk.LabelFrame(container, text="Output", padding=8)
        out_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 6))

        self.log_text = tk.Text(
            out_frame, height=20, wrap="word",
            font=("Consolas", 9),
            bg="#1e1e1e", fg="#d4d4d4",
            insertbackground="#ffffff",
            selectbackground="#264f78",
        )
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.log_text.configure(state="disabled")

        scroll = ttk.Scrollbar(out_frame, orient="vertical", command=self.log_text.yview)
        scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.log_text.configure(yscrollcommand=scroll.set)

        # Colour tags
        self.log_text.tag_configure(_TAG_INFO,  foreground="#4ec9b0")
        self.log_text.tag_configure(_TAG_RUN,   foreground="#9cdcfe")
        self.log_text.tag_configure(_TAG_WARN,  foreground="#ce9178")
        self.log_text.tag_configure(_TAG_ERROR, foreground="#f44747")
        self.log_text.tag_configure(_TAG_STEP,  foreground="#dcdcaa", font=("Consolas", 9, "bold"))
        self.log_text.tag_configure(_TAG_DIM,   foreground="#555555")
        self.log_text.tag_configure(_TAG_OK,    foreground="#6dce6d")

        # ── Status bar ──
        footer = ttk.Frame(container)
        footer.pack(fill=tk.X)

        ttk.Button(footer, text="Clear Output", command=self._clear_output).pack(side=tk.RIGHT)

        self.status_var = tk.StringVar(value="Ready.")
        ttk.Label(
            footer, textvariable=self.status_var,
            relief="sunken", anchor="w", font=("Segoe UI", 9),
        ).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 8))

        # Initial info line
        demo_label = "ON" if self.config.demo.enabled else "OFF"
        self._append_line(
            f"Oracle Flashback Automation v{self.config.tool_version}  |  "
            f"demo={demo_label}  |  shell_mode={self.config.shell_mode}  |  run={self.run_id}",
            _TAG_DIM,
        )
        self._append_line("Ready.", _TAG_INFO)

    # ── Startup validation ───────────────────────────────────────────────────

    def _startup_validation(self) -> None:
        result = validate_config(self.config)
        if not result.ok:
            logging.warning("Config startup validation errors:\n%s", result.as_text())
            messagebox.showwarning(
                "Configuration Warning",
                "config.json validation issues found. Execute may fail.\n\n"
                + result.as_text(),
            )
        elif result.warnings:
            logging.warning("Config startup warnings:\n%s", result.as_text())

    # ── Pre-flight helper ────────────────────────────────────────────────────

    def _preflight_execute(self, required_keys: list[str]) -> bool:
        """
        Run pre-flight checks before an execute workflow.

        In demo mode, script-existence check is skipped (demo scripts may
        not exist on path). Shell check is always performed.

        Returns True if safe to proceed, False to abort.
        """
        if not self.config.preflight.run_connectivity_before_execute:
            return True

        result = run_preflight(self.config, required_keys)
        if not result.ok:
            logging.error("Pre-flight failed:\n%s", result.as_text())
            if self.config.demo.enabled:
                # In demo mode: warn but allow proceed
                ans = messagebox.askyesno(
                    "Pre-flight Warning (Demo Mode)",
                    "Pre-flight checks failed, but DEMO mode is enabled.\n\n"
                    + result.as_text()
                    + "\n\nProceed in demo simulation mode?",
                )
                return bool(ans)
            messagebox.showerror(
                "Pre-flight Check Failed",
                "Cannot start workflow:\n\n"
                + result.as_text()
                + "\n\nFix these issues in config.json and scripts/ then try again.",
            )
            return False

        if result.warnings:
            ok = messagebox.askyesno(
                "Pre-flight Warnings",
                "Pre-flight passed with warnings:\n\n"
                + result.as_text()
                + "\n\nContinue?",
            )
            return bool(ok)

        return True

    # ── Demo env helper ──────────────────────────────────────────────────────

    def _script_env(self) -> dict[str, str]:
        """
        Build the full environment dict passed to every shell script.

        Includes:
          - FLASHBACK_DEMO      : "true" in demo mode
          - FLASHBACK_INSTANCE_ID / FLASHBACK_ORACLE_ENV / FLASHBACK_DB_AUTH
          - FLASHBACK_PDB_NAME : PDB container name (e.g. RXEST01)
          - flashback_BASE_DIR / FLASHBACK_BACKUP_DIR / FLASHBACK_FS_LIST
          - flashback_NODES / FLASHBACK_SSH_USER / FLASHBACK_SSH_KEY
        """
        cfg = self.config
        env: dict[str, str] = {}

        # Demo flag
        if cfg.demo.enabled:
            env["FLASHBACK_DEMO"] = "true"

        # Instance / Oracle
        env["FLASHBACK_INSTANCE_ID"] = cfg.instance_id
        env["FLASHBACK_ORACLE_ENV"]  = cfg.oracle.env_file
        env["FLASHBACK_DB_AUTH"]     = cfg.oracle.auth_mode
        env["FLASHBACK_PDB_NAME"]    = cfg.oracle.pdb_name

        # Network auth (only used when auth_mode=network)
        if cfg.oracle.db_host:
            env["FLASHBACK_DB_HOST"]    = cfg.oracle.db_host
        if cfg.oracle.db_port:
            env["FLASHBACK_DB_PORT"]    = cfg.oracle.db_port
        if cfg.oracle.db_service:
            env["FLASHBACK_DB_SERVICE"] = cfg.oracle.db_service
        if cfg.oracle.db_user:
            env["FLASHBACK_DB_USER"]    = cfg.oracle.db_user
        if cfg.oracle.db_pass:
            env["FLASHBACK_DB_PASS"]    = cfg.oracle.db_pass

        # App nodes
        if cfg.app.nodes:
            env["flashback_NODES"] = " ".join(cfg.app.nodes)
        env["FLASHBACK_SSH_USER"]    = cfg.app.ssh_user
        env["FLASHBACK_SSH_KEY"]     = cfg.app.ssh_key
        env["flashback_BASE_DIR"] = cfg.app.base_dir

        # Backup
        env["FLASHBACK_BACKUP_DIR"] = cfg.backup.dir
        env["FLASHBACK_FS_LIST"]    = " ".join(cfg.backup.filesystems)

        return env

    def _demo_env(self) -> dict[str, str]:
        """Backwards-compat alias — use _script_env() for all new code."""
        return self._script_env()

    # ── Workflow handlers ─────────────────────────────────────────────────────

    def _on_create_dry(self) -> None:
        """Dry-run: Create Flashback Request — shows steps only, nothing executes."""
        if not confirm_yes_no(
            "Create Flashback Request — Dry-Run",
            "This will show the steps that WOULD run in execute mode.\n"
            "No SSH, SQL, or filesystem operations will be performed.\n\n"
            "Continue?",
        ):
            return

        self._append_line("[dry-run] Create Flashback Request — showing steps only.", _TAG_RUN)
        self._print_workflow(dry_run_create_steps())

    def _on_restore_dry(self) -> None:
        """Dry-run: Restore using Flashback GRP — shows steps, nothing executes."""
        if not confirm_yes_no(
            "Restore using Flashback GRP — Dry-Run",
            "This will show the steps that WOULD run in execute mode.\n"
            "No SSH, SQL, or filesystem operations will be performed.\n\n"
            "Continue?",
        ):
            return

        if not self._maybe_demo_session_check():
            return

        _ensure_restore_points(self)
        options = [p.name for p in self.demo_restore_points] if self.config.demo.enabled else None
        sel = confirm_restore_point_flow(options)
        if not sel:
            return

        self._append_line(f"[dry-run] Restore to: {sel.restore_point} — showing steps only.", _TAG_RUN)
        self._print_workflow(dry_run_restore_steps(sel.restore_point))

    def _on_create_exec(self) -> None:
        """
        Execute: Create Flashback Request.

        Confirmation flow:
          1. Rich Yes/No dialog (describes what will happen)
          2. Type "YES" to confirm (final safeguard)
          -> Execute: create_backup.sh, create_flashback_restore_point.sh
        """
        required_keys = ["create_backup", "create_flashback"]

        if not self._preflight_execute(required_keys):
            return

        # Step 1 — Descriptive confirmation
        inst = self.config.instance_id
        demo_note = "\n\n[DEMO MODE: Simulated output — no real DB operations]" if self.config.demo.enabled else ""
        if not confirm_yes_no(
            "Execute: Create Flashback Request",
            "This will execute the following steps:\n\n"
            "  Step 1/2:  create_backup.sh\n"
            f"     Parallel nohup tar backup of fs_ne, fs1, fs2\n"
            f"     -> {self.config.backup.dir}/\n\n"
            "  Step 2/2:  create_flashback_restore_point.sh\n"
            f"     sqlplus / as sysdba\n"
            f"     CREATE RESTORE POINT '{inst}_CDB_flashback_restore_DDMMMYY'\n"
            f"     ALTER SESSION SET CONTAINER={self.config.oracle.pdb_name}\n"
            f"     CREATE RESTORE POINT '{inst}_PDB_flashback_restore_DDMMMYY'\n"
            "     GUARANTEE FLASHBACK DATABASE"
            + demo_note
            + "\n\nThis is a REAL database operation. Proceed?",
        ):
            return

        # Step 2 — Type YES
        if not require_typed_value(
            "Final Confirmation",
            "Type  YES  to execute the Create Flashback workflow:",
            "YES",
        ):
            messagebox.showwarning("Cancelled", "Confirmation failed — operation cancelled.")
            return

        tasks = [
            ("create_backup",    self.config.scripts["create_backup"],    []),
            ("create_flashback", self.config.scripts["create_flashback"], []),
        ]
        self._append_line("[execute] Create Flashback Request — starting.", _TAG_RUN)
        self._scripts.start(tasks, workflow_name="Create Flashback Request", env=self._script_env())

    def _on_restore_exec(self) -> None:
        """
        Execute: Restore using Flashback GRP.

        Confirmation flow:
          1. Rich Yes/No warning dialog (describes all 4 scripts)
          2. Session check (demo: WARN/BLOCK on active sessions)
          3. Select restore point from dropdown (demo) or free text
          4. Re-type restore point name to confirm
          -> Execute: shutdown_app_services, create_backup, restore_backup, flashback_restore
        """
        required_keys = [
            "shutdown_app_services", "create_backup",
            "restore_backup", "flashback_restore",
        ]

        if not self._preflight_execute(required_keys):
            return

        # Step 1 — Descriptive WARNING confirmation
        inst = self.config.instance_id
        nodes_str = ", ".join(self.config.app.nodes) if self.config.app.nodes else "(none configured)"
        demo_note = "\n\n[DEMO MODE: Simulated output — no real DB operations]" if self.config.demo.enabled else ""
        if not confirm_yes_no(
            "Execute: Restore using Flashback GRP",
            "This will execute the following steps:\n\n"
            "  Step 1/4:  shutdown_app_services.sh\n"
            f"     SSH to app nodes: {nodes_str}\n"
            "     Check and shutdown ALL EBS services on each node\n"
            "     Verify no EBS processes remain before proceeding\n\n"
            "  Step 2/4:  create_backup.sh\n"
            "     Safety snapshot of CURRENT filesystem state\n"
            f"     -> {self.config.backup.dir}/\n\n"
            "  Step 3/4:  restore_backup.sh\n"
            f"     Extract {inst}_fs_ne/fs1/fs2_backup_*.tar back to:\n"
            f"     {self.config.app.base_dir}\n\n"
            "  Step 4/4:  flashback_to_restore_point.sh\n"
            "     sqlplus / as sysdba\n"
            "     FLASHBACK DATABASE TO RESTORE POINT ...\n"
            "     ALTER DATABASE OPEN RESETLOGS\n"
            "     ALTER PLUGGABLE DATABASE ALL OPEN"
            + demo_note
            + "\n\n"
            "WARNING: This ROLLS BACK the database. It cannot be undone.\n"
            "Continue?",
        ):
            return

        # Step 2 — Session check (informational, WARN or BLOCK)
        if not self._maybe_demo_session_check():
            return

        # Step 3 — Select restore point from dropdown + retype confirmation
        _ensure_restore_points(self)
        options = [p.name for p in self.demo_restore_points] if self.config.demo.enabled else None
        sel = confirm_restore_point_flow(options)
        if not sel:
            return

        tasks = [
            ("shutdown_app_services", self.config.scripts["shutdown_app_services"], []),
            ("create_backup",         self.config.scripts["create_backup"],         []),
            ("restore_backup",        self.config.scripts["restore_backup"],        [sel.restore_point]),
            ("flashback_restore",     self.config.scripts["flashback_restore"],     [sel.restore_point]),
        ]
        self._append_line(
            f"[execute] Restore to '{sel.restore_point}' — starting.", _TAG_RUN
        )
        self._scripts.start(
            tasks,
            workflow_name=f"Restore to '{sel.restore_point}'",
            env=self._script_env(),
        )

    def _on_test_connectivity(self) -> None:
        """Utility: Run the connectivity test script."""
        key = "test_connectivity"
        p = self.config.scripts.get(key)
        if not p or not p.exists():
            messagebox.showerror(
                "Missing Script",
                f"Script '{key}' not found:\n{p}\n\nCheck scripts section in config.json.",
            )
            return
        if not confirm_yes_no("Test Connectivity", "Run connectivity test script now?"):
            return

        self._scripts.start(
            [("test_connectivity", p, [])],
            workflow_name="Test Connectivity",
            env=self._demo_env(),
        )

    def _on_abort(self) -> None:
        """Abort the currently running script."""
        if not messagebox.askyesno(
            "Abort Workflow",
            "Are you sure you want to abort the running script?\n"
            "The current script will be terminated (SIGTERM, then SIGKILL).",
        ):
            return
        self._scripts.abort()

    def _on_show_restore_points(self) -> None:
        """Display restore points from demo JSON."""
        if not self.config.demo.enabled:
            messagebox.showinfo("Demo Disabled", "demo.enabled=false in config.json.")
            return
        self.demo_restore_points = load_restore_points(self.config.demo.restore_points_file)
        self._append_line("[demo] Restore points:", _TAG_INFO)
        for line in format_restore_points_table(self.demo_restore_points):
            self._append_line(f"  {line}", _TAG_DIM)

    # ── Session check (demo) ─────────────────────────────────────────────────

    def _maybe_demo_session_check(self) -> bool:
        """Check active sessions in demo mode. Returns False to block workflow."""
        if not self.config.demo.enabled:
            return True
        sessions = load_active_sessions(self.config.demo.sessions_file)
        if not sessions:
            self._append_line("[demo] Session check: no sessions found.", _TAG_INFO)
            return True

        active = [s for s in sessions if s.get("status", "").upper() == "ACTIVE"]
        tag = _TAG_WARN if active else _TAG_INFO
        self._append_line(
            f"[demo] Session check: total={len(sessions)}, active={len(active)}"
            f" (soa_action={self.config.demo.soa_action})",
            tag,
        )

        if self.config.demo.soa_action == "BLOCK" and active:
            messagebox.showwarning(
                "Session Blocked",
                f"{len(active)} active session(s) detected.\n"
                "soa_action=BLOCK: workflow not permitted while sessions are active.\n\n"
                "Disconnect all sessions and try again.",
            )
            return False
        return True

    # ── Text widget helpers ───────────────────────────────────────────────────

    def _append_line(self, line: str, tag: str = _TAG_INFO) -> None:
        self.log_text.configure(state="normal")
        self.log_text.insert("end", line + "\n", tag)
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _clear_output(self) -> None:
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")

    def _print_workflow(self, steps) -> None:
        """Print dry-run step list to the output area."""
        for s in steps:
            logging.info("STEP %02d | %s", s.number, s.title)
            self._append_line(f"STEP {s.number:02d} | {s.title}", _TAG_STEP)
            for line in s.detail.splitlines():
                logging.info("        %s", line)
                self._append_line(f"         {line}", _TAG_DIM)
        self._append_line("Dry-run complete. No SSH/SQL/tar executed.  OK", _TAG_OK)

    def _set_execute_buttons_enabled(self, enabled: bool) -> None:
        state = "normal" if enabled else "disabled"
        for b in (self.btn_create_dry, self.btn_restore_dry,
                  self.btn_create_exec, self.btn_restore_exec, self.btn_test):
            b.configure(state=state)

    def _set_abort_enabled(self, enabled: bool) -> None:
        self.btn_abort.configure(state="normal" if enabled else "disabled")

    def _set_status(self, text: str) -> None:
        self.status_var.set(text)


# ---------------------------------------------------------------------------
# Module-level helpers
# ---------------------------------------------------------------------------

def _ensure_restore_points(gui: FlashbackGUI) -> None:
    """Reload restore points from demo file if the cache is empty."""
    if gui.config.demo.enabled and not gui.demo_restore_points:
        gui.demo_restore_points = load_restore_points(gui.config.demo.restore_points_file)


def _classify_line(line: str) -> str:
    """Classify a script output line to a colour tag based on content prefix."""
    low = line.lower().strip()
    if any(low.startswith(p) for p in (
        "[error]", "error:", "ora-", "failed", "cannot", "not found",
    )):
        return _TAG_ERROR
    if any(low.startswith(p) for p in ("[warn]", "warning:", "[timeout]")):
        return _TAG_WARN
    if any(low.startswith(p) for p in (
        "[run]", "[exit]", "[abort]", "starting workflow", "workflow",
    )):
        return _TAG_RUN
    if any(low.startswith(p) for p in (
        "[demo]", "demo mode", "[demo mode]",
    )):
        return _TAG_WARN
    if "ok" in low and ("check" in low or "complete" in low or "passed" in low):
        return _TAG_OK
    return _TAG_INFO


def _send_notify(cfg, workflow: str, status: str, run_id: str, log_path) -> None:
    """Fire email notification (non-blocking)."""
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
        run_id=run_id,
        operator_id=cfg.operator_id,
        log_path=log_path,
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def run_gui() -> None:
    """Create the root Tk window and launch the GUI event loop."""
    root = tk.Tk()
    try:
        ttk.Style().theme_use("clam")
    except Exception:
        pass
    FlashbackGUI(root)
    root.mainloop()
