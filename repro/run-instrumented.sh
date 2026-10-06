#!/usr/bin/env bash
# Take over the GPU from the systemd qwen38 unit and run the SAME server binary
# as a cuda-gdb child (via fifo stdin) so we can interrupt + 'info cuda kernels'
# when the Xid-8 wedge happens.
#
# Usage: run-instrumented.sh [extra server args...]
# BIN env overrides the server binary (default: the crashed production build;
# leg 2 of validation plan v2 points it at the worktree fixed build).
set -u
BIN="${BIN:-/home/jason/Work/llama-cpp-moecache/build/bin/llama-server}"
FIFO=/tmp/cuda-gdb-in.fifo
CGDB_OUT="${CGDB_OUT:-$HOME/logs/xid8-cgdb-server.log}"
PORT="${PORT:-8037}"

# 1. stop the systemd instance (clean SIGTERM -> exit 0 -> no restart)
pid=$(ss -tlnp "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | head -1)
if [ -n "$pid" ]; then
    echo "[$(date -Is)] stopping systemd instance pid $pid" >&2
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
fi
sleep 2

rm -f "$FIFO"; mkfifo "$FIFO"

# clock-state evidence: which profile this leg ran under
nvidia-smi -q -d CLOCK >> "$CGDB_OUT" 2>&1 || true
nvidia-smi --query-gpu=clocks.max.mem,clocks.max.sm,power.limit --format=csv >> "$CGDB_OUT" 2>&1 || true

# keep fifo open for gdb stdin (EOF would make gdb quit); feed start commands
(
    exec 9>"$FIFO"
    sleep 2
    echo "set pagination off" >&9
    echo "set confirm off" >&9
    echo "run" >&9
    # hold fd9 open forever so gdb never sees EOF
    while sleep 3600; do :; done
) &

# shellcheck disable=SC2086
/opt/cuda/bin/cuda-gdb \
    --args "$BIN" \
      -m /mnt/models/models/Qwen3.8-27B-W2/Qwen3.8-27B-UD-Q2_K_XL.gguf \
      --alias Qwen3.8-27B-W2 --host 127.0.0.1 --port "$PORT" \
      -ngl 999 -np 1 -c 131072 -t 8 -fa on -ctk turbo4 -ctv turbo3 \
      -b 2048 -ub 512 --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-ngl 999 \
      --jinja --slots --metrics --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
      --repeat-penalty 1.05 --n-predict 24576 --reasoning-budget 12288 \
      "$@" < "$FIFO" >> "$CGDB_OUT" 2>&1 &
echo "[$(date -Is)] starting cuda-gdb (server on :$PORT)" >&2
echo "cuda-gdb pid $!"

# stay alive so the systemd-run user unit does not kill the backgrounded cuda-gdb
echo "[$(date -Is)] holding unit open (ctrl: kill this unit to stop)" >&2
while pgrep -f 'cuda-gdb-python|cuda-gdb-minimal|bin/cuda-gdb' >/dev/null 2>&1; do sleep 10; done
echo "[$(date -Is)] cuda-gdb gone, unit exiting" >&2
