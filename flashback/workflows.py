from __future__ import annotations

"""
workflows.py — Dry-run step definitions that exactly mirror real execute steps.

Each dry_run_*_steps() function returns an ordered list of Step objects
describing what WOULD happen in a real execute run. The step descriptions
are kept in sync with what the shell scripts actually do.

v2.1 changes (aligned with client RXEST01 environment):
  - CREATE: backup now produces .tar archives (no compression), parallel nohup
  - CREATE: restore point naming is RXEST01_CDB_flashback_restore_DDMMMYY
  - RESTORE: adds shutdown_app_services.sh as Step 1 (CRITICAL new step)
  - RESTORE: list_restore_points.sh queries live V$RESTORE_POINT for dropdown
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Step:
    """A single named workflow step with a descriptive detail block."""
    number: int
    title: str
    detail: str


# ---------------------------------------------------------------------------
# Create Flashback Request — dry-run steps
# ---------------------------------------------------------------------------

def dry_run_create_steps() -> list[Step]:
    """
    Steps for the 'Create Flashback Request' workflow.

    Real execute order:
      1. Pre-flight validation
      2. Confirmation gates (Yes/No dialog + type YES)
      3. create_backup.sh          — parallel nohup tar of fs_ne, fs1, fs2
      4. create_flashback_restore_point.sh — CDB + PDB guaranteed restore point
      5. Audit log written
      6. Email notification
    """
    return [
        Step(
            1,
            "Pre-flight Validation",
            "WOULD: verify configured shell (Git Bash / WSL / sh) is available.\n"
            "WOULD: check all required script files exist and are non-empty.\n"
            "ABORTS workflow if any check fails.",
        ),
        Step(
            2,
            "Confirmation Gates",
            "Operator confirms with Yes/No dialog (describes all scripts that will run).\n"
            "Operator must then type 'YES' in a text input to proceed.\n"
            "Any Cancel or wrong input aborts the entire workflow.",
        ),
        Step(
            3,
            "Filesystem Backup  [create_backup.sh]",
            "WOULD: cd to $flashback_BASE_DIR (e.g. /db8000/app/oracle/r122rxest01)\n"
            "WOULD: launch 3 tar jobs simultaneously in parallel:\n"
            "  nohup tar -cvf /iriscommon/backups/tars/RXEST01_fs_ne_backup_DDMMMYY.tar  fs_ne &\n"
            "  nohup tar -cvf /iriscommon/backups/tars/RXEST01_fs1_Patch_backup_DDMMMYY.tar fs1 &\n"
            "  nohup tar -cvf /iriscommon/backups/tars/RXEST01_fs2_Run_backup_DDMMMYY.tar  fs2 &\n"
            "WOULD: wait for all 3 to complete and check exit codes.\n"
            "No compression (.tar not .tar.gz) — large EBS filesystems.\n"
            "Script exit code checked; non-zero aborts remaining steps.",
        ),
        Step(
            4,
            "Create DB Restore Points  [create_flashback_restore_point.sh]",
            "WOULD: source Oracle env file: . ./rxecst01.sh\n"
            "WOULD: connect: sqlplus / as sysdba  (OS authentication)\n"
            "WOULD: pre-check: ARCHIVELOG mode + Flashback Database = YES\n"
            "WOULD: CREATE RESTORE POINT \"RXEST01_CDB_flashback_restore_DDMMMYY\" GUARANTEE FLASHBACK DATABASE;\n"
            "WOULD: ALTER SESSION SET CONTAINER=RXEST01;\n"
            "WOULD: CREATE RESTORE POINT \"RXEST01_PDB_flashback_restore_DDMMMYY\" GUARANTEE FLASHBACK DATABASE;\n"
            "WOULD: ALTER SESSION SET CONTAINER=CDB$ROOT;\n"
            "WOULD: SELECT NAME, TIME, GUARANTEE_FLASHBACK_DATABASE, STORAGE_SIZE,\n"
            "               PDB_RESTORE_POINT, CON_ID FROM V$RESTORE_POINT ORDER BY TIME;\n"
            "Script exit code checked; non-zero marks workflow as FAILED.",
        ),
        Step(
            5,
            "Audit Log Written",
            "WOULD: write timestamped run log to logs/flashback_<ts>_<run_id>.log\n"
            "WOULD: log: operator_id, run_id, hostname, Python version, workflow, status.",
        ),
        Step(
            6,
            "Email Notification",
            "WOULD: send completion email to configured to_addrs.\n"
            "WOULD: attach session log file to email.\n"
            "Email failure is logged but does NOT fail the workflow.",
        ),
    ]


# ---------------------------------------------------------------------------
# Restore using Flashback GRP — dry-run steps
# ---------------------------------------------------------------------------

def dry_run_restore_steps(restore_point: str) -> list[Step]:
    """
    Steps for the 'Restore using Flashback GRP' workflow.

    Real execute order:
      1.  Pre-flight validation
      2.  Confirmation gate (Yes/No warning dialog)
      3.  SOA session check (informational WARN, not block by default)
      4.  shutdown_app_services.sh   — CRITICAL: SSH all nodes, stop EBS services
      5.  Restore point selection + retype confirmation
      6.  create_backup.sh           — safety snapshot of current state
      7.  restore_backup.sh          — extract .tar archives back to app nodes
      8.  flashback_to_restore_point.sh — FLASHBACK DATABASE + RESETLOGS + open PDBs
      9.  Audit log written
      10. Email notification
    """
    rp = restore_point
    return [
        Step(
            1,
            "Pre-flight Validation",
            "WOULD: verify configured shell is available.\n"
            "WOULD: check shutdown_app_services.sh, create_backup.sh,\n"
            "       restore_backup.sh, flashback_to_restore_point.sh exist.\n"
            "ABORTS workflow if any check fails.",
        ),
        Step(
            2,
            "Confirmation Gate",
            "Operator confirms with Yes/No dialog (WARNING: ROLLS BACK the database).\n"
            "Any Cancel or No aborts the workflow immediately.",
        ),
        Step(
            3,
            "SOA Session Check  (informational)",
            "WOULD: query V$SESSION for non-background sessions.\n"
            "WOULD: display active connections grouped by username, program, machine.\n"
            "WOULD: if SOA connections found: log WARNING and notify SOA Admins via email.\n"
            "SOA_ACTION=WARN: continues after informing (does NOT block workflow).\n"
            "SOA_ACTION=BLOCK: aborts if active sessions found.\n"
            "[demo] Uses demo/active_sessions.json as session source.",
        ),
        Step(
            4,
            "Shutdown App Node Services  [shutdown_app_services.sh]",
            "WOULD: SSH to each application node:\n"
            "         node2, node3, node4, node5, node6, node7\n"
            "WOULD: for each node:\n"
            "  1) Check if EBS services are running (FNDLIBR, Apache, opmn)\n"
            "  2) Run adstpall.sh to shutdown ALL EBS services\n"
            "  3) Wait 30 seconds\n"
            "  4) Re-check: if processes still running -> ERROR\n"
            "WOULD: All nodes must be confirmed clean before proceeding.\n"
            "Script exit code non-zero = services did not stop = ABORT.",
        ),
        Step(
            5,
            f"Restore Point Selected + Confirmed: {rp}",
            f"Operator selected restore point from dropdown: '{rp}'\n"
            f"Operator re-typed the name to confirm (safety gate).\n"
            f"Variable RESTORE_POINT='{rp}' passed as $1 to restore and flashback scripts.",
        ),
        Step(
            6,
            "Pre-Restore Safety Backup  [create_backup.sh]",
            "WOULD: take a NEW backup of current filesystem state BEFORE restoring.\n"
            "This is a safety net: if the restore fails, you can recover to this state.\n"
            "Same parallel nohup tar approach as the Create workflow.\n"
            "Script exit code checked; non-zero aborts remaining steps.",
        ),
        Step(
            7,
            f"Filesystem Restore  [restore_backup.sh]",
            f"WOULD: find most recent archive matching:\n"
            f"  /iriscommon/backups/tars/RXEST01_fs_ne_backup_*.tar\n"
            f"  /iriscommon/backups/tars/RXEST01_fs1_Patch_backup_*.tar\n"
            f"  /iriscommon/backups/tars/RXEST01_fs2_Run_backup_*.tar\n"
            f"WOULD: cd $APP_BASE_DIR && tar -xvf <archive>\n"
            "Runs sequentially (one filesystem at a time for reliability).\n"
            "Script exit code checked; non-zero aborts remaining steps.",
        ),
        Step(
            8,
            f"Database Flashback  [flashback_to_restore_point.sh]",
            f"WOULD: connect: sqlplus / as sysdba\n"
            f"WOULD: verify '{rp}' exists in V$RESTORE_POINT with GUARANTEE=YES\n"
            f"WOULD: ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE;\n"
            f"WOULD: FLASHBACK DATABASE TO RESTORE POINT \"{rp}\";\n"
            "WOULD: ALTER DATABASE OPEN RESETLOGS;\n"
            "WOULD: ALTER PLUGGABLE DATABASE ALL OPEN;\n"
            "WOULD: SELECT NAME, TIME, GUA, STORAGE_SIZE, PDB, CON_ID\n"
            "       FROM V$RESTORE_POINT ORDER BY TIME;  (final verification)\n"
            "Script exit code checked; non-zero marks workflow as FAILED.",
        ),
        Step(
            9,
            "Audit Log Written",
            "WOULD: write timestamped run log to logs/flashback_<ts>_<run_id>.log\n"
            "WOULD: log: operator_id, run_id, restore_point, hostname, status.",
        ),
        Step(
            10,
            "Email Notification",
            "WOULD: send completion email to configured to_addrs.\n"
            "WOULD: include restore_point name and final status in subject line.\n"
            "WOULD: attach session log file for team reference.\n"
            "Email failure is logged but does NOT fail the workflow.",
        ),
    ]
