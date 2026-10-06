#!/usr/bin/env bash
# Perf leg: prefill/decode t/s at the current clock setting (house bench rules:
# unique word-salad per depth per pass, cache_prompt=false, two-shot steady-state
# = report the SECOND pass). Same numeric seed recipe for every leg so legs compare.
#
# Usage: perf-bench.sh <label> [server_log]
#   label      -> results appended to ~/logs/v2-perf-<label>.log
#   server_log -> llama-server log to parse print_timing from (default: the
#                 v2 smoke/perf server log). Run against a DEDICATED server
#                 instance (no other traffic) for clean attribution.
set -u
PORT="${PORT:-8037}"
LABEL="$1"
SRVLOG="${2:-$HOME/logs/v2-smoke-server.log}"
OUT="$HOME/logs/v2-perf-$LABEL.log"
RUNTAG="${SEEDTAG:-$(date +%s)}"   # SEEDTAG pins the salad seeds (cross-clock same-prompt comparison)

salad() { # depth seed  (both numeric)
  python3 - "$1" "$2" <<'EOF'
import random, sys
depth, seed = int(sys.argv[1]), int(sys.argv[2])
random.seed(seed)
words = [f"w{random.randint(0,999999)}_{i:04d}" for i in range(depth * 2)]
print(" ".join(random.choice(words) for _ in range(depth)))
EOF
}

gen_pass() { # pass_num (0=warmup 1=steady)
  local pnum="$1" depth seed before P
  for depth in 512 2048 8192; do
    seed=$(( (RUNTAG % 1000000) * 100 + pnum * 7 + depth ))
    P=$(salad "$depth" "$seed")
    before=$(wc -l < "$SRVLOG")
    curl -sS -m 600 "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"messages\":[{\"role\":\"system\",\"content\":\"Absorb this material: $P\"},{\"role\":\"user\",\"content\":\"Summarize the material in one paragraph, then count the distinct word shapes you saw.\"}],\"max_tokens\":512,\"temperature\":0.7,\"top_p\":0.95,\"cache_prompt\":false,\"stream\":false}" \
      -o /dev/null
    sleep 1
    tail -n +$((before+1)) "$SRVLOG" | grep "eval time =" | tail -2 | sed "s/^/[perf $LABEL d=$depth pass=$pnum] /" >> "$OUT"
  done
}

repro_dir="$(cd "$(dirname "$0")" && pwd)"
"$repro_dir/clock-snap.sh" "$OUT" "perf-$LABEL"
echo "=== perf-bench $LABEL start $(date -Is) runtag=$RUNTAG ===" >> "$OUT"
gen_pass 0
gen_pass 1
{
  echo "=== perf-bench $LABEL STEADY SUMMARY (pass=1) $(date -Is) ==="
  grep "pass=1" "$OUT" | grep "eval time ="
} >> "$OUT"
echo "perf-bench $LABEL complete -> $OUT"
