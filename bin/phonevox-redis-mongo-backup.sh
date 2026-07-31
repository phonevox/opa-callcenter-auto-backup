#!/usr/bin/bash

# === CONSTANTS ===

# General script constants
FULL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CURRDIR="$(dirname "$FULL_SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$FULL_SCRIPT_PATH")"

# Logging
_LOG_FILE="/var/log/pbackup.log"
_LOG_LEVEL=3 # 0:test, 1:trace, 2:debug, 3:info, 4:warn, 5:error, 6:fatal
_LOG_ROTATE_PERIOD=7

# Staging dir (local, temporary, before uploading via pbackup)
BACKUP_DIR="$CURRDIR/tmp"

# Redis
REDIS_CONTAINER="redis"
REDIS_DUMP_HOST_PATH="/var/lib/redis/data/dump.rdb" # container bind mount, path on the HOST
REDIS_BACKUP_FILE="redisbackup-$(date +%Y%m%d%H%M%S).rdb"

# MongoDB
MONGO_CONTAINER="mongodb"
MONGO_CREDENTIALS_FILE="$CURRDIR/mongo.env" # must contain MONGO_USER and MONGO_PASS, fill in after pulling
MONGO_AUTH_DB="call-center"
MONGO_DUMP_CONTAINER_DIR="/data/db/backup" # path INSIDE the container
MONGO_DUMP_HOST_DIR="/var/lib/mongodb/data/db/backup" # container bind mount, path on the HOST
MONGO_ARCHIVE_NAME="mongodump-$(date +%Y%m%d%H%M%S).archive.gz"
MONGO_BACKUP_FILE="mongobackup-$(date +%Y%m%d%H%M%S).archive.gz"

# Discord (start/finish/error notifications)
DISCORD_WEBHOOK_FILE="$CURRDIR/discord.env" # must contain DISCORD_WEBHOOK_URL, fill in after pulling

# UOE (custom drive, pbackup upload destination)
UOE_CREDENTIALS_FILE="$CURRDIR/uoe.env" # must contain UOE_URL and UOE_TOKEN, fill in after pulling

# === LOGGING ===

function _log() {
    local level="$1"
    local message="$2"
    local muted="$3"

    local level_num
    case "$level" in
        trace) level_num=1 ;;
        debug) level_num=2 ;;
        info)  level_num=3 ;;
        warn)  level_num=4 ;;
        error) level_num=5 ;;
        fatal) level_num=6 ;;
        *)     level_num=3 ;;
    esac
    [ "$level_num" -lt "$_LOG_LEVEL" ] && return 0

    local level_upper
    level_upper="$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')"

    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level_upper] $message"

    { echo "$line" >> "$_LOG_FILE"; } 2>/dev/null
    [ "$muted" != "muted" ] && echo "$line"
}

function log.trace() { _log trace "$1" "$2"; }
function log.debug() { _log debug "$1" "$2"; }
function log.info()  { _log info  "$1" "$2"; }
function log.warn()  { _log warn  "$1" "$2"; }
function log.error() { _log error "$1" "$2"; }
function log.fatal() { _log fatal "$1" "$2"; }

# rotate the log file if it's older than _LOG_ROTATE_PERIOD days
if [ -f "$_LOG_FILE" ]; then
    _log_age_days=$(( ($(date +%s) - $(stat -c %Y "$_LOG_FILE" 2>/dev/null || echo 0)) / 86400 ))
    if [ "$_log_age_days" -ge "$_LOG_ROTATE_PERIOD" ]; then
        { mv -f "$_LOG_FILE" "$_LOG_FILE.$(date +%Y%m%d)"; } 2>/dev/null
    fi
fi

# === FUNCS ===

log.info "=== STARTING - ARGUMENTS: $*" muted

function load_discord_webhook() {
    if [ -f "$DISCORD_WEBHOOK_FILE" ]; then
        source "$DISCORD_WEBHOOK_FILE"
    fi

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        log.warn "WARNING: DISCORD_WEBHOOK_URL not set in '$DISCORD_WEBHOOK_FILE'. Discord notifications disabled."
    fi
}

function discord_notify() {
    local message="$1"
    local color="${2:-3447003}" # blue (default), green=3066993, red=15158332

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        return 0
    fi

    local escaped="${message//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"

    curl -sS -m 10 -H "Content-Type: application/json" \
        -d "{\"embeds\":[{\"title\":\"$SCRIPT_NAME\",\"description\":\"$escaped ($(hostname))\",\"color\":$color}]}" \
        "$DISCORD_WEBHOOK_URL" > /dev/null 2>&1 \
        || log.warn "WARNING: Failed to send Discord notification."
}

