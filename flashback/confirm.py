from __future__ import annotations

"""
confirm.py — Confirmation dialog helpers for the Flashback Automation GUI.

All dialogs are modal (grab_set + wait_window). Proper focus management is
applied to prevent the Tkinter "window appears but doesn't respond" bug that
occurs when a Toplevel is shown immediately after another dialog closes.

Key fix: every Toplevel calls lift() + focus_force() + update_idletasks()
BEFORE grab_set() to ensure the window is fully rendered and front-most
before the event loop blocks on wait_window().
"""

from dataclasses import dataclass
import tkinter as tk
from tkinter import messagebox, simpledialog, ttk


@dataclass(frozen=True)
class RestoreSelection:
    """Returned by confirm_restore_point_flow() on success."""
    restore_point: str


# ---------------------------------------------------------------------------
# Simple dialogs (wrappers around standard Tk dialogs)
# ---------------------------------------------------------------------------

def confirm_yes_no(title: str, message: str) -> bool:
    """Show a yes/no messagebox. Returns True if Yes was clicked."""
    return bool(messagebox.askyesno(title=title, message=message))


def require_typed_value(title: str, prompt: str, expected: str) -> bool:
    """
    Show a text-input dialog. Returns True only if the typed value exactly
    matches `expected` (case-sensitive). Returns False on Cancel or mismatch.
    """
    typed = simpledialog.askstring(title=title, prompt=prompt)
    if typed is None:
        return False
    return typed.strip() == expected


def prompt_restore_point(title: str) -> str | None:
    """Show a free-text input dialog for restore point name. Returns None on Cancel."""
    value = simpledialog.askstring(title=title, prompt="Enter restore point name:")
    if value is None:
        return None
    return value.strip() or None


# ---------------------------------------------------------------------------
# Restore point selection — dropdown list (demo mode) or free text
# ---------------------------------------------------------------------------

def select_restore_point_from_list(title: str, prompt: str, options: list[str]) -> str | None:
    """
    Show a modal Toplevel with a Combobox for selecting a restore point.

    This replaces askstring() when restore point names are known in advance
    (demo mode with a pre-loaded restore_points.json).

    Focus management:
      We call update_idletasks() → deiconify() → lift() → focus_force()
      BEFORE grab_set() + wait_window(). This prevents the dialog appearing
      "behind" the parent or losing keyboard focus after a previous dialog.

    Returns:
        Selected restore point name string, or None if cancelled.
    """
    if not options:
        return None

    root = tk._default_root  # type: ignore[attr-defined]
    if root is None:
        return None

    result: dict[str, str | None] = {"value": None}

    # ── Build the window ──
    win = tk.Toplevel(root)
    win.title(title)
    win.resizable(False, False)
    win.withdraw()          # Start hidden; show after widgets are built

    frame = ttk.Frame(win, padding=16)
    frame.pack(fill="both", expand=True)

    ttk.Label(frame, text=prompt, font=("Segoe UI", 10)).pack(anchor="w")

    value_var = tk.StringVar(value=options[0])
    combo = ttk.Combobox(
        frame,
        textvariable=value_var,
        values=options,
        state="readonly",
        width=52,
        font=("Segoe UI", 10),
    )
    combo.pack(fill="x", pady=(8, 4))

    # Show count chip
    ttk.Label(
        frame,
        text=f"{len(options)} restore point(s) available",
        font=("Segoe UI", 8),
        foreground="#888888",
    ).pack(anchor="w", pady=(0, 12))

    # Button row
    btns = ttk.Frame(frame)
    btns.pack(fill="x")

    def _ok() -> None:
        result["value"] = value_var.get().strip() or None
        win.destroy()

    def _cancel() -> None:
        result["value"] = None
        win.destroy()

    ttk.Button(btns, text="Cancel", command=_cancel, width=10).pack(side="right")
    ttk.Button(btns, text="OK", command=_ok, width=10).pack(side="right", padx=(0, 8))

    combo.focus_set()
    win.bind("<Return>", lambda _e: _ok())
    win.bind("<Escape>", lambda _e: _cancel())
    win.protocol("WM_DELETE_WINDOW", _cancel)
    win.transient(root)

    # ── Critical focus sequence ── (fixes disappearing/unresponsive dialog)
    win.update_idletasks()   # Ensure all widget geometry is calculated
    win.deiconify()          # Make visible
    win.lift()               # Raise above parent
    win.focus_force()        # Move OS keyboard focus to this window
    win.grab_set()           # Block all events to parent

    root.wait_window(win)    # Block until win.destroy() is called
    return result["value"]


