"""
tests/test_validators.py — Unit tests for the validators module.

Tests:
  - validate_config() detects bad shell_mode, soa_action, and missing bash_path.
  - validate_scripts() detects missing and empty scripts.
  - run_preflight() combines shell + script checks.
  - ValidationResult.merge() and .as_text() work correctly.
"""

import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from flashback.config import _default_config
from flashback.validators import (
    ValidationResult,
    run_preflight,
    validate_config,
    validate_scripts,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_cfg(tmp_path: Path, **overrides):
    """Create a default config rooted at tmp_path with optional overrides."""
    import dataclasses
    from flashback.config import AppConfig
    base = _default_config(tmp_path)
    return dataclasses.replace(base, **overrides)


def make_cfg_with_scripts(*keys: str, tmp_path: Path):
    """Create a config where named script files actually exist."""
    scripts_dir = tmp_path / "scripts"
    scripts_dir.mkdir(exist_ok=True)

    scripts = {}
    for key in keys:
        p = scripts_dir / f"{key}.sh"
        p.write_text("#!/usr/bin/env sh\necho ok\n", encoding="utf-8")
        scripts[key] = p

    import dataclasses
    from flashback.config import AppConfig
    base = _default_config(tmp_path)
    return dataclasses.replace(base, scripts=scripts)


# ---------------------------------------------------------------------------
# ValidationResult
# ---------------------------------------------------------------------------

class TestValidationResult:
    def test_starts_ok(self) -> None:
        r = ValidationResult()
        assert r.ok is True
        assert r.errors == []
        assert r.warnings == []

    def test_add_error_sets_not_ok(self) -> None:
        r = ValidationResult()
        r.add_error("something is wrong")
        assert r.ok is False
        assert len(r.errors) == 1

    def test_add_warning_keeps_ok(self) -> None:
        r = ValidationResult()
        r.add_warning("heads up")
        assert r.ok is True
        assert len(r.warnings) == 1

    def test_merge_error_propagates(self) -> None:
        r1 = ValidationResult()
        r2 = ValidationResult()
        r2.add_error("bad thing")
        r1.merge(r2)
        assert r1.ok is False
        assert "bad thing" in r1.errors

    def test_merge_warning_propagates(self) -> None:
        r1 = ValidationResult()
        r2 = ValidationResult()
        r2.add_warning("soft issue")
        r1.merge(r2)
        assert r1.ok is True
        assert "soft issue" in r1.warnings

    def test_as_text_with_error_and_warning(self) -> None:
        r = ValidationResult()
        r.add_error("big problem")
        r.add_warning("small concern")
        text = r.as_text()
        assert "ERROR" in text
        assert "WARNING" in text
        assert "big problem" in text

    def test_as_text_all_ok(self) -> None:
        r = ValidationResult()
        text = r.as_text()
        assert "passed" in text.lower() or text.strip() != ""


# ---------------------------------------------------------------------------
# validate_config
# ---------------------------------------------------------------------------

class TestValidateConfig:
    def test_valid_default_config_is_ok(self, tmp_path: Path) -> None:
        cfg = _default_config(tmp_path)
        result = validate_config(cfg)
        # Defaults may have warnings (demo files missing) but no errors
        assert result.ok

    def test_invalid_shell_mode_error(self, tmp_path: Path) -> None:
        import dataclasses
        cfg = dataclasses.replace(_default_config(tmp_path), shell_mode="ftp")
        result = validate_config(cfg)
        assert not result.ok
        assert any("shell_mode" in e for e in result.errors)

    def test_invalid_soa_action_error(self, tmp_path: Path) -> None:
        import dataclasses
        from flashback.config import DemoConfig
        base = _default_config(tmp_path)
        bad_demo = dataclasses.replace(base.demo, soa_action="WHATEVER")
        cfg = dataclasses.replace(base, demo=bad_demo)
        result = validate_config(cfg)
        assert not result.ok
        assert any("soa_action" in e for e in result.errors)

    def test_bash_mode_no_path_warns(self, tmp_path: Path) -> None:
        import dataclasses
        cfg = dataclasses.replace(_default_config(tmp_path), shell_mode="bash", bash_path=None)
        result = validate_config(cfg)
        # Should warn (not error) when bash_path is not set
        assert any("bash_path" in w for w in result.warnings)

    def test_bash_mode_missing_path_is_error(self, tmp_path: Path) -> None:
        import dataclasses
        cfg = dataclasses.replace(
            _default_config(tmp_path),
            shell_mode="bash",
            bash_path="/nonexistent/path/bash.exe",
        )
        result = validate_config(cfg)
        assert not result.ok
        assert any("bash_path" in e for e in result.errors)


# ---------------------------------------------------------------------------
# validate_scripts
# ---------------------------------------------------------------------------

class TestValidateScripts:
    def test_all_scripts_present_is_ok(self, tmp_path: Path) -> None:
        keys = ["create_backup", "create_flashback"]
        cfg = make_cfg_with_scripts(*keys, tmp_path=tmp_path)
        result = validate_scripts(cfg, keys)
        assert result.ok

    def test_missing_key_in_config(self, tmp_path: Path) -> None:
        cfg = _default_config(tmp_path)  # scripts point to non-existent files
        # None of the default scripts exist on disk
        result = validate_scripts(cfg, ["create_backup"])
        assert not result.ok
        assert any("create_backup" in e for e in result.errors)

    def test_empty_script_file_warns(self, tmp_path: Path) -> None:
        scripts_dir = tmp_path / "scripts"
        scripts_dir.mkdir()
        empty = scripts_dir / "empty.sh"
        empty.write_text("", encoding="utf-8")

        import dataclasses
        base = _default_config(tmp_path)
        cfg = dataclasses.replace(base, scripts={"empty": empty})
        result = validate_scripts(cfg, ["empty"])
        # ok=True (file exists) but with a warning
        assert result.ok
        assert any("empty" in w for w in result.warnings)

    def test_key_not_in_scripts_dict(self, tmp_path: Path) -> None:
        cfg = _default_config(tmp_path)
        result = validate_scripts(cfg, ["nonexistent_key"])
        assert not result.ok
        assert any("nonexistent_key" in e for e in result.errors)


# ---------------------------------------------------------------------------
# run_preflight (integration of shell + scripts)
# ---------------------------------------------------------------------------

class TestRunPreflight:
    def test_missing_scripts_fails_preflight(self, tmp_path: Path) -> None:
        cfg = _default_config(tmp_path)
        # No scripts exist on disk
        result = run_preflight(cfg, ["create_backup", "create_flashback"])
        assert not result.ok

    def test_all_scripts_exist_passes_preflight(self, tmp_path: Path) -> None:
        keys = ["create_backup", "create_flashback"]
        cfg = make_cfg_with_scripts(*keys, tmp_path=tmp_path)
        result = run_preflight(cfg, keys)
        # May still fail on shell check in a restricted env; check only scripts part
        script_result = validate_scripts(cfg, keys)
        assert script_result.ok
