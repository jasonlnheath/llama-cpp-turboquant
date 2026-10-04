#!/usr/bin/env bash
# Detect a decode stall (hang) on the qwen38 server and dump the running CUDA
# kernels with cuda-gdb before the RC watchdog aborts the process.
#
# Signal: server log goes silent (no print_timing) for >STALL_SEC while a task
# was actively decoding (last line shows n_decoded progress). Then:
#   1. cuda-gdb attach -> "info cuda kernels" (names the wedged kernel)
#   2. also grab nvidia-smi and kernel log tail
# Fires once per stall, re-arms after the server recovers/restarts.
set -u
LOG="${LOG:-$HOME/logs/qwen38-8037.log}"
OUT="${OUT:-$HOME/logs/xid8-hang-dumps.log}"
STALL_SEC="${STALL_SEC:-4}"
COOLDOWN="${COOLDOWN:-120}"

last_size=0
last_change=$(date +%s)
armed=1
echo "[$(date -Is)] stall-detector armed (stall=${STALL_SEC}s)" >> "$OUT"

while true; do
    sleep 1
    size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    now=$(date +%s)

    if [ "$size" != "$last_size" ]; then
        last_size=$size
        last_change=$now
        # log moved; re-arm if we are past cooldown
        if [ $((now - 0)) -gt "$COOLDOWN" ] 2>/dev/null; then
            armed=1
        fi
        continue
    fi

    # log silent: check whether a task is actively decoding
    if [ $((now - last_change)) -lt "$STALL_SEC" ] || [ "$armed" -ne 1 ]; then
        continue
    fi

    tail_line=$(tail -1 "$LOG" 2>/dev/null | cut -c1-200)
    case "$tail_line" in
        *n_decoded*|*prompt*)
            # active task but silent = likely GPU hang in progress
            echo "[$(date -Is)] STALL DETECTED: log silent ${STALL_SEC}s, last: $tail_line" >> "$OUT"
            pid=$(pgrep -f 'llama-cpp-moecache/build/bin/llama-server' | head -1)
            if [ -n "$pid" ]; then
                echo "[$(date -Is)] attaching cuda-gdb to pid $pid" >> "$OUT"
                timeout 25 cuda-gdb -p "$pid" -batch \
                    -ex 'set pagination off' \
                    -ex 'info cuda kernels' \
                    -ex 'thread apply all bt 8' >> "$OUT" 2>&1
                echo "[$(date -Is)] cuda-gdb done (rc=$?)" >> "$OUT"
            else
                echo "[$(date -Is)] no llama-server pid found" >> "$OUT"
            fi
            journalctl -k --since "-2 min" --no-pager 2>/dev/null | grep -iE "xid|nvrm" | tail -8 >> "$OUT"
            nvidia-smi >> "$OUT" 2>&1
            armed=0
            ;;
    esac
done
