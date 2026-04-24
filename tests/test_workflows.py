"""
tests/test_workflows.py — Unit tests for dry-run workflow step definitions.

Tests:
  - Create workflow has expected step count and key titles.
  - Restore workflow includes the restore point name in step details.
  - Steps are numbered sequentially starting from 1.
  - Step objects are frozen (immutable).
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from flashback.workflows import Step, dry_run_create_steps, dry_run_restore_steps


class TestDryRunCreateSteps:
    def test_returns_list_of_steps(self) -> None:
        steps = dry_run_create_steps()
        assert isinstance(steps, list)
        assert len(steps) > 0

    def test_step_count(self) -> None:
        steps = dry_run_create_steps()
        assert len(steps) == 6  # pre-flight, confirm, backup, db, log, email

    def test_steps_numbered_sequentially(self) -> None:
        steps = dry_run_create_steps()
        for i, step in enumerate(steps, start=1):
            assert step.number == i

    def test_first_step_is_preflight(self) -> None:
        steps = dry_run_create_steps()
        assert "Pre-flight" in steps[0].title or "pre-flight" in steps[0].title.lower()

    def test_last_step_is_email(self) -> None:
        steps = dry_run_create_steps()
        assert "Email" in steps[-1].title or "mail" in steps[-1].title.lower()

    def test_steps_have_non_empty_detail(self) -> None:
        for step in dry_run_create_steps():
            assert step.detail.strip(), f"Step {step.number} has empty detail"

    def test_step_is_frozen(self) -> None:
        step = dry_run_create_steps()[0]
        with pytest.raises((AttributeError, TypeError)):
            step.number = 999  # type: ignore[misc]


class TestDryRunRestoreSteps:
    def test_returns_list_of_steps(self) -> None:
        steps = dry_run_restore_steps("MY_RP_001")
        assert isinstance(steps, list)
        assert len(steps) > 0

    def test_step_count(self) -> None:
        steps = dry_run_restore_steps("MY_RP")
        # 10 steps: pre-flight, confirm, session-check, shutdown-services,
        #           rp-select, safety-backup, fs-restore, db-flashback, log, email
        assert len(steps) == 10

    def test_restore_point_in_step_details(self) -> None:
        rp = "FB_PROD_20260422_1200"
        steps = dry_run_restore_steps(rp)
        # The restore point name must appear somewhere in the steps
        all_text = " ".join(s.detail for s in steps)
        assert rp in all_text

    def test_steps_numbered_sequentially(self) -> None:
        steps = dry_run_restore_steps("TEST_RP")
        for i, step in enumerate(steps, start=1):
            assert step.number == i

    def test_flashback_step_contains_sql_keyword(self) -> None:
        steps = dry_run_restore_steps("MY_RP")
        all_text = " ".join(s.detail for s in steps)
        # The actual Oracle command should be mentioned
        assert "FLASHBACK" in all_text.upper()

    def test_different_restore_points_give_different_details(self) -> None:
        steps_a = dry_run_restore_steps("RP_A")
        steps_b = dry_run_restore_steps("RP_B")
        # At least one step should differ
        details_a = [s.detail for s in steps_a]
        details_b = [s.detail for s in steps_b]
        assert details_a != details_b


class TestStepDataclass:
    def test_step_equality(self) -> None:
        s1 = Step(1, "Title", "Detail")
        s2 = Step(1, "Title", "Detail")
        assert s1 == s2

    def test_step_inequality(self) -> None:
        s1 = Step(1, "Title A", "Detail")
        s2 = Step(1, "Title B", "Detail")
        assert s1 != s2
