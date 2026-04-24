from __future__ import annotations

import sys


sys.dont_write_bytecode = True


from flashback.ui import run_gui


def main() -> int:
    run_gui()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