# ---------------------------------------------------------------------------
# Retype confirmation dialog
# ---------------------------------------------------------------------------

def confirm_retype_value(title: str, expected: str) -> bool:
    """
    Show a Toplevel asking the operator to re-type `expected` exactly.
    Used for restore point name confirmation to prevent typos.

    Returns True only if the entered text matches `expected` exactly.
    """
    root = tk._default_root  # type: ignore[attr-defined]
    if root is None:
        return False

    result: dict[str, bool] = {"ok": False}

    win = tk.Toplevel(root)
    win.title(title)
    win.resizable(False, False)
    win.withdraw()

    frame = ttk.Frame(win, padding=16)
    frame.pack(fill="both", expand=True)

    ttk.Label(
        frame,
        text="Re-type the restore point name to confirm:",
        font=("Segoe UI", 10),
    ).pack(anchor="w")

    # Show what needs to be typed
    ttk.Label(
        frame,
        text=expected,
        font=("Segoe UI", 10, "bold"),
        foreground="#cc4400",
    ).pack(anchor="w", pady=(4, 8))

    entry_var = tk.StringVar()
    entry = ttk.Entry(frame, textvariable=entry_var, width=55, font=("Segoe UI", 10))
    entry.pack(fill="x", pady=(0, 12))

    error_var = tk.StringVar(value="")
    error_lbl = ttk.Label(frame, textvariable=error_var, foreground="red", font=("Segoe UI", 9))
    error_lbl.pack(anchor="w", pady=(0, 6))

    btns = ttk.Frame(frame)
    btns.pack(fill="x")

    def _ok() -> None:
        typed = entry_var.get().strip()
        if typed == expected:
            result["ok"] = True
            win.destroy()
        else:
            error_var.set(f'  Does not match. Expected: "{expected}"')
            entry.focus_set()
            entry.select_range(0, "end")

    def _cancel() -> None:
        result["ok"] = False
        win.destroy()

    ttk.Button(btns, text="Cancel", command=_cancel, width=10).pack(side="right")
    ttk.Button(btns, text="Confirm", command=_ok, width=10).pack(side="right", padx=(0, 8))

    entry.focus_set()
    win.bind("<Return>", lambda _e: _ok())
    win.bind("<Escape>", lambda _e: _cancel())
    win.protocol("WM_DELETE_WINDOW", _cancel)
    win.transient(root)

    # Focus sequence
    win.update_idletasks()
    win.deiconify()
    win.lift()
    win.focus_force()
    win.grab_set()
    root.wait_window(win)

    return result["ok"]


# ---------------------------------------------------------------------------
# High-level restore point flow
# ---------------------------------------------------------------------------

def confirm_restore_point_flow(restore_point_options: list[str] | None) -> RestoreSelection | None:
    """
    Full restore point confirmation flow:
      1. Select restore point (dropdown if options given, free-text otherwise)
      2. Re-type restore point name to confirm

    Returns RestoreSelection on success, None if cancelled at any step.

    Note: The initial "do you want to continue?" dialog is NOT included here —
    the caller in ui.py handles that as part of its own flow, allowing the
    session check to happen in between.
    """
    # Step 1: Select or type restore point
    if restore_point_options:
        rp = select_restore_point_from_list(
            title="Select Restore Point",
            prompt="Select the restore point to flash back to:",
            options=restore_point_options,
        )
    else:
        rp = prompt_restore_point("Enter Restore Point")

    if not rp:
        messagebox.showwarning("Cancelled", "A restore point name is required.")
        return None

    # Step 2: Re-type confirmation
    if not confirm_retype_value("Confirm Restore Point", rp):
        messagebox.showwarning("Cancelled", "Restore point name did not match. Operation cancelled.")
        return None

    return RestoreSelection(restore_point=rp)