function discord_report_exit() {
    local code="$1"
    if [ "$code" -eq 0 ]; then
        discord_notify "✅ Backup finished successfully." 3066993
    else
        discord_notify "❌ Backup failed (exit code $code). Check $_LOG_FILE." 15158332
    fi
}

function generate_redis_backup() {
    log.info "Generating Redis backup..."

    local save_output
    save_output="$(docker exec "$REDIS_CONTAINER" redis-cli SAVE 2>&1)"
    if [ "$?" -ne 0 ] || ! echo "$save_output" | grep -q "OK"; then
        log.fatal "ERROR: redis-cli SAVE failed: $save_output. Exiting for safety reasons..."
        exit 1
    fi

    if ! [ -f "$REDIS_DUMP_HOST_PATH" ]; then
        log.fatal "ERROR: '$REDIS_DUMP_HOST_PATH' not found after SAVE. Exiting for safety reasons..."
        exit 1
    fi

    cp -f "$REDIS_DUMP_HOST_PATH" "$BACKUP_DIR/$REDIS_BACKUP_FILE"

    if ! [ -f "$BACKUP_DIR/$REDIS_BACKUP_FILE" ]; then
        log.fatal "ERROR: '$BACKUP_DIR/$REDIS_BACKUP_FILE' was not generated! Exiting for safety reasons..."
        exit 1
    fi

    log.debug "'$BACKUP_DIR/$REDIS_BACKUP_FILE' generated, proceeding..."
}

function generate_mongo_backup() {
    log.info "Generating MongoDB backup..."

    if [ -z "$MONGO_USER" ] || [ -z "$MONGO_PASS" ]; then
        log.fatal "ERROR: MONGO_USER/MONGO_PASS not set. Check '$MONGO_CREDENTIALS_FILE'. Exiting..."
        exit 1
    fi

    # --archive generates a single file (no leftover directory accumulating across runs)
    docker exec "$MONGO_CONTAINER" mongodump \
        --archive="$MONGO_DUMP_CONTAINER_DIR/$MONGO_ARCHIVE_NAME" \
        --gzip \
        -u "$MONGO_USER" \
        -p "$MONGO_PASS" \
        --authenticationDatabase "$MONGO_AUTH_DB" 2>&1

    if ! [ -f "$MONGO_DUMP_HOST_DIR/$MONGO_ARCHIVE_NAME" ]; then
        log.fatal "ERROR: '$MONGO_DUMP_HOST_DIR/$MONGO_ARCHIVE_NAME' was not generated! Exiting for safety reasons..."
        exit 1
    fi

    mv -f "$MONGO_DUMP_HOST_DIR/$MONGO_ARCHIVE_NAME" "$BACKUP_DIR/$MONGO_BACKUP_FILE"

    if ! [ -f "$BACKUP_DIR/$MONGO_BACKUP_FILE" ]; then
        log.fatal "ERROR: '$BACKUP_DIR/$MONGO_BACKUP_FILE' was not generated! Exiting for safety reasons..."
        exit 1
    fi

    log.debug "'$BACKUP_DIR/$MONGO_BACKUP_FILE' generated, proceeding..."
}

# === RUNTIME ===

function print_help() {
    cat <<EOF
$SCRIPT_NAME - backs up Redis and MongoDB (Docker containers) and uploads to the UOE drive via pbackup

Usage:
  $SCRIPT_NAME              Run the backup
  $SCRIPT_NAME -h, --help   Show this help message and exit
  $SCRIPT_NAME -l, --logs   Tail the log file in real time (tail -f $_LOG_FILE)

Runs with no arguments in normal operation. Credentials are read from:
  $MONGO_CREDENTIALS_FILE   (MONGO_USER, MONGO_PASS)
  $UOE_CREDENTIALS_FILE     (UOE_URL, UOE_TOKEN)
  $DISCORD_WEBHOOK_FILE     (DISCORD_WEBHOOK_URL, optional)

Log file: $_LOG_FILE
EOF
}

