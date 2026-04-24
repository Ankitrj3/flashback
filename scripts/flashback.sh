#!/usr/bin/env sh
set -eu

# This script lives in scripts/ — resolve project root (one level up).
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1

find_python() {
  if command -v python3 >/dev/null 2>&1; then
    echo "python3"
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    echo "python"
    return 0
  fi
  return 1
}

PY="$(find_python || true)"
if [ -z "${PY}" ]; then
  echo "ERROR: python3/python not found on PATH." >&2
  exit 127
fi

usage() {
  cat >&2 <<'EOF'
Usage:
  sh scripts/flashback.sh gui
  sh scripts/flashback.sh dry-run
  sh scripts/flashback.sh execute
  sh scripts/flashback.sh test-connectivity

Notes:
  - This wrapper is POSIX sh. It works on Linux/macOS and on Windows via Git Bash or WSL.
  - Windows-native entrypoint for GUI: scripts/run_gui.bat
EOF
}

cmd="${1:-}"
shift || true

case "${cmd}" in
  gui)
    exec "${PY}" "${ROOT_DIR}/gui.py" "$@"
    ;;
  dry-run)
    exec "${PY}" "${ROOT_DIR}/cli.py" --dry-run "$@"
    ;;
  execute)
    exec "${PY}" "${ROOT_DIR}/cli.py" --execute "$@"
    ;;
  test-connectivity)
    exec "${PY}" "${ROOT_DIR}/cli.py" --test-connectivity "$@"
    ;;
  -h|--help|help|"")
    usage
    exit 2
    ;;
  *)
    echo "ERROR: Unknown command: ${cmd}" >&2
    usage
    exit 2
    ;;
esac
