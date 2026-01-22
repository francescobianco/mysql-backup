#!/bin/bash
set -euo pipefail

# MySQL Backup Script with retention management via rclone
# Required variables:
#   BACKUP_NAME (environment/instance name)
#   MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE
#   RCLONE_DEST (e.g., remote:bucket/backups)
# Optional:
#   BACKUP_SCHEDULE (cron expression, default: "oneshot")
#   BACKUP_RETENTION (daily,weekly,monthly,yearly - default: "1,1,1,1")
#   MYSQL_DUMP_OPTS (additional mysqldump options)

# Validate required variables
: "${BACKUP_NAME:?BACKUP_NAME variable not defined}"
: "${MYSQL_HOST:?MYSQL_HOST variable not defined}"
: "${MYSQL_PORT:=3306}"
: "${MYSQL_USER:?MYSQL_USER variable not defined}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD variable not defined}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE variable not defined}"
: "${RCLONE_DEST:?RCLONE_DEST variable not defined}"
: "${BACKUP_SCHEDULE:=oneshot}"
: "${BACKUP_RETENTION:=1,1,1,1}"
: "${MYSQL_DUMP_OPTS:=}"

# Parse retention (daily,weekly,monthly,yearly)
IFS=',' read -r RETENTION_DAILY RETENTION_WEEKLY RETENTION_MONTHLY RETENTION_YEARLY <<< "$BACKUP_RETENTION"

# Classify cron schedule into a class (daily, weekly, monthly, yearly)
# Returns: class name or empty string if no match
# Cron format: minute hour day-of-month month day-of-week
classify_schedule() {
    local schedule=$1

    # Handle special cases
    if [[ "$schedule" == "oneshot" ]]; then
        echo ""
        return
    fi

    # Parse cron fields
    local min hour dom month dow
    read -r min hour dom month dow <<< "$schedule"

    # yearly: specific day and month (e.g., "0 5 1 1 *" = Jan 1st)
    if [[ "$dom" != "*" && "$month" != "*" && ! "$month" =~ [/,\-] && ! "$dom" =~ [/,\-] ]]; then
        echo "yearly"
        return
    fi

    # monthly: specific day of month, any month (e.g., "0 4 1 * *" = 1st of each month)
    if [[ "$dom" != "*" && ! "$dom" =~ [/,\-] && "$month" == "*" && "$dow" == "*" ]]; then
        echo "monthly"
        return
    fi

    # weekly: specific day of week, any day of month (e.g., "0 3 * * 0" = every Sunday)
    if [[ "$dom" == "*" && "$dow" != "*" && ! "$dow" =~ [/,\-] ]]; then
        echo "weekly"
        return
    fi

    # daily: every day (e.g., "0 2 * * *")
    if [[ "$dom" == "*" && "$month" == "*" && "$dow" == "*" && ! "$hour" =~ [/,] ]]; then
        echo "daily"
        return
    fi

    # No class match - return empty
    echo ""
}

# Sanitize string for path/filename
# Non-alphanumeric characters -> underscore, lowercase
sanitize_name() {
    echo "$1" | sed 's/[^a-zA-Z0-9_-]/_/g' | tr '[:upper:]' '[:lower:]'
}

# Sanitize cron expression for folder name
# * -> X, space -> _, / -> -
sanitize_schedule() {
    echo "$1" | sed 's/\*/X/g; s/ /_/g; s/\//-/g'
}

# Classify the schedule
BACKUP_CLASS=$(classify_schedule "$BACKUP_SCHEDULE")

# Determine folder name and retention
if [[ -n "$BACKUP_CLASS" ]]; then
    BACKUP_FOLDER="$BACKUP_CLASS"
    case "$BACKUP_CLASS" in
        daily)   CURRENT_RETENTION=$RETENTION_DAILY ;;
        weekly)  CURRENT_RETENTION=$RETENTION_WEEKLY ;;
        monthly) CURRENT_RETENTION=$RETENTION_MONTHLY ;;
        yearly)  CURRENT_RETENTION=$RETENTION_YEARLY ;;
    esac
    APPLY_RETENTION=true
else
    BACKUP_FOLDER=$(sanitize_schedule "$BACKUP_SCHEDULE")
    CURRENT_RETENTION=0
    APPLY_RETENTION=false
fi

