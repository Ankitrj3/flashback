#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ENV_FILE="$HOME/.flashback_env"
REQUESTED_FLASHBACK_MODE="${FLASHBACK_MODE:-}"

pause() {
    echo ""
    read -r -p "Press [Enter] key to continue..." _
}

apply_detected_config() {
    # The detector prints KEY="value" records from sqlplus. Parse only the
    # approved variables here instead of eval'ing database-derived text.
    detected_config="$1"
    while IFS='=' read -r key raw_value; do
        case "$key" in
            FLASHBACK_INSTANCE_ID|FLASHBACK_DB_HOST|FLASHBACK_PDB_NAME|FLASHBACK_ALERT_LOG)
                value="${raw_value#\"}"
                value="${value%\"}"
                value="${value//\\\"/\"}"
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done <<< "$detected_config"
}

load_or_prompt_config() {
    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$ENV_FILE"
    fi

    if [ -n "$REQUESTED_FLASHBACK_MODE" ]; then
        FLASHBACK_MODE="$REQUESTED_FLASHBACK_MODE"
    fi

    if [ -z "${FLASHBACK_INSTANCE_ID:-}" ] || [ -z "${FLASHBACK_PDB_NAME:-}" ] || [ -z "${FLASHBACK_ALERT_LOG:-}" ]; then
        detected="$(sh "$SCRIPT_DIR/oracle/detect_environment.sh" 2>/dev/null || true)"
        if [ -n "$detected" ]; then
            apply_detected_config "$detected"
            echo "Detected DB environment:"
            echo "  DB Name   : ${FLASHBACK_INSTANCE_ID:-not detected}"
            echo "  PDB Name  : ${FLASHBACK_PDB_NAME:-not detected}"
            echo "  DB Host   : ${FLASHBACK_DB_HOST:-not detected}"
            echo "  Alert Log : ${FLASHBACK_ALERT_LOG:-not detected}"
            echo ""
        fi
    fi

    if [ -z "${FLASHBACK_INSTANCE_ID:-}" ]; then
        read -r -p "Enter DB name / instance prefix (example: DBNAME): " FLASHBACK_INSTANCE_ID
    fi
    if [ -z "${FLASHBACK_PDB_NAME:-}" ]; then
        read -r -p "Enter PDB name/container (default: ${FLASHBACK_INSTANCE_ID}): " FLASHBACK_PDB_NAME
        FLASHBACK_PDB_NAME="${FLASHBACK_PDB_NAME:-$FLASHBACK_INSTANCE_ID}"
    fi
    FLASHBACK_ALERT_LOG="${FLASHBACK_ALERT_LOG:-}"
    FLASHBACK_DB_HOST="${FLASHBACK_DB_HOST:-}"
    if [ -z "${FLASHBACK_APP_HOST:-}" ]; then
        read -r -p "Enter application host for SSH, blank if running locally: " FLASHBACK_APP_HOST
    fi
    if [ -z "${FLASHBACK_SSH_USER:-}" ]; then
        read -r -p "Enter SSH/application OS user (default: $(whoami)): " FLASHBACK_SSH_USER
        FLASHBACK_SSH_USER="${FLASHBACK_SSH_USER:-$(whoami)}"
    fi
    if [ -z "${FLASHBACK_APP_BASE_DIR:-}" ]; then
        read -r -p "Enter application base dir (example: /db800/app/oracle/r122${FLASHBACK_INSTANCE_ID}): " FLASHBACK_APP_BASE_DIR
    fi
    if [ -z "${FLASHBACK_BACKUP_DIR:-}" ]; then
        read -r -p "Enter app tar backup dir (default: /iriscommon/backups/tars): " FLASHBACK_BACKUP_DIR
        FLASHBACK_BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/iriscommon/backups/tars}"
    fi
    FLASHBACK_APPS_USER="${FLASHBACK_APPS_USER:-apps}"
    FLASHBACK_APPS_PASS="${FLASHBACK_APPS_PASS:-}"
    FLASHBACK_WLS_PASS="${FLASHBACK_WLS_PASS:-}"
    FLASHBACK_MODE="${FLASHBACK_MODE:-dry-run}"
    FLASHBACK_DRY_RUN_PROCESS_COUNT="${FLASHBACK_DRY_RUN_PROCESS_COUNT:-0}"
    if [ "$FLASHBACK_MODE" != "dry-run" ] && [ "$FLASHBACK_MODE" != "real" ]; then
        FLASHBACK_MODE="dry-run"
    fi

    {
        printf 'export FLASHBACK_INSTANCE_ID=%q\n' "$FLASHBACK_INSTANCE_ID"
        printf 'export FLASHBACK_PDB_NAME=%q\n' "$FLASHBACK_PDB_NAME"
        printf 'export FLASHBACK_ORACLE_ENV=%q\n' "${FLASHBACK_ORACLE_ENV:-}"
        printf 'export FLASHBACK_DB_HOST=%q\n' "${FLASHBACK_DB_HOST:-}"
        printf 'export FLASHBACK_APP_HOST=%q\n' "$FLASHBACK_APP_HOST"
        printf 'export FLASHBACK_SSH_USER=%q\n' "$FLASHBACK_SSH_USER"
        printf 'export FLASHBACK_APP_BASE_DIR=%q\n' "$FLASHBACK_APP_BASE_DIR"
        printf 'export FLASHBACK_BACKUP_DIR=%q\n' "$FLASHBACK_BACKUP_DIR"
        printf 'export FLASHBACK_ALERT_LOG=%q\n' "${FLASHBACK_ALERT_LOG:-}"
        printf 'export FLASHBACK_APPS_USER=%q\n' "$FLASHBACK_APPS_USER"
        printf 'export FLASHBACK_APPS_PASS=%q\n' "$FLASHBACK_APPS_PASS"
        printf 'export FLASHBACK_WLS_PASS=%q\n' "$FLASHBACK_WLS_PASS"
        printf 'export FLASHBACK_MODE=%q\n' "$FLASHBACK_MODE"
        printf 'export FLASHBACK_DRY_RUN_PROCESS_COUNT=%q\n' "$FLASHBACK_DRY_RUN_PROCESS_COUNT"
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    export FLASHBACK_INSTANCE_ID FLASHBACK_PDB_NAME FLASHBACK_ORACLE_ENV FLASHBACK_DB_HOST
    export FLASHBACK_APP_HOST FLASHBACK_SSH_USER FLASHBACK_APP_BASE_DIR FLASHBACK_BACKUP_DIR
    export FLASHBACK_ALERT_LOG FLASHBACK_APPS_USER FLASHBACK_APPS_PASS FLASHBACK_WLS_PASS FLASHBACK_MODE FLASHBACK_DRY_RUN_PROCESS_COUNT
}

