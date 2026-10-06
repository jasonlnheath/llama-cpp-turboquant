#!/usr/bin/env bash
# Watch kernel log for Xid/NVRM lines and server liveness; append timestamps.
OUT="${OUT:-$HOME/logs/xid8-repro-watch.log}"
PORT="${PORT:-8037}"
DUR="${DUR:-7200}"
START=$(date +%s)
echo "[$(date -Is)] watcher start" >> "$OUT"
if ! journalctl -k -n 1 --no-pager >/dev/null 2>&1; then
    echo "[$(date -Is)] watcher DEAD: journalctl unreadable, no kernel-log surveillance" >> "$OUT"
    exit 1
fi
timeout "$DUR" journalctl -kf --no-pager 2>/dev/null | while read -r line; do
    case "$line" in
        *Xid*|*NVRM*|*krcWatchdog*)
            echo "[$(date -Is)] $line" >> "$OUT"
            ;;
    esac
    [ $(( $(date +%s) - START )) -ge "$DUR" ] && break
done
echo "[$(date -Is)] watcher done" >> "$OUT"
