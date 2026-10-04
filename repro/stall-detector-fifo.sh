#!/usr/bin/env bash
# On stall (server log silent while decoding), interrupt the cuda-gdb child and
# dump 'info cuda kernels' through the fifo.
set -u
LOG="${LOG:-$HOME/logs/xid8-cgdb-server.log}"
OUT="${OUT:-$HOME/logs/xid8-hang-dumps.log}"
FIFO=/tmp/cuda-gdb-in.fifo
STALL_SEC="${STALL_SEC:-4}"
COOLDOWN="${COOLDOWN:-90}"

last_size=0; last_change=$(date +%s); rearm_at=0
echo "[$(date -Is)] fifo stall-detector armed (log=$LOG)" >> "$OUT"
while true; do
    sleep 1
    size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ "$size" != "$last_size" ]; then
        last_size=$size; last_change=$now; continue
    fi
    [ $((now - last_change)) -lt "$STALL_SEC" ] && continue
    [ "$now" -lt "$rearm_at" ] && continue
    tail_line=$(tail -1 "$LOG" 2>/dev/null | cut -c1-160)
    case "$tail_line" in
        *n_decoded*|*prompt*|*eval*) kind=instrumented ;;
        *)                           kind=unrecognized ;;
    esac
    echo "[$(date -Is)] STALL ($kind tail); last: $tail_line" >> "$OUT"
    {
        timeout 5 bash -c "echo interrupt > '$FIFO'" 2>/dev/null
        sleep 2
        timeout 5 bash -c "echo 'info cuda kernels' > '$FIFO'" 2>/dev/null
        timeout 5 bash -c "echo 'info cuda contexts' > '$FIFO'" 2>/dev/null
        sleep 6
        timeout 5 bash -c "echo continue > '$FIFO'" 2>/dev/null
    } &
    rearm_at=$((now + COOLDOWN))
done
