#!/bin/bash
set -euo pipefail

# MySQL Backup Script with retention management via rclone
# Required variables:
#   BACKUP_NAME (environment/instance name)
#   MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE
#   RCLONE_DEST (e.g., remote:bucket/backups)
#   BACKUP_SCHEDULE (cron expression, e.g., "0 2 * * *")
#   BACKUP_RETENTION (number of backups to keep)
# Optional:
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
: "${BACKUP_RETENTION:?BACKUP_RETENTION variable not defined}"
: "${MYSQL_DUMP_OPTS:=}"

# Sanitize BACKUP_NAME for path/filename
# Non-alphanumeric characters -> underscore, lowercase
BACKUP_NAME_SAFE=$(echo "$BACKUP_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g' | tr '[:upper:]' '[:lower:]')

# Sanitize BACKUP_SCHEDULE to create folder name
# * -> X, space -> _, / -> -
BACKUP_FOLDER=$(echo "$BACKUP_SCHEDULE" | sed 's/\*/X/g; s/ /_/g; s/\//-/g')

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FILENAME="${BACKUP_NAME_SAFE}_${MYSQL_DATABASE}_${TIMESTAMP}.sql.gz"
LOG_FILE=".backup.log"
DEST_PATH="$RCLONE_DEST/$BACKUP_NAME_SAFE/$BACKUP_FOLDER"

echo "=== MySQL Backup Script ==="
echo "Name: $BACKUP_NAME ($BACKUP_NAME_SAFE)"
echo "Schedule: $BACKUP_SCHEDULE"
echo "Folder: $BACKUP_FOLDER"
echo "Database: $MYSQL_DATABASE"
echo "Destination: $DEST_PATH/"
echo "Retention: $BACKUP_RETENTION backups"
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

# Retention cleanup
echo ""
echo "=== Retention Cleanup ==="
echo "Keeping last $BACKUP_RETENTION backups in $BACKUP_FOLDER..."

# List files sorted by name (exclude .backup.log), get files to delete
files_to_delete=$(rclone lsf "$DEST_PATH/" --files-only 2>/dev/null | grep -v "^\.backup\.log$" | sort -r | tail -n +$((BACKUP_RETENTION + 1))) || true

if [[ -n "$files_to_delete" ]]; then
    while IFS= read -r file; do
        echo "  Deleting: $file"
        rclone delete "$DEST_PATH/$file"
    done <<< "$files_to_delete"
else
    echo "  No files to delete."
fi

echo ""
echo "=== Backup completed successfully ==="
