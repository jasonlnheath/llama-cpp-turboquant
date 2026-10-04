#!/usr/bin/env bash
# Sustained-load driver for the qwen38 (:8037) Xid 8 repro.
# Mimics worker traffic: alternating large-prompt prefill + long decode,
# back-to-back tasks with no idle gaps. Logs each task start/end.
set -u
PORT="${PORT:-8037}"
OUT="${OUT:-$HOME/logs/xid8-repro-driver.log}"
DUR="${DUR:-7200}"    # total seconds, default 2h
START=$(date +%s)

# ~2k-token filler paragraph repeated to make a big prompt
P1=$(python3 - <<'EOF'
import random
random.seed(42)
words = [f"w{i:03d}" for i in range(800)]
para = " ".join(random.choice(words) for _ in range(3500))
print(para)
EOF
)

task=0
while [ $(( $(date +%s) - START )) -lt "$DUR" ]; do
    task=$((task+1))
    ts=$(date -Is)
    echo "[$ts] task $task start" >> "$OUT"
    curl -sS -m 1800 "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"messages\":[{\"role\":\"system\",\"content\":\"You are a diligent assistant. $P1\"},{\"role\":\"user\",\"content\":\"Summarize the system text above in exhaustive detail, then write a long essay about compilers. $P1\"}],\"max_tokens\":4096,\"temperature\":1.0,\"top_p\":0.95,\"cache_prompt\":true}" \
      -o /dev/null >> "$OUT" 2>&1
    rc=$?
    ts=$(date -Is)
    echo "[$ts] task $task end rc=$rc" >> "$OUT"
    if [ $rc -ne 0 ]; then
        echo "[$ts] DRIVER: curl failed rc=$rc - server may have died" >> "$OUT"
        break
    fi
done
echo "[$(date -Is)] driver done after $task tasks" >> "$OUT"
