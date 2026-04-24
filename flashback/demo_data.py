from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RestorePoint:
    name: str
    time: str
    guaranteed: str


def load_restore_points(path: Path) -> list[RestorePoint]:
    if not path.exists():
        return []
    raw = json.loads(path.read_text(encoding="utf-8"))
    points: list[RestorePoint] = []
    for item in raw or []:
        points.append(
            RestorePoint(
                name=str(item.get("name", "")).strip(),
                time=str(item.get("time", "")).strip(),
                guaranteed=str(item.get("guaranteed", "")).strip().upper(),
            )
        )
    return [p for p in points if p.name]


def format_restore_points_table(points: list[RestorePoint]) -> list[str]:
    if not points:
        return ["(no restore points found in demo file)"]

    headers = ["NAME", "TIME", "GUARANTEED"]
    rows = [(p.name, p.time, p.guaranteed) for p in points]

    widths = [len(h) for h in headers]
    for r in rows:
        widths = [max(w, len(col)) for w, col in zip(widths, r)]

    def fmt_row(cols: list[str]) -> str:
        return "  ".join(c.ljust(w) for c, w in zip(cols, widths))

    lines = [fmt_row(headers), fmt_row(["-" * w for w in widths])]
    lines.extend(fmt_row([a, b, c]) for (a, b, c) in rows)
    return lines


def load_active_sessions(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    raw = json.loads(path.read_text(encoding="utf-8"))
    out: list[dict[str, str]] = []
    for item in raw or []:
        out.append(
            {
                "username": str(item.get("username", "")).strip(),
                "status": str(item.get("status", "")).strip(),
                "program": str(item.get("program", "")).strip(),
                "logon_time": str(item.get("logon_time", "")).strip(),
            }
        )
    return [s for s in out if s.get("username")]
