#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ENV_FILE="$HOME/.flashback_env"
APP_INFO_FILE="$HOME/.flashback_app_info"
RESTORE_PID_FILE="$HOME/.flashback_restore_pid"
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
        read -r -p "Enter app tar backup dir (default: /iriscommon/backup/tar): " FLASHBACK_BACKUP_DIR
        FLASHBACK_BACKUP_DIR="${FLASHBACK_BACKUP_DIR:-/iriscommon/backup/tar}"
    fi
    FLASHBACK_APPS_USER="${FLASHBACK_APPS_USER:-apps}"
    FLASHBACK_APPS_PASS="${FLASHBACK_APPS_PASS:-}"
    FLASHBACK_WLS_PASS="${FLASHBACK_WLS_PASS:-}"
    FLASHBACK_START_CMD="${FLASHBACK_START_CMD:-adstrtal.sh}"
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
        printf 'export FLASHBACK_APP_INFO_FILE=%q\n' "$APP_INFO_FILE"
        printf 'export FLASHBACK_APPS_USER=%q\n' "$FLASHBACK_APPS_USER"
        printf 'export FLASHBACK_APPS_PASS=%q\n' "$FLASHBACK_APPS_PASS"
        printf 'export FLASHBACK_WLS_PASS=%q\n' "$FLASHBACK_WLS_PASS"
        printf 'export FLASHBACK_START_CMD=%q\n' "$FLASHBACK_START_CMD"
        printf 'export FLASHBACK_MODE=%q\n' "$FLASHBACK_MODE"
        printf 'export FLASHBACK_DRY_RUN_PROCESS_COUNT=%q\n' "$FLASHBACK_DRY_RUN_PROCESS_COUNT"
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    export FLASHBACK_INSTANCE_ID FLASHBACK_PDB_NAME FLASHBACK_ORACLE_ENV FLASHBACK_DB_HOST
    export FLASHBACK_APP_HOST FLASHBACK_SSH_USER FLASHBACK_APP_BASE_DIR FLASHBACK_BACKUP_DIR
    export FLASHBACK_ALERT_LOG FLASHBACK_APP_INFO_FILE FLASHBACK_APPS_USER FLASHBACK_APPS_PASS FLASHBACK_WLS_PASS FLASHBACK_START_CMD FLASHBACK_MODE FLASHBACK_DRY_RUN_PROCESS_COUNT
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
    if [ -f "$APP_INFO_FILE" ]; then
        # shellcheck disable=SC1090
        . "$APP_INFO_FILE"
        export FLASHBACK_RUN_FS FLASHBACK_PATCH_FS FLASHBACK_NE_FS
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

