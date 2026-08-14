#!/usr/bin/env bash
# Clean A/B: ub2048+prefetch vs ub512 baseline, on a test port WITHOUT --cache-reuse (real prefill).
# No MTP (decode-side, orthogonal to prefill). Battery 150..2500 tokens -> shows pp_t/s vs context curve.
set +e
SRV=/c/dev/llama-cpp-turboquant/build/bin/Release/llama-server.exe
MODEL=/d/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf
PORT=8046
OUT=/tmp/fable7_ab
BASE="-m $MODEL --host 127.0.0.1 --port $PORT -ngl 999 --n-cpu-moe 36 -np 1 -c 8192 -t 8 -fa on --no-mmap -ctk turbo4 -ctv turbo3 -b 2048 --no-warmup --jinja"
PASSAGE="Computing evolved through generations of switching technology: vacuum tubes to transistors to integrated circuits to microprocessors, each smaller cheaper faster more reliable, while software and networking grew in parallel to form the modern accelerated interconnected world we rely on today. "
wait_health() { for i in $(seq 1 150); do curl -sf -m 2 http://127.0.0.1:$PORT/health >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
free_port()   { for i in $(seq 1 40); do netstat -ano 2>/dev/null | grep -q ":$PORT.*LISTEN" || return 0; sleep 1; done; }
battery() {
  label=$1
  for size in 150 500 1200 2500; do
    MSG=$(python -c "import sys; p=sys.stdin.read(); n=max(1,$size//40); print('(cfg test $label $size) Summarize in one sentence. '+p*n)" <<<"$PASSAGE")
    PROMPT=$(python -c 'import sys,json; m=sys.stdin.read(); print(json.dumps({"messages":[{"role":"user","content":m}],"temperature":0,"seed":42,"max_tokens":20,"stream":False,"chat_template_kwargs":{"enable_thinking":False}}))' <<<"$MSG")
    RESP=$(curl -sf -m 120 -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d "$PROMPT")
    echo "$RESP" | python -c "
import sys,json
try:
    d=json.load(sys.stdin); t=d.get('timings',{})
    print(f'$label  size=$size  prompt_n={t.get(\"prompt_n\")}  pp_t/s={t.get(\"prompt_per_second\",0):.1f}')
except Exception as e:
    print('$label size=$size ERROR', e)
"
  done
}

echo "=== A: ub2048 + prefetch ==="
GGML_SCHED_PREFETCH_EXPERTS=1 "$SRV" $BASE -ub 2048 > $OUT.srvA.log 2>&1 &
A=$!; wait_health && battery "A-ub2048-pf" || echo "A failed to start"
kill $A 2>/dev/null; wait $A 2>/dev/null; free_port

echo "=== B: ub512 baseline ==="
env -u GGML_SCHED_PREFETCH_EXPERTS "$SRV" $BASE -ub 512 > $OUT.srvB.log 2>&1 &
B=$!; wait_health && battery "B-ub512" || echo "B failed to start"
kill $B 2>/dev/null; wait $B 2>/dev/null; free_port
echo "ALL DONE"
