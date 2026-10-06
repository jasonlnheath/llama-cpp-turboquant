#!/usr/bin/env bash
# Restore the qwen38 lane after experiments: stop any ab/instrumented instance,
# then relaunch the standard server via the fleet launcher under setsid so it
# survives this shell (systemd unit stays inactive; same binary/flags/port).
set -u
PORT=8037
FIFO=/tmp/cuda-gdb-in.fifo

listener_pid() {
    ss -tlnp "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | head -1
}

# instrumented leg: fifo 'kill' then 'quit' to gdb first - its server child
# ignores TERM once gdb is gone (ptrace state); timeout bounds a dead-reader fifo
if pgrep -f 'cuda-gdb-python|cuda-gdb-minimal|bin/cuda-gdb' >/dev/null 2>&1 && [ -p "$FIFO" ]; then
    timeout 5 bash -c "echo kill > '$FIFO'" 2>/dev/null
    sleep 2
    timeout 5 bash -c "echo quit > '$FIFO'" 2>/dev/null
    for _ in $(seq 1 30); do
        pgrep -f 'cuda-gdb-python|cuda-gdb-minimal|bin/cuda-gdb' >/dev/null 2>&1 || break
        sleep 1
    done
fi

pid=$(listener_pid)
if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 90); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
fi
pkill -f 'stall-detector' 2>/dev/null
pkill -f 'xid-watch' 2>/dev/null
pkill -f 'run-instrumented' 2>/dev/null
sleep 2
setsid nohup /home/jason/Work/qwen38-8037.sh </dev/null >/dev/null 2>&1 &
sleep 1
for _ in $(seq 1 120); do pid=$(listener_pid); [ -n "$pid" ] && break; sleep 1; done
echo "restored: ${pid:-not listening on $PORT yet}"
