#!/usr/bin/env bash
# Feature 2 (expert prefetch) benchmark + token-identical correctness check.
# Both configs use prod-like --no-mmap + n-cpu-moe 36; candidate adds GGML_SCHED_PREFETCH_EXPERTS=1.
# Prefetch is gated on op_offload (ncmoe>0) AND the env var; off by default -> baseline unaffected.
set +e
BIN=/c/dev/llama-cpp-turboquant/build/bin/Release/llama-bench.exe
SRV=/c/dev/llama-cpp-turboquant/build/bin/Release/llama-server.exe
MODEL=/d/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf
PORT=8046
OUT=/tmp/fable2_bench
PROMPT='{"messages":[{"role":"user","content":"List the three subtractive primary colors of pigment and give one sentence each on how they mix."}],"temperature":0,"seed":42,"max_tokens":96,"stream":false,"chat_template_kwargs":{"enable_thinking":false}}'
BENCH_COMMON="-m $MODEL -ngl 999 -ncmoe 36 -t 8 -fa 1 -b 2048 -ub 512 -ctk turbo4 -ctv turbo3 -p 512 -n 128 -r 10 -mmp 0"
SRV_COMMON="-m $MODEL --host 127.0.0.1 --port $PORT -ngl 999 --n-cpu-moe 36 -t 8 -fa on --no-mmap -ctk turbo4 -ctv turbo3 --no-warmup --jinja"
echo "START $(date)" > $OUT.runlog

wait_health() { for i in $(seq 1 120); do curl -s -m 2 http://127.0.0.1:$PORT/health >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
free_port()   { for i in $(seq 1 40); do netstat -ano 2>/dev/null | grep -q ":$PORT.*LISTEN" || return 0; sleep 1; done; }

# ---- SPEED ----
echo "=== speed baseline (prefetch OFF) ===" | tee -a $OUT.runlog
env -u GGML_SCHED_PREFETCH_EXPERTS "$BIN" $BENCH_COMMON > $OUT.speed_base.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog
echo "=== speed candidate (prefetch ON) ===" | tee -a $OUT.runlog
GGML_SCHED_PREFETCH_EXPERTS=1 "$BIN" $BENCH_COMMON > $OUT.speed_cand.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog

# ---- CORRECTNESS (token-identical, temp 0, fixed seed) ----
echo "=== correctness baseline ===" | tee -a $OUT.runlog
env -u GGML_SCHED_PREFETCH_EXPERTS "$SRV" $SRV_COMMON > $OUT.srv_base.log 2>&1 &
BP=$!; wait_health && curl -s -m 120 -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d "$PROMPT" > $OUT.raw_base.json 2>&1
kill $BP 2>/dev/null; wait $BP 2>/dev/null; free_port
echo "=== correctness candidate (prefetch ON) ===" | tee -a $OUT.runlog
GGML_SCHED_PREFETCH_EXPERTS=1 "$SRV" $SRV_COMMON > $OUT.srv_cand.log 2>&1 &
CP=$!; wait_health && curl -s -m 120 -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d "$PROMPT" > $OUT.raw_cand.json 2>&1
kill $CP 2>/dev/null; wait $CP 2>/dev/null; free_port

for l in base cand; do python -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])' < $OUT.raw_$l.json > $OUT.gen_$l.txt 2>&1; done
echo "=== TEXT DIFF (empty = token-identical) ===" | tee -a $OUT.runlog
diff $OUT.gen_base.txt $OUT.gen_cand.txt | tee -a $OUT.runlog
echo "ALL DONE $(date)" | tee -a $OUT.runlog