BACKUP_NAME_SAFE=$(sanitize_name "$BACKUP_NAME")
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FILENAME="${BACKUP_NAME_SAFE}_${MYSQL_DATABASE}_${TIMESTAMP}.sql.gz"
LOG_FILE=".backup.log"
DEST_PATH="$RCLONE_DEST/$BACKUP_NAME_SAFE/$BACKUP_FOLDER"

echo "=== MySQL Backup Script ==="
echo "Name: $BACKUP_NAME ($BACKUP_NAME_SAFE)"
echo "Schedule: $BACKUP_SCHEDULE"
if [[ -n "$BACKUP_CLASS" ]]; then
    echo "Class: $BACKUP_CLASS (retention: $CURRENT_RETENTION)"
else
    echo "Class: none (no retention, manual cleanup)"
fi
echo "Folder: $BACKUP_FOLDER"
echo "Database: $MYSQL_DATABASE"
echo "Destination: $DEST_PATH/"
echo ""

# Create destination folder if it doesn't exist
echo "Creating destination folder..."
rclone mkdir "$DEST_PATH"

# Temporary directory for backup
TEMP_DIR=$(mktemp -d)

LOCAL_LOG="$TEMP_DIR/$LOG_FILE"
BACKUP_FILE="$TEMP_DIR/$BACKUP_FILENAME"

# Flag to track if backup completed successfully
BACKUP_COMPLETED=false

# Function to append to remote log
# Log format:
#   >>> = START (backup started)
#   !!! = ERROR (backup failed)
#   <<< = END   (backup completed)
log_entry() {
    local marker=$1
    local message=$2
    local ts
    ts=$(date "+%Y-%m-%d %H:%M:%S")

    # Download existing log (if exists)
    rclone copy "$DEST_PATH/$LOG_FILE" "$TEMP_DIR/" 2>/dev/null || true

    # Append entry
    echo "$marker $ts | $message" >> "$LOCAL_LOG"

    # Upload updated log
    rclone copy "$LOCAL_LOG" "$DEST_PATH/"
}

# Trap for cleanup and error logging
cleanup() {
    local exit_code=$?

    # If backup not completed and exited with error, log ERROR
    if [[ "$BACKUP_COMPLETED" != "true" && $exit_code -ne 0 ]]; then
        echo "!!! Backup failed with exit code $exit_code"
        log_entry "!!!" "ERROR | $BACKUP_FILENAME | exit code: $exit_code" 2>/dev/null || true
    fi

    # Cleanup temp dir
    rm -rf "$TEMP_DIR"

    exit $exit_code
}
trap cleanup EXIT

# === LOG START ===
echo "Logging START..."
log_entry ">>>" "START | $BACKUP_FILENAME"

# Execute mysqldump
echo "Running mysqldump..."
mysqldump \
    -h "$MYSQL_HOST" \
    -P "$MYSQL_PORT" \
    -u "$MYSQL_USER" \
    -p"$MYSQL_PASSWORD" \
    $MYSQL_DUMP_OPTS \
    --no-tablespaces \
    "$MYSQL_DATABASE" | gzip > "$BACKUP_FILE"

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "Backup created: $BACKUP_SIZE"

# Upload with rclone
echo "Uploading backup to $DEST_PATH/..."
rclone copy "$BACKUP_FILE" "$DEST_PATH/"

echo "Upload completed."

# === LOG END ===
echo "Logging END..."
log_entry "<<<" "END   | $BACKUP_FILENAME | $BACKUP_SIZE | OK"
BACKUP_COMPLETED=true

# Retention cleanup (only if schedule is classified)
echo ""
if [[ "$APPLY_RETENTION" == "true" ]]; then
    echo "=== Retention Cleanup ==="
    echo "Keeping last $CURRENT_RETENTION backups in $BACKUP_FOLDER..."

    # List files sorted by name (exclude .backup.log), get files to delete
    files_to_delete=$(rclone lsf "$DEST_PATH/" --files-only 2>/dev/null | grep -v "^\.backup\.log$" | sort -r | tail -n +$((CURRENT_RETENTION + 1))) || true

    if [[ -n "$files_to_delete" ]]; then
        while IFS= read -r file; do
            echo "  Deleting: $file"
            rclone delete "$DEST_PATH/$file"
        done <<< "$files_to_delete"
    else
        echo "  No files to delete."
    fi
else
    echo "=== No Retention ==="
    echo "Schedule not classified. Backups kept indefinitely (manual cleanup required)."
fi

echo ""
echo "=== Backup completed successfully ==="
