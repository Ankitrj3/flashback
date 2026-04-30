#!/usr/bin/env sh
set -eu

# Creates a client-shareable archive from the project root.
# This script lives in scripts/ — ROOT_DIR is one level up.
# Excludes logs/, __pycache__/, .pytest_cache/, tests/, and config.json (client-specific).

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
PARENT_DIR="$(CDPATH= cd -- "${ROOT_DIR}/.." && pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
PROJECT_NAME="$(basename "${ROOT_DIR}")"
NAME="${PROJECT_NAME}_${TS}"

cd "${PARENT_DIR}"

if command -v zip >/dev/null 2>&1; then
  ZIP_PATH="${ROOT_DIR}/${NAME}.zip"
  rm -f "${ZIP_PATH}" 2>/dev/null || true
  zip -r "${ZIP_PATH}" "${PROJECT_NAME}" \
    -x "${PROJECT_NAME}/logs/*" \
    -x "${PROJECT_NAME}/__pycache__/*" \
    -x "${PROJECT_NAME}/**/__pycache__/*" \
    -x "${PROJECT_NAME}/.pytest_cache/*" \
    -x "${PROJECT_NAME}/.cache/*" \
    -x "${PROJECT_NAME}/tests/*" \
    -x "${PROJECT_NAME}/config.json" >/dev/null
  echo "Created: ${ZIP_PATH}"
  exit 0
fi

TAR_PATH="${ROOT_DIR}/${NAME}.tar.gz"
rm -f "${TAR_PATH}" 2>/dev/null || true
tar --exclude="${PROJECT_NAME}/logs" \
    --exclude="${PROJECT_NAME}/__pycache__" \
    --exclude="${PROJECT_NAME}/**/__pycache__" \
    --exclude="${PROJECT_NAME}/.pytest_cache" \
    --exclude="${PROJECT_NAME}/.cache" \
    --exclude="${PROJECT_NAME}/tests" \
    --exclude="${PROJECT_NAME}/config.json" \
    -czf "${TAR_PATH}" "${PROJECT_NAME}"
echo "Created: ${TAR_PATH}"
