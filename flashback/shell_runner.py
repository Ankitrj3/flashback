from __future__ import annotations

"""
shell_runner.py — Shell execution helper with timeout and abort support.

Goals:
  - Run POSIX `sh` scripts on Linux/macOS directly.
  - On Windows, run scripts via Git Bash or WSL (configurable via config.json).
  - Stream script stdout+stderr back to callers (GUI queue, CLI stdout).
  - Support per-script timeouts: SIGTERM after timeout, SIGKILL after grace period.
  - Support abort: operator can cancel a running script mid-flight.

Shell detection order (auto mode, Windows):
  1. Git Bash (`C:\\Program Files\\Git\\bin\\bash.exe` or common locations)
  2. WSL (`wsl.exe sh`)
  3. Any `bash` on PATH (excluding C:\\Windows\\System32\\bash.exe without WSL)

Design principle: this module never touches Oracle — it only knows how to
launch a process and plumb its output. All DB/SSH logic is in the .sh scripts.
"""

import logging
import os
import shutil
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from queue import Queue


# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

def _bash_quote(value: str) -> str:
    """POSIX-safe single-quote escaping."""
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _is_windows() -> bool:
    return os.name == "nt"


def _win_to_wsl_path(path: Path) -> str:
    """Convert a Windows absolute path to a WSL /mnt/... path."""
    # E:\Task\foo  →  /mnt/e/Task/foo
    drive = path.drive.rstrip(":").lower()
    rest = path.as_posix().split(":", 1)[-1]
    if rest.startswith("/"):
        rest = rest[1:]
    return f"/mnt/{drive}/{rest}"


def _detect_git_bash() -> str | None:
    """Return the path to Git Bash exe if found in standard locations."""
    candidates = [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\usr\bin\bash.exe",
    ]
    for c in candidates:
        if Path(c).exists():
            return c
    return None


def _detect_bash(bash_path_hint: str | None) -> str | None:
    if bash_path_hint:
        p = Path(bash_path_hint)
        if p.exists():
            return str(p)
    return shutil.which("bash")


def _detect_sh() -> str | None:
    return shutil.which("sh")


