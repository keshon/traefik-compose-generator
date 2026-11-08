#!/bin/sh
# Compatibility helper for legacy file logs. New deployments use Docker log rotation.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
. "$ROOT/lib/common.sh"
ENV_FILE=${ENV_FILE:-$ROOT/.env}
if [ -f "$ENV_FILE" ]; then load_env; fi
: "${LOGS_DIR:=${DATA_DIR:-$ROOT/traefik-data}/logs}"
: "${LOG_ROTATE_TRIGGER_SIZE:=10m}" "${LOG_ROTATE_MAX_BACKUPS:=5}" "${LOGROTATE_INTERVAL:=60}"
: "${TRAEFIK_CONTAINER:=traefik}"
positive_integer LOG_ROTATE_MAX_BACKUPS "$LOG_ROTATE_MAX_BACKUPS"
positive_integer LOGROTATE_INTERVAL "$LOGROTATE_INTERVAL"
printf '%s\n' "$LOG_ROTATE_TRIGGER_SIZE" | grep -Eq '^[1-9][0-9]*[kKmMgG]$' || die 'Invalid log size'
number=${LOG_ROTATE_TRIGGER_SIZE%?}
case "$LOG_ROTATE_TRIGGER_SIZE" in *[kK]) multiplier=1024 ;; *[mM]) multiplier=1048576 ;; *[gG]) multiplier=1073741824 ;; esac
trigger=$((number * multiplier))
case "${1:---once}" in --once|--watch) mode=${1:---once} ;; *) die 'Usage: sh traefik-logrotate.sh [--once|--watch]' ;; esac
command -v docker >/dev/null 2>&1 || die 'Docker is required to signal the legacy Traefik container'
[ -d "$LOGS_DIR" ] || die "Missing legacy log directory: $LOGS_DIR"
while :; do
    for log in "$LOGS_DIR"/*.log; do
        [ -f "$log" ] || continue
        size=$(wc -c < "$log" | tr -d ' ')
        [ "$size" -ge "$trigger" ] || continue
        # Verify the target before renaming files. No copy/truncate data-loss window.
        docker inspect "$TRAEFIK_CONTAINER" >/dev/null
        i=$LOG_ROTATE_MAX_BACKUPS
        while [ "$i" -gt 1 ]; do
            previous=$((i - 1))
            if [ -f "$log.$previous" ]; then mv -f "$log.$previous" "$log.$i"; fi
            i=$previous
        done
        mv "$log" "$log.1"
        if ! docker kill --signal=USR1 "$TRAEFIK_CONTAINER" >/dev/null; then
            mv "$log.1" "$log"
            die 'Failed to reopen Traefik logs; restored the active log'
        fi
        printf 'Rotated %s\n' "$log"
    done
    [ "$mode" = --watch ] || break
    sleep "$LOGROTATE_INTERVAL"
done
