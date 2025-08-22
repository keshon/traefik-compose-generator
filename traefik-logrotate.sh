#!/bin/sh
# traefik-logrotate.sh - Simple log rotation for Traefik logs

echo "------------------------------"
echo "Traefik Log Rotate"
echo "------------------------------"

# -------------------------------
# Constants
# -------------------------------
DEFAULT_TRIGGER_SIZE="50M"
DEFAULT_MAX_BACKUPS="14"
DEFAULT_INTERVAL="60"

# -------------------------------
# Parse command line arguments
# -------------------------------
WATCH_MODE=false
if [ "$1" = "--watch" ]; then
    WATCH_MODE=true
fi

# -------------------------------
# Load environment variables
# -------------------------------
if [ -f .env ]; then
    # shellcheck source=/dev/null
    . ./.env
else
    echo ".env file not found - using default settings"
fi

# -------------------------------
# Set configuration variables
# -------------------------------
if [ -z "$DATA_DIR" ]; then
    echo "DATA_DIR is not set. Using current directory..."
    DATA_DIR=.
fi

LOGS_DIR="${DATA_DIR}/logs"
LOG_ROTATE_TRIGGER_SIZE="${LOG_ROTATE_TRIGGER_SIZE:-$DEFAULT_TRIGGER_SIZE}"
LOG_ROTATE_MAX_BACKUPS="${LOG_ROTATE_MAX_BACKUPS:-$DEFAULT_MAX_BACKUPS}"
INTERVAL="${LOGROTATE_INTERVAL:-$DEFAULT_INTERVAL}"

echo "Logs dir:   $LOGS_DIR"
echo "Max backup: $LOG_ROTATE_MAX_BACKUPS"
echo "Trigger:    $LOG_ROTATE_TRIGGER_SIZE"
echo "Mode:       $([ "$WATCH_MODE" = true ] && echo "Watch mode (interval ${INTERVAL}s)" || echo "Single run")"
echo "Log rotation check starting..."

# -------------------------------
# Check logs directory
# -------------------------------
if [ -d "$LOGS_DIR" ]; then
    echo "---- Contents of $LOGS_DIR ----"
    ls -lh "$LOGS_DIR"
    echo "--------------------------------"
else
    echo "Logs directory not found: $LOGS_DIR"
fi

# -------------------------------
# Helper functions
# -------------------------------
to_bytes() {
    size="$1"
    num=$(echo "$size" | grep -o '[0-9]\+')
    unit=$(echo "$size" | grep -o '[KMG]' | tr '[:lower:]' '[:upper:]')

    case "$unit" in
        K) echo $((num * 1024)) ;;
        M) echo $((num * 1024 * 1024)) ;;
        G) echo $((num * 1024 * 1024 * 1024)) ;;
        *) echo "$num" ;;
    esac
}

rotate_log() {
    log_file="$1"
    echo "Rotating $log_file ..."
    
    # Shift existing backups
    i=$LOG_ROTATE_MAX_BACKUPS
    while [ $i -ge 1 ]; do
        if [ -f "$log_file.$i" ]; then
            if [ $i -ge $LOG_ROTATE_MAX_BACKUPS ]; then
                echo "Removing old backup: $log_file.$i"
                rm -f "$log_file.$i"
            else
                mv "$log_file.$i" "$log_file.$((i+1))"
            fi
        fi
        i=$((i-1))
    done
    
    # Create new backup and clear log
    if [ -f "$log_file" ]; then
        cp "$log_file" "$log_file.1"
        echo "$log_file → $log_file.1"
        
        # Signal Traefik to reopen log files
        if command -v docker >/dev/null 2>&1; then
            traefik_id=$(docker ps --quiet --filter "name=^traefik$" | head -n1)
            if [ -n "$traefik_id" ]; then
                echo "Sending USR1 to Traefik container $traefik_id"
                docker kill -s USR1 "$traefik_id" >/dev/null 2>&1 || true
                sleep 1
            fi
        fi
        
        > "$log_file"
    echo "Log rotation completed for $log_file"
    fi
}

check_logs() {
    TRIGGER_BYTES=$(to_bytes "$LOG_ROTATE_TRIGGER_SIZE")
    
    for log in "$LOGS_DIR"/*.log; do
        [ -f "$log" ] || continue
        
        # Get file size in cross-platform way
        size=$(stat -c %s "$log" 2>/dev/null || stat -f %z "$log" 2>/dev/null || echo 0)
        
        if [ "$size" -ge "$TRIGGER_BYTES" ]; then
            rotate_log "$log"
        else
            echo "$log size: $size bytes (< $TRIGGER_BYTES) → skipping"
        fi
    done
}

# -------------------------------
# Main execution logic
# -------------------------------
if [ "$WATCH_MODE" = true ]; then
    echo "Starting watch loop (interval ${INTERVAL}s)..."
    while true; do
        check_logs
        sleep "$INTERVAL"
    done
else
    check_logs
fi