def _wsl_available() -> bool:
    """Return True if WSL is installed and responding."""
    if not shutil.which("wsl"):
        return False
    try:
        subprocess.run(
            ["wsl", "-e", "sh", "-c", "exit 0"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=True,
        )
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Result type
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class RunResult:
    """Outcome of a completed script run."""
    exit_code: int
    aborted: bool = False
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        return self.exit_code == 0 and not self.aborted and not self.timed_out


# ---------------------------------------------------------------------------
# ShellRunner
# ---------------------------------------------------------------------------

class ShellRunner:
    """
    Builds shell commands and executes .sh scripts, optionally with a timeout
    and an abort mechanism.

    Usage (GUI):
        runner = ShellRunner(cfg.shell_mode, cfg.bash_path)
        thread = runner.run_in_thread(
            path, args, output_queue, done_queue,
            timeout_secs=cfg.timeout.script_timeout_secs
        )

    Usage (CLI):
        cmd = runner.build_command(script_path, args)
        proc = subprocess.Popen(cmd, ...)

    Abort:
        runner.abort()   # thread-safe; sends SIGTERM/SIGKILL to the subprocess
    """

    def __init__(self, shell_mode: str, bash_path: str | None) -> None:
        self.shell_mode = (shell_mode or "auto").lower()
        self.bash_path = bash_path
        self._lock = threading.Lock()
        self._current_proc: subprocess.Popen | None = None  # guarded by _lock
        self._abort_requested = threading.Event()

    # ------------------------------------------------------------------
    # Command building
    # ------------------------------------------------------------------

    def build_command(self, script_path: Path, args: list[str]) -> list[str]:
        """
        Return the full command list to execute script_path with args.

        Raises:
            FileNotFoundError: if script_path does not exist.
            RuntimeError:      if no usable shell is found.
        """
        if not script_path.exists():
            raise FileNotFoundError(f"Script not found: {script_path}")

        if _is_windows():
            return self._build_windows_command(script_path, args)

        # POSIX: use sh directly
        sh = _detect_sh() or "sh"
        return [sh, str(script_path.resolve()), *args]

    def _build_windows_command(self, script_path: Path, args: list[str]) -> list[str]:
        """Build command for Windows (Git Bash / WSL)."""
        mode = self.shell_mode

        if mode == "bash":
            bash = _detect_git_bash() or _detect_bash(self.bash_path)
            if self._is_system_bash_without_wsl(bash):
                bash = None
            if not bash:
                raise RuntimeError(
                    "shell_mode=bash but no bash.exe found. "
                    "Install Git for Windows or set bash_path in config.json."
                )
            return [bash, str(script_path.resolve()), *args]

        if mode == "wsl":
            wsl_script = _win_to_wsl_path(script_path.resolve())
            full = " ".join(["sh", _bash_quote(wsl_script), *(_bash_quote(a) for a in args)])
            return ["wsl", "sh", "-lc", full]

        # auto: prefer Git Bash → WSL → any bash
        bash = _detect_git_bash() or _detect_bash(self.bash_path)
        if self._is_system_bash_without_wsl(bash):
            bash = None
        if bash:
            return [bash, str(script_path.resolve()), *args]

        if _wsl_available():
            wsl_script = _win_to_wsl_path(script_path.resolve())
            full = " ".join(["sh", _bash_quote(wsl_script), *(_bash_quote(a) for a in args)])
            return ["wsl", "sh", "-lc", full]

        bash = _detect_bash(self.bash_path)
        if bash:
            return [bash, str(script_path.resolve()), *args]

        raise RuntimeError(
            "No usable shell found on Windows. "
            "Install Git for Windows or WSL, or set shell_mode/bash_path in config.json."
        )

    @staticmethod
    def _is_system_bash_without_wsl(bash: str | None) -> bool:
        """Return True if bash points to the WSL stub without a working WSL."""
        if not bash:
            return False
        stub = Path(r"C:\Windows\System32\bash.exe")
        try:
            if Path(bash).resolve() == stub.resolve():
                return not _wsl_available()
        except Exception:
            pass
        return False

    # ------------------------------------------------------------------
    # Abort support
    # ------------------------------------------------------------------

    def abort(self) -> None:
        """
        Request abort of the currently running script.

        Sends SIGTERM immediately, then SIGKILL after a 5-second grace period
        if the process is still running. Thread-safe.
        """
        self._abort_requested.set()
        with self._lock:
            proc = self._current_proc
        if proc is None:
            return
        logging.warning("[abort] Sending SIGTERM to subprocess pid=%s", proc.pid)
        try:
            if _is_windows():
                proc.terminate()
            else:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)  # type: ignore[attr-defined]
        except Exception as exc:
            logging.warning("[abort] Failed to SIGTERM: %s", exc)

        # Grace period: if still alive after 5s, SIGKILL
        def _force_kill() -> None:
            time.sleep(5)
            with self._lock:
                p = self._current_proc
            if p is not None and p.poll() is None:
                logging.warning("[abort] Grace period elapsed; sending SIGKILL to pid=%s", p.pid)
                try:
                    p.kill()
                except Exception as exc2:
                    logging.warning("[abort] Failed to SIGKILL: %s", exc2)

        threading.Thread(target=_force_kill, daemon=True).start()

    def _clear_abort(self) -> None:
        """Reset abort state before starting a new script."""
        self._abort_requested.clear()

    # ------------------------------------------------------------------
    # Execution
    # ------------------------------------------------------------------

    def run_streaming(
        self,
        script_path: Path,
        args: list[str],
        output_queue: "Queue[str]",
        done_queue: "Queue[RunResult]",
        env: dict[str, str] | None = None,
        timeout_secs: int = 0,
    ) -> None:
        """
        Execute script_path with args, streaming output lines into output_queue.
        Posts a RunResult to done_queue when the script finishes, is aborted,
        or times out.

        This method is intended to be called from a daemon thread.

        Args:
            script_path:   Path to the .sh script.
            args:          Positional arguments for the script.
            output_queue:  Lines of stdout/stderr are put here as str.
            done_queue:    RunResult is put here on completion.
            env:           Optional extra environment variables.
            timeout_secs:  0 = no timeout; >0 = SIGTERM after this many seconds.
        """
        self._clear_abort()
        cmd = self.build_command(script_path, args)
        logging.info("[run] Command: %s", " ".join(str(c) for c in cmd))

        # Use process groups on POSIX so we can kill the whole tree
        kwargs: dict = dict(
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env={**os.environ, **(env or {})},
        )
        if not _is_windows():
            kwargs["start_new_session"] = True  # creates a process group

        proc = subprocess.Popen(cmd, **kwargs)

        with self._lock:
            self._current_proc = proc

        aborted = False
        timed_out = False
        start_time = time.monotonic()

        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                output_queue.put(line.rstrip("\n"))

                # Check abort flag
                if self._abort_requested.is_set():
                    aborted = True
                    break

                # Check timeout
                if timeout_secs > 0 and (time.monotonic() - start_time) > timeout_secs:
                    timed_out = True
                    output_queue.put(
                        f"[timeout] Script exceeded {timeout_secs}s limit. Terminating."
                    )
                    logging.warning(
                        "[timeout] Script %s exceeded %ss. Aborting.", script_path.name, timeout_secs
                    )
                    self.abort()
                    break

        except Exception as exc:
            output_queue.put(f"[error] Read error: {exc}")
            logging.exception("[run] Unexpected error reading script output: %s", script_path)

        finally:
            # Drain remaining stdout lines after abort/timeout
            try:
                if proc.stdout:
                    for line in proc.stdout:
                        output_queue.put(line.rstrip("\n"))
            except Exception:
                pass

            exit_code = proc.wait()
            with self._lock:
                self._current_proc = None

            result = RunResult(exit_code=exit_code, aborted=aborted, timed_out=timed_out)
            done_queue.put(result)
            logging.info(
                "[run] %s finished: exit_code=%s aborted=%s timed_out=%s",
                script_path.name,
                exit_code,
                aborted,
                timed_out,
            )

    def run_in_thread(
        self,
        script_path: Path,
        args: list[str],
        output_queue: "Queue[str]",
        done_queue: "Queue[RunResult]",
        env: dict[str, str] | None = None,
        timeout_secs: int = 0,
    ) -> threading.Thread:
        """
        Launch run_streaming() in a daemon thread and return the thread.

        The caller must poll done_queue (or join the thread) to know when
        the script finishes.
        """
        t = threading.Thread(
            target=self.run_streaming,
            args=(script_path, args, output_queue, done_queue, env, timeout_secs),
            daemon=True,
            name=f"script-{script_path.stem}",
        )
        t.start()
        return t

    # ------------------------------------------------------------------
    # Back-compat alias (used by older callers in this repo)
    # ------------------------------------------------------------------

    def _build_command(self, script_path: Path, args: list[str]) -> list[str]:
        """Deprecated alias for build_command(). Use build_command() directly."""
        return self.build_command(script_path, args)