delete_config() {
    clear
    echo "=========================================="
    echo "          DELETE STORED CONFIG            "
    echo "=========================================="
    if [ -f "$ENV_FILE" ]; then
        rm -f "$ENV_FILE"
        echo "Stored config deleted. It will be requested on next run."
    else
        echo "No stored config found."
    fi
    pause
}

view_flashback() {
    clear
    echo "=========================================="
    echo "             VIEW FLASHBACK               "
    echo "=========================================="
    sh "$SCRIPT_DIR/oracle/view_flashback.sh"
    pause
}

make_flashback_request() {
    clear
    echo "=========================================="
    echo "         MAKE FLASHBACK REQUEST           "
    echo "=========================================="
    echo "This will check application services, create DB guaranteed restore points, and secure application tar backups."
    echo "Execution mode: ${FLASHBACK_MODE:-dry-run}"
    if [ "${FLASHBACK_MODE:-dry-run}" != "real" ]; then
        echo "Dry-run mode prints the actions and commands without changing DB or filesystems."
        echo "Run with FLASHBACK_MODE=real for live execution."
    fi
    echo ""
    read -r -p "Continue with Make Flashback Request? Type YES: " confirm
    if [ "$confirm" != "YES" ]; then
        echo "Cancelled."
        pause
        return
    fi

    echo ""
    echo "Step 1/3: Capturing application file-system and service status..."
    if ! sh "$SCRIPT_DIR/oracle/capture_app_info.sh"; then
        echo "ERROR: Application pre-check failed."
        pause
        return
    fi

    echo ""
    echo "Step 2/3: Creating CDB/PDB guaranteed restore points..."
    if ! sh "$SCRIPT_DIR/oracle/create_flashback_restore_point.sh"; then
        echo "ERROR: DB restore point creation failed."
        pause
        return
    fi

    echo ""
    echo "Step 3/3: Starting application tar backup..."
    if ! sh "$SCRIPT_DIR/oracle/create_backup.sh"; then
        echo "ERROR: Application backup failed."
        pause
        return
    fi

    echo ""
    echo "Make Flashback Request completed."
    pause
}

not_in_scope_yet() {
    clear
    echo "=========================================="
    echo "              NEXT PHASE                  "
    echo "=========================================="
    echo "This option is intentionally not active yet."
    echo "Current active scope is:"
    echo "  1. View Flashback"
    echo "  2. Make flashback request"
    pause
}

toggle_mode() {
    clear
    echo "=========================================="
    echo "             EXECUTION MODE               "
    echo "=========================================="
    echo "Current mode: ${FLASHBACK_MODE:-dry-run}"
    echo ""
    echo "1. dry-run"
    echo "2. real"
    echo ""
    read -r -p "Choose mode [1-2]: " mode_choice
    case "$mode_choice" in
        1) FLASHBACK_MODE="dry-run" ;;
        2)
            read -r -p "Type REAL to enable live execution: " real_confirm
            if [ "$real_confirm" = "REAL" ]; then
                FLASHBACK_MODE="real"
            else
                echo "Mode unchanged."
                pause
                return
            fi
            ;;
        *) echo "Invalid option."; pause; return ;;
    esac
    REQUESTED_FLASHBACK_MODE="$FLASHBACK_MODE"
    export FLASHBACK_MODE
    load_or_prompt_config
    echo "Execution mode set to: $FLASHBACK_MODE"
    pause
}

load_or_prompt_config

while true; do
    clear
    echo "=========================================="
    echo "       ORACLE DB FLASHBACK MANAGER        "
    echo "=========================================="
    echo "1. View Flashback"
    echo "2. Make flashback request"
    echo "3. Restore flashback              (next phase)"
    echo "4. Validate system ready for Load test (next phase)"
    echo "5. Exit"
    echo "6. Delete stored config"
    echo "7. Change execution mode (${FLASHBACK_MODE:-dry-run})"
    echo "=========================================="
    read -r -p "Enter your choice [1-7]: " choice

    case "$choice" in
        1) view_flashback ;;
        2) make_flashback_request ;;
        3) not_in_scope_yet ;;
        4) not_in_scope_yet ;;
        5) echo "Exiting..."; exit 0 ;;
        6) delete_config; load_or_prompt_config ;;
        7) toggle_mode ;;
        *) echo "Invalid option."; pause ;;
    esac
done
