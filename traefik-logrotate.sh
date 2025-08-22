#!/bin/sh
# traefik-logrotate.sh - Simple log rotation for Traefik logs
echo "--------------------------"
echo "Traefik Log Rotate"
echo "--------------------------"

if [ -f .env ]; then
    . .env
fi

if [ -z "$DATA_DIR" ]; then
    echo "DATA_DIR is not set. Using current directory..."
    DATA_DIR=.
fi

LOGS_DIR="${DATA_DIR}/logs"
LOG_ROTATE_TRIGGER_SIZE="${LOG_ROTATE_TRIGGER_SIZE:-50M}"
LOG_ROTATE_MAX_BACKUPS="${LOG_ROTATE_MAX_BACKUPS:-14}"
WATCH_MODE=false
INTERVAL="${LOGROTATE_INTERVAL:-60}" # seconds

if [ "$1" = "--watch" ]; then
    WATCH_MODE=true
fi

echo "Logs dir:   $LOGS_DIR"
echo "Max backup: $LOG_ROTATE_MAX_BACKUPS"
echo "Trigger:    $LOG_ROTATE_TRIGGER_SIZE"
if [ "$WATCH_MODE" = true ]; then
    echo "Mode:       Watch mode"
else
    echo "Mode:       Single run"
fi

if [ -d "$LOGS_DIR" ]; then
    echo "---- Contents of $LOGS_DIR ----"
    ls -lh "$LOGS_DIR"
    echo "--------------------------------"
else
    echo "Logs directory not found: $LOGS_DIR"
fi

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

TRIGGER_BYTES=$(to_bytes "$LOG_ROTATE_TRIGGER_SIZE")


rotate_log() {
    log_file="$1"
    echo "Rotating $log_file ..."
    
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
    
    if [ -f "$log_file" ]; then
        cp "$log_file" "$log_file.1"
        echo "$log_file → $log_file.1"
        
        if command -v docker >/dev/null 2>&1; then
            traefik_id=$(docker ps --quiet --filter "name=^traefik$" | head -n1)
            if [ -n "$traefik_id" ]; then
                echo "Sending USR1 to Traefik container $traefik_id"
                docker kill -s USR1 "$traefik_id" >/dev/null 2>&1 || true
                sleep 1
            fi
        fi
        
        > "$log_file"
        echo "Cleared original log file: $log_file"
    fi
}

check_logs() {
    for log in "$LOGS_DIR"/*.log; do
        [ -f "$log" ] || continue
        size=$(stat -c %s "$log" 2>/dev/null || stat -f %z "$log" 2>/dev/null || echo 0)
        if [ "$size" -ge "$TRIGGER_BYTES" ]; then
            rotate_log "$log"
        else
            echo "$log size: $size bytes (< $TRIGGER_BYTES) → skipping"
        fi
    done
}

if [ "$WATCH_MODE" = true ]; then
    echo "Starting watch loop (interval ${INTERVAL}s)..."
    while true; do
        check_logs
        sleep "$INTERVAL"
    done
else
    check_logs
fi
