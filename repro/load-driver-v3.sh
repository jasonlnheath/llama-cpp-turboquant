#!/usr/bin/env bash
# Sustained-load driver v3: deep-context repro.
# Targets the observed crash signature: 50-80K-token contexts, LCP prefix reuse
# (f_keep ~1.0), long decodes, occasional aborts, multiple prompt families.
set -u
PORT="${PORT:-8037}"
OUT="${OUT:-$HOME/logs/xid8-repro-driver.log}"
DUR="${DUR:-21600}"
START=$(date +%s)

mkfam() { # $1 family: stable ~20k-token prefix
python3 - "$1" <<'EOF'
import random, sys
random.seed(9000 + int(sys.argv[1]))
words = [f"w{i:03d}" for i in range(800)]
out = []
for seg in range(20):
    out.append(" ".join(random.choice(words) for _ in range(1000)))
print(" || ".join(out))
EOF
}

mktail() { # $1 seed: per-task ~5k-token varying suffix
python3 - "$1" <<'EOF'
import random, sys
random.seed(70000 + int(sys.argv[1]))
words = [f"w{i:03d}" for i in range(800)]
print(" ".join(random.choice(words) for _ in range(2500)))
EOF
}

declare -A FAM
for f in 0 1; do FAM[$f]=$(mkfam "$f"); done

task=0
while [ $(( $(date +%s) - START )) -lt "$DUR" ]; do
    task=$((task+1))
    fam=$((task % 2))
    seed=$task
    T=$(mktail "$seed")
    P="${FAM[$fam]} $T"

    gens=(8192 12288 16384)
    gen=${gens[$((task % 3))]}
    abort=""
    if [ $((task % 7)) -eq 3 ]; then abort="-m 40"; fi

    echo "[$(date -Is)] task $task fam=$fam gen=$gen start ${abort:+(abort)}" >> "$OUT"
    curl -sS ${abort:--m 3600} "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"messages\":[{\"role\":\"system\",\"content\":\"You are a diligent assistant. First absorb: $P\"},{\"role\":\"user\",\"content\":\"Now produce an exhaustive structured summary of every segment, then a long essay on memory hierarchies. Additional material: $T\"}],\"max_tokens\":$gen,\"temperature\":1.0,\"top_p\":0.95,\"cache_prompt\":true,\"stream\":false}" \
      -o /dev/null >> "$OUT" 2>&1
    rc=$?
    echo "[$(date -Is)] task $task end rc=$rc" >> "$OUT"
done
echo "[$(date -Is)] driver done after $task tasks" >> "$OUT"
