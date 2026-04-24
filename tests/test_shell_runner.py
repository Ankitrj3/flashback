"""
tests/test_shell_runner.py — Unit tests for ShellRunner.

Tests:
  - build_command() builds correct command lists on POSIX.
  - RunResult dataclass behaviour.
  - _win_to_wsl_path() path conversion.
  - ShellRunner can actually run a simple script and capture output.
"""

import os
import sys
import tempfile
from pathlib import Path
from queue import Queue

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from flashback.shell_runner import RunResult, ShellRunner, _win_to_wsl_path


# ---------------------------------------------------------------------------
# RunResult
# ---------------------------------------------------------------------------

class TestRunResult:
    def test_ok_when_exit_zero(self) -> None:
        r = RunResult(exit_code=0)
        assert r.ok is True

    def test_not_ok_when_exit_nonzero(self) -> None:
        r = RunResult(exit_code=1)
        assert r.ok is False

    def test_not_ok_when_aborted(self) -> None:
        r = RunResult(exit_code=0, aborted=True)
        assert r.ok is False

    def test_not_ok_when_timed_out(self) -> None:
        r = RunResult(exit_code=0, timed_out=True)
        assert r.ok is False

    def test_frozen(self) -> None:
        r = RunResult(exit_code=0)
        with pytest.raises((AttributeError, TypeError)):
            r.exit_code = 99  # type: ignore[misc]


# ---------------------------------------------------------------------------
# _win_to_wsl_path
# ---------------------------------------------------------------------------

class TestWinToWslPath:
    def test_simple_path(self) -> None:
        p = Path("E:\\Task\\flashback\\scripts\\test.sh")
        result = _win_to_wsl_path(p)
        assert result == "/mnt/e/Task/flashback/scripts/test.sh"

    def test_c_drive(self) -> None:
        p = Path("C:\\Users\\oracle\\script.sh")
        result = _win_to_wsl_path(p)
        assert result.startswith("/mnt/c/")

    def test_lowercase_drive(self) -> None:
        p = Path("d:\\data\\backup.sh")
        result = _win_to_wsl_path(p)
        assert result.startswith("/mnt/d/")


# ---------------------------------------------------------------------------
# ShellRunner.build_command (POSIX only — skip on Windows)
# ---------------------------------------------------------------------------

@pytest.mark.skipif(os.name == "nt", reason="POSIX-only test")
class TestBuildCommandPosix:
    def test_returns_list(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".sh", delete=False) as f:
            script = Path(f.name)
        try:
            script.write_text("#!/usr/bin/env sh\necho ok\n")
            runner = ShellRunner("auto", None)
            cmd = runner.build_command(script, [])
            assert isinstance(cmd, list)
            assert len(cmd) >= 2
        finally:
            script.unlink(missing_ok=True)

    def test_args_appended(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".sh", delete=False) as f:
            script = Path(f.name)
        try:
            script.write_text("#!/usr/bin/env sh\necho $1\n")
            runner = ShellRunner("auto", None)
            cmd = runner.build_command(script, ["MY_RP"])
            assert "MY_RP" in cmd
        finally:
            script.unlink(missing_ok=True)

    def test_missing_script_raises(self) -> None:
        runner = ShellRunner("auto", None)
        with pytest.raises(FileNotFoundError):
            runner.build_command(Path("/nonexistent/script.sh"), [])


# ---------------------------------------------------------------------------
# ShellRunner.run_in_thread integration (POSIX only)
# ---------------------------------------------------------------------------

@pytest.mark.skipif(os.name == "nt", reason="POSIX-only integration test")
class TestRunInThread:
    def test_simple_echo_script(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".sh", delete=False, mode="w") as f:
            f.write("#!/usr/bin/env sh\necho HELLO_FROM_SCRIPT\nexit 0\n")
            script = Path(f.name)
        script.chmod(0o755)

        try:
            output_q: Queue[str] = Queue()
            done_q: Queue[RunResult] = Queue()

            runner = ShellRunner("auto", None)
            t = runner.run_in_thread(script, [], output_q, done_q)
            t.join(timeout=10)

            result = done_q.get_nowait()
            assert result.exit_code == 0
            assert result.ok is True

            lines = []
            while not output_q.empty():
                lines.append(output_q.get_nowait())
            assert any("HELLO_FROM_SCRIPT" in line for line in lines)

        finally:
            script.unlink(missing_ok=True)

    def test_failing_script_returns_nonzero(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".sh", delete=False, mode="w") as f:
            f.write("#!/usr/bin/env sh\nexit 42\n")
            script = Path(f.name)
        script.chmod(0o755)

        try:
            output_q: Queue[str] = Queue()
            done_q: Queue[RunResult] = Queue()

            runner = ShellRunner("auto", None)
            t = runner.run_in_thread(script, [], output_q, done_q)
            t.join(timeout=10)

            result = done_q.get_nowait()
            assert result.exit_code == 42
            assert result.ok is False

        finally:
            script.unlink(missing_ok=True)
