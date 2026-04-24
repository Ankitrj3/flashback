"""
tests/test_config.py — Unit tests for the config loader.

Tests:
  - Default config is returned when no config.json exists.
  - Values from config.json override defaults.
  - Malformed config.json falls back to defaults (no crash).
  - Email, preflight, timeout, logging sections are parsed correctly.
  - _coerce_soa normalises soa_action values.
"""

import json
import os
import sys
from pathlib import Path

import pytest

# Ensure flashback is importable regardless of cwd
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from flashback.config import (
    TOOL_VERSION,
    _coerce_soa,
    _default_config,
    load_config,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def write_config(tmp_path: Path, data: dict) -> None:
    (tmp_path / "config.json").write_text(json.dumps(data), encoding="utf-8")


# ---------------------------------------------------------------------------
# Default config
# ---------------------------------------------------------------------------

class TestDefaultConfig:
    def test_shell_mode_is_auto(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.shell_mode == "auto"

    def test_demo_enabled_by_default(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.demo.enabled is True

    def test_soa_action_default_warn(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.demo.soa_action == "WARN"

    def test_all_default_script_keys_present(self, tmp_path: Path) -> None:
        expected_keys = {
            "test_connectivity",
            "shutdown_app_services",
            "list_restore_points",
            "create_backup",
            "restore_backup",
            "create_flashback",
            "flashback_restore",
        }
        cfg = load_config(tmp_path)
        assert expected_keys <= set(cfg.scripts.keys())

    def test_instance_id_default(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.instance_id == "RXEST01"

    def test_oracle_config_defaults(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.oracle.auth_mode == "os"
        assert cfg.oracle.pdb_name == "RXEST01"
        assert cfg.oracle.db_user == "sys"

    def test_app_config_defaults(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.app.ssh_user == "oracle"
        assert cfg.app.base_dir == "/db8000/app/oracle/r122rxest01"

    def test_backup_config_defaults(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.backup.dir == "/iriscommon/backups/tars"
        assert cfg.backup.filesystems == ["fs_ne", "fs1", "fs2"]

    def test_tool_version_set(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.tool_version == TOOL_VERSION

    def test_email_disabled_by_default(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.email.enabled is False

    def test_preflight_enabled_by_default(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.preflight.run_connectivity_before_execute is True

    def test_timeout_defaults(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        # Default bumped to 7200s (2h) to accommodate large EBS filesystem tars
        assert cfg.timeout.script_timeout_secs == 7200
        assert cfg.timeout.connectivity_timeout_secs == 30

    def test_log_max_files_default(self, tmp_path: Path) -> None:
        cfg = load_config(tmp_path)
        assert cfg.logging.max_log_files == 30


# ---------------------------------------------------------------------------
# Config.json overrides
# ---------------------------------------------------------------------------

class TestConfigJsonOverrides:
    def test_shell_mode_override(self, tmp_path: Path) -> None:
        write_config(tmp_path, {"shell_mode": "wsl"})
        cfg = load_config(tmp_path)
        assert cfg.shell_mode == "wsl"

    def test_demo_disabled(self, tmp_path: Path) -> None:
        write_config(tmp_path, {"demo": {"enabled": False}})
        cfg = load_config(tmp_path)
        assert cfg.demo.enabled is False

    def test_soa_action_block(self, tmp_path: Path) -> None:
        write_config(tmp_path, {"demo": {"soa_action": "BLOCK"}})
        cfg = load_config(tmp_path)
        assert cfg.demo.soa_action == "BLOCK"

    def test_email_section_parsed(self, tmp_path: Path) -> None:
        write_config(tmp_path, {
            "email": {
                "enabled": True,
                "smtp_host": "smtp.test.com",
                "smtp_port": 465,
                "from_addr": "from@test.com",
                "to_addrs": ["a@b.com", "c@d.com"],
                "use_tls": False,
            }
        })
        cfg = load_config(tmp_path)
        assert cfg.email.enabled is True
        assert cfg.email.smtp_host == "smtp.test.com"
        assert cfg.email.smtp_port == 465
        assert cfg.email.to_addrs == ["a@b.com", "c@d.com"]
        assert cfg.email.use_tls is False

    def test_timeout_override(self, tmp_path: Path) -> None:
        write_config(tmp_path, {
            "timeout": {"script_timeout_secs": 600, "connectivity_timeout_secs": 10}
        })
        cfg = load_config(tmp_path)
        assert cfg.timeout.script_timeout_secs == 600
        assert cfg.timeout.connectivity_timeout_secs == 10

    def test_custom_script_path_merged_with_defaults(self, tmp_path: Path) -> None:
        (tmp_path / "scripts").mkdir()
        (tmp_path / "scripts" / "my_backup.sh").write_text("#!/usr/bin/env sh\n", encoding="utf-8")

        write_config(tmp_path, {
            "scripts": {"create_backup": "scripts/my_backup.sh"}
        })
        cfg = load_config(tmp_path)
        # Custom path is used
        assert cfg.scripts["create_backup"].name == "my_backup.sh"
        # Other keys still have defaults
        assert "flashback_restore" in cfg.scripts

    def test_preflight_can_be_disabled(self, tmp_path: Path) -> None:
        write_config(tmp_path, {
            "preflight": {"run_connectivity_before_execute": False}
        })
        cfg = load_config(tmp_path)
        assert cfg.preflight.run_connectivity_before_execute is False

    def test_log_dir_override(self, tmp_path: Path) -> None:
        write_config(tmp_path, {"logging": {"log_dir": "custom_logs", "max_log_files": 10}})
        cfg = load_config(tmp_path)
        assert cfg.logging.log_dir == "custom_logs"
        assert cfg.logging.max_log_files == 10

    def test_operator_id_override(self, tmp_path: Path) -> None:
        write_config(tmp_path, {"operator_id": "jsmith"})
        cfg = load_config(tmp_path)
        assert cfg.operator_id == "jsmith"


# ---------------------------------------------------------------------------
# Malformed / bad config.json
# ---------------------------------------------------------------------------

class TestMalformedConfig:
    def test_invalid_json_falls_back_to_defaults(self, tmp_path: Path) -> None:
        (tmp_path / "config.json").write_text("{not valid json}", encoding="utf-8")
        cfg = load_config(tmp_path)
        # Should not raise; returns defaults
        assert cfg.shell_mode == "auto"

    def test_empty_json_object_uses_defaults(self, tmp_path: Path) -> None:
        write_config(tmp_path, {})
        cfg = load_config(tmp_path)
        assert cfg.shell_mode == "auto"
        assert cfg.demo.enabled is True

    def test_extra_unknown_keys_ignored(self, tmp_path: Path) -> None:
        write_config(tmp_path, {"unknown_key": "value", "shell_mode": "bash"})
        cfg = load_config(tmp_path)
        assert cfg.shell_mode == "bash"


# ---------------------------------------------------------------------------
# _coerce_soa helper
# ---------------------------------------------------------------------------

class TestCoerceSoa:
    def test_warn_passthrough(self) -> None:
        assert _coerce_soa("WARN") == "WARN"

    def test_block_passthrough(self) -> None:
        assert _coerce_soa("BLOCK") == "BLOCK"

    def test_lowercase_warn(self) -> None:
        assert _coerce_soa("warn") == "WARN"

    def test_invalid_defaults_to_warn(self) -> None:
        assert _coerce_soa("INVALID") == "WARN"

    def test_empty_defaults_to_warn(self) -> None:
        assert _coerce_soa("") == "WARN"
