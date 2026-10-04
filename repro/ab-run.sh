#!/usr/bin/env bash
# A/B experiment runner: restart the qwen38 server (same binary) with a given
# variant env/args, run the load driver for N minutes, log the outcome.
#
# Usage: ab-run.sh <label> <minutes> [extra server args...]
#   special extra arg NOSPEC -> omit the --spec-type draft-mtp flags entirely
# Env for the server can be injected via AB_ENV="GGML_CUDA_PDL=0" ab-run.sh ...
# Plan v2: legs run the multi-client v4 driver (production-like interleave).
# DRIVER env selects an alternative load-driver-<name>.sh in this directory.
set -u
LABEL="$1"; MINS="$2"; shift 2
# AB_BIN overrides the server binary (default: the crashed production build;
# post-fix runs point this at the worktree build, see SESSION-NOTES.md)
BIN="${AB_BIN:-/home/jason/Work/llama-cpp-moecache/build/bin/llama-server}"
SRVLOG="$HOME/logs/ab-$LABEL-server.log"
DRVLOG="$HOME/logs/ab-$LABEL-driver.log"
SUM="$HOME/logs/ab-summary.log"

# stop whatever server is running on 8037 (systemd instance or previous ab instance)
pid=$(pgrep -f 'llama-server.*--port 8037' | head -1)
if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null; for i in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done; fi
sleep 2

echo "[$(date -Is)] AB $LABEL start (env: ${AB_ENV:-none}, extra: $*, bin: $BIN)" >> "$SUM"
# clock-state evidence: which profile this leg ran under (attribution per plan v2)
nvidia-smi -q -d CLOCK >> "$SRVLOG" 2>&1 || true
nvidia-smi --query-gpu=clocks.max.mem,clocks.max.sm,power.limit --format=csv >> "$SRVLOG" 2>&1 || true
SPECARGS="--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-ngl 999"
for a in "$@"; do [ "$a" = "NOSPEC" ] && SPECARGS=""; done

# shellcheck disable=SC2086
setsid env ${AB_ENV:-} "$BIN" \
  -m /mnt/models/models/Qwen3.8-27B-W2/Qwen3.8-27B-UD-Q2_K_XL.gguf \
  --alias Qwen3.8-27B-W2 --host 127.0.0.1 --port 8037 \
  -ngl 999 -np 1 -c 131072 -t 8 -fa on -ctk turbo4 -ctv turbo3 \
  -b 2048 -ub 512 $SPECARGS \
  --jinja --slots --metrics --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --repeat-penalty 1.05 --n-predict 24576 --reasoning-budget 12288 \
  "$@" >> "$SRVLOG" 2>&1 &
SRVPID=$!

# wait for readiness
for i in $(seq 1 180); do
    curl -s -m 2 "http://127.0.0.1:8037/health" 2>/dev/null | grep -q ok && break
    kill -0 "$SRVPID" 2>/dev/null || { echo "[$(date -Is)] AB $LABEL server died during startup" >> "$SUM"; exit 1; }
    sleep 1
done

DUR=$((MINS*60)) OUT="$DRVLOG" PORT=8037 setsid bash "$(dirname "$0")/load-driver-${DRIVER:-v4}.sh" </dev/null >/dev/null 2>&1 &
DRVPID=$!
echo "server=$SRVPID driver=$DRVPID"

end=$(( $(date +%s) + MINS*60 + 120 ))
while [ "$(date +%s)" -lt "$end" ]; do
    kill -0 "$SRVPID" 2>/dev/null || {
        echo "[$(date -Is)] AB $LABEL RESULT: SERVER DIED" >> "$SUM"
        journalctl -k --since "-5 min" --no-pager 2>/dev/null | grep -iE "xid" | tail -3 >> "$SUM"
        tail -20 "$SRVLOG" | grep -E "CUDA error|abort" | head -3 >> "$SUM"
        exit 2
    }
    sleep 10
done
kill -- -"$DRVPID" 2>/dev/null; kill "$DRVPID" 2>/dev/null   # group kill: v4 workers are subshells
n_xid=$(journalctl -k --since "-$((MINS+2)) min" --no-pager 2>/dev/null | grep -c Xid)
echo "[$(date -Is)] AB $LABEL RESULT: survived ${MINS}min (xid_count=$n_xid)" >> "$SUM"
exit 0
