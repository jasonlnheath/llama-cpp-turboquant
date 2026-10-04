#!/usr/bin/env bash
# Sustained-load driver v4: multi-client interleaved load matching production.
#
# Why v4: all six Xid-8 crashes hit under real fleet traffic (several workers
# + Jemma interleaving /v1/chat/completions with tools, streaming aborts and
# /slots + /metrics polling). v1-v3 were single-client sequential and never
# reproduced in ~1h35m. v4 runs three concurrent task shapes on the same slot:
#   A) deep-context long decodes (v3 pattern: LCP reuse, f_keep~1.0)
#   B) short-task churn with mid-stream aborts (disconnect ~2-6s in)
#   C) poller: /slots + /metrics + /health hammering
# plus occasional JSON-schema constrained requests (grammar sampler path).
set -u
PORT="${PORT:-8037}"
OUT="${OUT:-$HOME/logs/xid8-repro-driver-v4.log}"
DUR="${DUR:-7200}"
START=$(date +%s)

mkfam() { python3 - "$1" <<'EOF'
import random, sys
random.seed(9000 + int(sys.argv[1]))
words = [f"w{i:03d}" for i in range(800)]
out = []
for seg in range(20):
    out.append(" ".join(random.choice(words) for _ in range(1000)))
print(" || ".join(out))
EOF
}

mktail() { python3 - "$1" <<'EOF'
import random, sys, zlib
random.seed(70000 + zlib.crc32(sys.argv[1].encode()))
words = [f"w{i:03d}" for i in range(800)]
print(" ".join(random.choice(words) for _ in range(2500)))
EOF
}

declare -A FAM
for f in 0 1; do FAM[$f]=$(mkfam "$f"); done

# --- Worker A: deep-context long decodes (v3 pattern) ---
(
  task=0
  while [ $(( $(date +%s) - START )) -lt "$DUR" ]; do
    task=$((task+1)); fam=$((task % 2))
    T=$(mktail "A$task"); P="${FAM[$fam]} $T"
    gen=$((8192 + 4096 * (task % 3)))
    echo "[$(date -Is)] A task $task fam=$fam gen=$gen start" >> "$OUT"
    curl -sS -m 3600 "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"messages\":[{\"role\":\"system\",\"content\":\"You are a diligent assistant. First absorb: $P\"},{\"role\":\"user\",\"content\":\"Now produce an exhaustive structured summary of every segment, then a long essay on memory hierarchies. Additional material: $T\"}],\"max_tokens\":$gen,\"temperature\":1.0,\"top_p\":0.95,\"cache_prompt\":true,\"stream\":false}" \
      -o /dev/null >> "$OUT" 2>&1
    echo "[$(date -Is)] A task $task end rc=$?" >> "$OUT"
    sleep 2
  done
) &

# --- Worker B: short-task churn with streaming aborts ---
(
  task=0
  while [ $(( $(date +%s) - START )) -lt "$DUR" ]; do
    task=$((task+1))
    T=$(mktail "B$task")
    # every 3rd task: abort a streaming request mid-decode (client disconnect)
    if [ $((task % 3)) -eq 0 ]; then
      echo "[$(date -Is)] B task $task abort-stream start" >> "$OUT"
      curl -sS -N -m $((2 + task % 5)) "http://127.0.0.1:$PORT/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Write a long story. Context: $T\"}],\"max_tokens\":4096,\"temperature\":1.0,\"top_p\":0.95,\"cache_prompt\":true,\"stream\":true}" \
        -o /dev/null >> "$OUT" 2>&1
    else
      # every 5th: JSON-schema constrained output (grammar path)
      if [ $((task % 5)) -eq 2 ]; then
        echo "[$(date -Is)] B task $task schema start" >> "$OUT"
        curl -sS -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Summarize as JSON. Context: $T\"}],\"max_tokens\":2048,\"temperature\":0.3,\"cache_prompt\":true,\"stream\":false,\"response_format\":{\"type\":\"json_object\"}}" \
          -o /dev/null >> "$OUT" 2>&1
      else
        echo "[$(date -Is)] B task $task short start" >> "$OUT"
        curl -sS -m 600 "http://127.0.0.1:$PORT/v1/chat/completions" \
          -H 'Content-Type: application/json' \
          -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Answer briefly then stop. Context: $T\"}],\"max_tokens\":1500,\"temperature\":1.0,\"top_p\":0.95,\"cache_prompt\":true,\"stream\":false}" \
          -o /dev/null >> "$OUT" 2>&1
      fi
    fi
    echo "[$(date -Is)] B task $task end rc=$?" >> "$OUT"
    sleep 4
  done
) &

# --- Worker C: poller (mirrors fleet monitoring) ---
(
  while [ $(( $(date +%s) - START )) -lt "$DUR" ]; do
    curl -sS -m 5 "http://127.0.0.1:$PORT/slots"  -o /dev/null 2>/dev/null
    curl -sS -m 5 "http://127.0.0.1:$PORT/metrics" -o /dev/null 2>/dev/null
    curl -sS -m 5 "http://127.0.0.1:$PORT/health"  -o /dev/null 2>/dev/null
    sleep 1
  done
) &

wait
echo "[$(date -Is)] v4 driver done after ${DUR}s" >> "$OUT"