restore_flashback() {
    clear
    echo "=========================================="
    echo "           RESTORE FLASHBACK              "
    echo "=========================================="
    echo "This will RESTORE the database and application filesystems to a previous flashback point."
    echo ""
    echo "WARNING: This is a DESTRUCTIVE operation."
    echo "  - Application services will be stopped"
    echo "  - Filesystem content will be overwritten from tar backups"
    echo "  - Database will be flashed back to the selected restore point"
    echo "  - Restore points will be dropped after successful flashback"
    echo "  - Application services will be restarted"
    echo ""
    echo "The restore runs DETACHED — your terminal will be freed immediately."
    echo "All output is written to a log file you can tail at any time."
    echo ""
    echo "Execution mode: ${FLASHBACK_MODE:-dry-run}"
    if [ "${FLASHBACK_MODE:-dry-run}" != "real" ]; then
        echo "Dry-run mode prints the actions and commands without changing DB or filesystems."
        echo "Run with FLASHBACK_MODE=real for live execution."
    fi
    echo ""
    read -r -p "Continue with Restore Flashback? Type YES: " confirm
    if [ "$confirm" != "YES" ]; then
        echo "Cancelled."
        pause
        return
    fi

    # --- Collect restore point names interactively (foreground) ---
    echo ""
    echo "Querying available restore points..."
    echo ""

    # Try to get a parseable list of restore point names from Oracle.
    local rp_raw=""
    if command -v sqlplus >/dev/null 2>&1; then
        local DB_AUTH="${FLASHBACK_DB_AUTH:-os}"
        local CONNECT_CMD
        if [ "$DB_AUTH" = "os" ]; then
            CONNECT_CMD="/ as sysdba"
        else
            CONNECT_CMD="${FLASHBACK_DB_USER:-sys}/${FLASHBACK_DB_PASS:-}@${FLASHBACK_DB_HOST:-}:${FLASHBACK_DB_PORT:-1521}/${FLASHBACK_DB_SERVICE:-} as sysdba"
        fi
        rp_raw=$(sqlplus -S /nolog <<EOF 2>/dev/null || true
CONNECT $CONNECT_CMD
SET HEAD OFF FEED OFF PAGES 0 LINES 500 TRIMSPOOL ON
SELECT NAME FROM V\$RESTORE_POINT ORDER BY TIME;
EXIT;
EOF
        )
    fi

    # Build an array of restore point names (skip blank lines).
    local rp_names=()
    if [ -n "$rp_raw" ]; then
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$line" ] && continue
            rp_names+=("$line")
        done <<< "$rp_raw"
    fi

    local CDB_RP_NAME=""
    local PDB_RP_NAME=""

    if [ "${#rp_names[@]}" -gt 0 ]; then
        # --- Numbered list selection ---
        echo "Available restore points:"
        echo ""
        local i=1
        for name in "${rp_names[@]}"; do
            printf "  %2d. %s\n" "$i" "$name"
            i=$((i + 1))
        done
        echo ""

        read -r -p "Select CDB restore point number: " cdb_num
        if [ -n "$cdb_num" ] && [ "$cdb_num" -ge 1 ] 2>/dev/null && [ "$cdb_num" -le "${#rp_names[@]}" ] 2>/dev/null; then
            CDB_RP_NAME="${rp_names[$((cdb_num - 1))]}"
        else
            echo "Invalid selection."
            pause
            return
        fi

        read -r -p "Select PDB restore point number: " pdb_num
        if [ -n "$pdb_num" ] && [ "$pdb_num" -ge 1 ] 2>/dev/null && [ "$pdb_num" -le "${#rp_names[@]}" ] 2>/dev/null; then
            PDB_RP_NAME="${rp_names[$((pdb_num - 1))]}"
        else
            echo "Invalid selection."
            pause
            return
        fi
    else
        # --- Fallback: no sqlplus or no restore points found ---
        if [ "${FLASHBACK_MODE:-dry-run}" != "real" ]; then
            echo "DRY-RUN: sqlplus not on PATH or no restore points found."
            echo "DRY-RUN: In live execution, V\$RESTORE_POINT would be queried here."
            echo ""
        else
            echo "WARNING: Could not query restore points. Enter names manually."
            echo ""
        fi

        local DATE_TAG_DEFAULT
        DATE_TAG_DEFAULT=$(date '+%d%b%y' | tr '[:lower:]' '[:upper:]')
        local CDB_RP_DEFAULT="${FLASHBACK_INSTANCE_ID}_CDB_flashback_restore_${DATE_TAG_DEFAULT}"
        local PDB_RP_DEFAULT="${FLASHBACK_INSTANCE_ID}_PDB_flashback_restore_${DATE_TAG_DEFAULT}"

        read -r -p "Enter CDB restore point name [$CDB_RP_DEFAULT]: " CDB_RP_NAME
        CDB_RP_NAME="${CDB_RP_NAME:-$CDB_RP_DEFAULT}"

        read -r -p "Enter PDB restore point name [$PDB_RP_DEFAULT]: " PDB_RP_NAME
        PDB_RP_NAME="${PDB_RP_NAME:-$PDB_RP_DEFAULT}"
    fi

    # --- Prepare log file ---
    local LOG_DIR="${FLASHBACK_LOG_DIR:-$SCRIPT_DIR/../logs}"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    local LOG_TS
    LOG_TS=$(date '+%Y%m%d_%H%M%S')
    local LOG_FILE="$LOG_DIR/restore_flashback_${LOG_TS}.log"

    echo ""
    echo "=========================================="
    echo "  Restore points confirmed:"
    echo "    CDB: $CDB_RP_NAME"
    echo "    PDB: $PDB_RP_NAME"
    echo ""
    echo "  Launching restore in detached mode..."
    echo "  Log file: $LOG_FILE"
    echo "=========================================="

    # --- Launch detached ---
    export FLASHBACK_CDB_RESTORE_POINT="$CDB_RP_NAME"
    export FLASHBACK_PDB_RESTORE_POINT="$PDB_RP_NAME"

    nohup sh "$SCRIPT_DIR/oracle/restore_flashback.sh" > "$LOG_FILE" 2>&1 &
    local RESTORE_PID=$!

    # Save PID and log path for status tracking (menu option 8).
    printf '%s %s\n' "$RESTORE_PID" "$LOG_FILE" >> "$RESTORE_PID_FILE"
    chmod 600 "$RESTORE_PID_FILE"

    echo ""
    echo "  Restore PID: $RESTORE_PID"
    echo ""
    echo "  Monitor progress with:"
    echo "    tail -f $LOG_FILE"
    echo ""
    echo "  Check status from menu: option 8"
    echo ""
    pause
}

view_restore_status() {
    clear
    echo "=========================================="
    echo "         RESTORE PROCESS STATUS           "
    echo "=========================================="

    if [ ! -f "$RESTORE_PID_FILE" ]; then
        echo "No restore processes have been launched yet."
        pause
        return
    fi

    echo ""
    printf "  %-8s  %-10s  %s\n" "PID" "STATUS" "LOG FILE"
    echo "  ------   --------   ------------------------------------------"

    while IFS=' ' read -r pid logfile rest; do
        # Skip blank/malformed lines.
        case "$pid" in ''|*[!0-9]*) continue ;; esac

        if kill -0 "$pid" 2>/dev/null; then
            status="RUNNING"
        else
            status="DONE"
        fi
        printf "  %-8s  %-10s  %s\n" "$pid" "$status" "$logfile"
    done < "$RESTORE_PID_FILE"

    echo ""
    echo "=========================================="
    echo "  Latest log tail (last 15 lines):"
    echo "=========================================="

    # Show tail of the most recent log file.
    latest_log=$(tail -1 "$RESTORE_PID_FILE" | awk '{print $2}')
    if [ -n "$latest_log" ] && [ -f "$latest_log" ]; then
        tail -15 "$latest_log"
    else
        echo "  Log file not found."
    fi

    echo ""
    echo "=========================================="
    echo "  To follow live: tail -f <LOG FILE>"
    echo "=========================================="
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
    echo "  3. Restore flashback"
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
    echo "3. Restore flashback"
    echo "4. Validate system ready for Load test (next phase)"
    echo "5. Exit"
    echo "6. Delete stored config"
    echo "7. Change execution mode (${FLASHBACK_MODE:-dry-run})"
    echo "8. View restore status"
    echo "=========================================="
    read -r -p "Enter your choice [1-8]: " choice

    case "$choice" in
        1) view_flashback ;;
        2) make_flashback_request ;;
        3) restore_flashback ;;
        4) not_in_scope_yet ;;
        5) echo "Exiting..."; exit 0 ;;
        6) delete_config; load_or_prompt_config ;;
        7) toggle_mode ;;
        8) view_restore_status ;;
        *) echo "Invalid option."; pause ;;
    esac
done
