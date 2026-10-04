#!/usr/bin/env bash
# Restore the qwen38 lane after experiments: stop any ab/instrumented instance,
# then relaunch the standard server via the fleet launcher under setsid so it
# survives this shell (systemd unit stays inactive; same binary/flags/port).
set -u
pid=$(pgrep -f 'llama-cpp-moecache/build/bin/llama-server' | head -1)
if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 90); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
fi
pkill -f 'stall-detector' 2>/dev/null
pkill -f 'xid-watch' 2>/dev/null
sleep 2
setsid nohup /home/jason/Work/qwen38-8037.sh </dev/null >/dev/null 2>&1 &
sleep 1
echo "restored: $(pgrep -f 'llama-cpp-moecache/build/bin/llama-server' | head -1)"
