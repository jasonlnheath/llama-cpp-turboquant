#!/usr/bin/env bash
# Sustained-load driver v2 for the qwen38 (:8037) Xid 8 repro.
# Mimics worker traffic more faithfully than v1:
#   - alternating prompt families (multiple prompt-cache entries + evictions)
#   - prefix reuse within a family (LCP similarity f_keep transitions)
#   - occasional mid-generation aborts (worker timeouts/cancels)
#   - long generations at high KV occupancy
set -u
PORT="${PORT:-8037}"
OUT="${OUT:-$HOME/logs/xid8-repro-driver.log}"
DUR="${DUR:-14400}"
START=$(date +%s)

mkprompt() { # $1 = family id, $2 = seed
python3 - "$1" "$2" <<'EOF'
import random, sys
fam, seed = int(sys.argv[1]), int(sys.argv[2])
random.seed(fam * 1000 + seed)
words = [f"w{i:03d}" for i in range(800)]
# family-defining prefix (shared within a family -> LCP reuse)
head = " ".join(random.choice(words) for _ in range(600))
para = " ".join(random.choice(words) for _ in range(1200))
print(f"{head} || {para}")
EOF
}

# cache prompts per family so the family prefix stays stable across tasks
declare -A FAM
for f in 0 1 2 3; do FAM[$f]=$(mkprompt "$f" 0); done

task=0
while [ $(( $(date +%s) - START )) -lt "$DUR" ]; do
    task=$((task+1))
    fam=$((task % 4))
    seed=$((task / 4))
    tail_txt=$(mkprompt "$fam" "$seed")
    P="${FAM[$fam]} $tail_txt"

    # ~1 in 6 tasks: abort mid-generation (worker timeout style)
    abort=""
    if [ $((task % 6)) -eq 3 ]; then abort="-m 25"; fi

    ts=$(date -Is)
    echo "[$ts] task $task fam=$fam start ${abort:+(abort-mode)}" >> "$OUT"
    curl -sS ${abort:--m 1800} "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"messages\":[{\"role\":\"system\",\"content\":\"You are a diligent assistant. $P\"},{\"role\":\"user\",\"content\":\"First repeat the system text verbatim, then write a very long technical essay about GPU memory systems. $P\"}],\"max_tokens\":4096,\"temperature\":1.0,\"top_p\":0.95,\"cache_prompt\":true}" \
      -o /dev/null >> "$OUT" 2>&1
    rc=$?
    echo "[$(date -Is)] task $task end rc=$rc" >> "$OUT"
    [ $rc -ne 0 ] && echo "[$(date -Is)] DRIVER: curl rc=$rc (ok for abort-mode)" >> "$OUT"
done
echo "[$(date -Is)] driver done after $task tasks" >> "$OUT"
