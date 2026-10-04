#!/usr/bin/env bash
# On stall (server log silent while decoding), interrupt the cuda-gdb child and
# dump 'info cuda kernels' through the fifo.
set -u
LOG="${LOG:-$HOME/logs/xid8-cgdb-server.log}"
OUT="${OUT:-$HOME/logs/xid8-hang-dumps.log}"
FIFO=/tmp/cuda-gdb-in.fifo
STALL_SEC="${STALL_SEC:-4}"
COOLDOWN="${COOLDOWN:-90}"

last_size=0; last_change=$(date +%s); armed=1
echo "[$(date -Is)] fifo stall-detector armed (log=$LOG)" >> "$OUT"
while true; do
    sleep 1
    size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ "$size" != "$last_size" ]; then
        last_size=$size; last_change=$now; continue
    fi
    [ $((now - last_change)) -lt "$STALL_SEC" ] && continue
    [ "$armed" -ne 1 ] && continue
    tail_line=$(tail -1 "$LOG" 2>/dev/null | cut -c1-160)
    case "$tail_line" in
        *n_decoded*|*prompt*|*eval*)
            echo "[$(date -Is)] STALL on instrumented server; last: $tail_line" >> "$OUT"
            {
                echo "interrupt" > "$FIFO" 2>/dev/null
                sleep 2
                echo "info cuda kernels" > "$FIFO" 2>/dev/null
                echo "info cuda contexts" > "$FIFO" 2>/dev/null
                sleep 6
                echo "continue" > "$FIFO" 2>/dev/null
            } &
            armed=0
            (sleep "$COOLDOWN"; armed=1) &
            ;;
    esac
done