function validations () {
    log.trace "Checking if pbackup is installed..."
    if ! [ -f "/usr/sbin/pbackup" ]; then
        log.fatal "ERROR: You need to install pbackup! Exiting..."
        exit 1
    fi
    if ! [ -x "/usr/sbin/pbackup" ]; then
        log.fatal "ERROR: '/usr/sbin/pbackup' is not executable. Run 'chmod +x /usr/sbin/pbackup'. Exiting..."
        exit 1
    fi

    log.trace "Checking if rclone is installed..."
    if ! command -v rclone &> /dev/null; then
        log.fatal "ERROR: rclone not found. pbackup depends on it. Exiting..."
        exit 1
    fi

    log.trace "Checking for UOE credentials file..."
    if ! [ -f "$UOE_CREDENTIALS_FILE" ]; then
        log.fatal "ERROR: '$UOE_CREDENTIALS_FILE' not found. Exiting..."
        exit 1
    fi
    source "$UOE_CREDENTIALS_FILE"
    if [ -z "$UOE_URL" ] || [ -z "$UOE_TOKEN" ]; then
        log.fatal "ERROR: UOE_URL/UOE_TOKEN not set. Check '$UOE_CREDENTIALS_FILE'. Exiting..."
        exit 1
    fi

    log.trace "Checking if docker is installed..."
    if ! command -v docker &> /dev/null; then
        log.fatal "ERROR: docker not found. Exiting..."
        exit 1
    fi

    log.trace "Checking if $REDIS_CONTAINER container is running..."
    if ! docker ps --format '{{.Names}}' | grep -q "^${REDIS_CONTAINER}$"; then
        log.fatal "ERROR: Container '$REDIS_CONTAINER' is not running. Exiting..."
        exit 1
    fi

    log.trace "Checking if $MONGO_CONTAINER container is running..."
    if ! docker ps --format '{{.Names}}' | grep -q "^${MONGO_CONTAINER}$"; then
        log.fatal "ERROR: Container '$MONGO_CONTAINER' is not running. Exiting..."
        exit 1
    fi

    log.trace "Checking for MongoDB credentials file..."
    if ! [ -f "$MONGO_CREDENTIALS_FILE" ]; then
        log.fatal "ERROR: '$MONGO_CREDENTIALS_FILE' not found. Exiting..."
        exit 1
    fi
    source "$MONGO_CREDENTIALS_FILE"

    log.trace "Pinging Redis..."
    if ! docker exec "$REDIS_CONTAINER" redis-cli PING 2>/dev/null | grep -q "PONG"; then
        log.fatal "ERROR: Redis did not respond to PING. Exiting..."
        exit 1
    fi

    log.trace "Pinging MongoDB..."
    if ! docker exec "$MONGO_CONTAINER" mongo --quiet --eval "db.runCommand({ping:1}).ok" \
        -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase "$MONGO_AUTH_DB" 2>/dev/null | grep -q "^1$"; then
        log.fatal "ERROR: MongoDB did not respond to ping. Exiting..."
        exit 1
    fi

    log.trace "Checking/creating staging dir..."
    mkdir -p "$BACKUP_DIR"
    if ! [ -d "$BACKUP_DIR" ]; then
        log.fatal "ERROR: could not create '$BACKUP_DIR'. Exiting..."
        exit 1
    fi
}

function main () {
    load_discord_webhook
    trap 'discord_report_exit $?' EXIT

    discord_notify "🟡 Backup started."

    validations

    generate_redis_backup
    generate_mongo_backup

    FILES="$BACKUP_DIR/$REDIS_BACKUP_FILE:/redis,$BACKUP_DIR/$MONGO_BACKUP_FILE:/mongodb"

    log.info "Uploading through pbackup..."
    pbackup --files "$FILES" -t "$UOE_URL" --token "$UOE_TOKEN"
    local pbackup_exit=$?
    if [ "$pbackup_exit" -ne 0 ]; then
        log.fatal "ERROR: pbackup upload failed (exit code $pbackup_exit). Local backup files were kept in '$BACKUP_DIR' for manual retry. Exiting..."
        exit 1
    fi

    log.debug "Cleaning backup files from local machine..."
    for f in "$BACKUP_DIR/$REDIS_BACKUP_FILE" "$BACKUP_DIR/$MONGO_BACKUP_FILE"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            log.trace "- '$f' deleted."
        else
            log.error "ERROR: '$f' was not found. We aren't going to perform any delete operation in order to avoid deleting other files."
        fi
    done
    rmdir "$BACKUP_DIR" 2>/dev/null

    log.info "All done!"
}

case "$1" in
    -h|--help)
        print_help
        exit 0
        ;;
    -l|--logs)
        exec tail -f "$_LOG_FILE"
        ;;
esac

main "$@"
