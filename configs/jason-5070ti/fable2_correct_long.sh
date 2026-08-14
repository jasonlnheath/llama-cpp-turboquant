#!/usr/bin/env bash
# Long-prompt token-identical check: a ~600-token prefill forces GGML_SCHED_PREFETCH_EXPERTS to
# fire (ids >= 2*n_expert). If prefetch corrupts the large-batch path, the generated output
# diverges from baseline. temp 0, seed 42 -> deterministic.
set +e
SRV=/c/dev/llama-cpp-turboquant/build/bin/Release/llama-server.exe
MODEL=/d/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf
PORT=8046
OUT=/tmp/fable2_correct_long
SRV_COMMON="-m $MODEL --host 127.0.0.1 --port $PORT -ngl 999 --n-cpu-moe 36 -t 8 -fa on --no-mmap -ctk turbo4 -ctv turbo3 --no-warmup --jinja"
# ~600-token prompt (long passage) so prefill triggers the prefetch path
read -r -d '' MSG <<'EOF'
Summarize the following passage in exactly three bullet points, then state the single most important takeaway in one sentence. Passage: The history of computing hardware is often described in terms of generations, each marked by a dominant technology. The first generation used vacuum tubes, which were large, hot, and unreliable; machines filled entire rooms and were programmed with physical switches and punched cards. The second generation replaced tubes with transistors, dramatically reducing size and power consumption while improving reliability. The third generation introduced integrated circuits, packing many transistors onto a single chip and enabling minicomputers. The fourth generation, beginning in the 1970s, was defined by the microprocessor, a single chip containing a complete central processing unit, which made personal computers possible and transformed business, science, and daily life. The fifth generation, a term popularized by a Japanese research program in the 1980s, was envisioned around artificial intelligence and parallel processing, though the framing has since shifted toward the rise of graphics processing units, accelerators, and specialized hardware for machine learning. Across all generations, a consistent theme is the pursuit of greater performance per unit of cost, energy, and space, driven by improvements in manufacturing, architecture, and software. The development of compilers, operating systems, and high level languages was as important as the hardware itself, because it allowed programmers to express complex algorithms without managing every hardware detail. Networking, beginning with time sharing systems and expanding into the internet, connected machines and ultimately enabled distributed computing and cloud services. More recently, the boundaries between generations have blurred, and progress is often described in terms of scaling laws, specialized accelerators, and the integration of computation with massive data sets. Understanding these shifts matters because each generation redefined what problems were tractable, who could access computing, and how organizations structured their work.
EOF
PROMPT=$(python -c 'import json,sys; print(json.dumps({"messages":[{"role":"user","content":sys.stdin.read()}],"temperature":0,"seed":42,"max_tokens":120,"stream":false,"chat_template_kwargs":{"enable_thinking":false}}))' <<<"$MSG")
wait_health() { for i in $(seq 1 150); do curl -sf -m 2 http://127.0.0.1:$PORT/health >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
free_port()   { for i in $(seq 1 40); do netstat -ano 2>/dev/null | grep -q ":$PORT.*LISTEN" || return 0; sleep 1; done; }
echo "START $(date)" > $OUT.runlog

run_gen() {
  label=$1; shift
  "$SRV" $SRV_COMMON "$@" > $OUT.srv_$label.log 2>&1 &
  P=$!; wait_health && curl -s -m 120 -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d "$PROMPT" > $OUT.raw_$label.json 2>&1
  kill $P 2>/dev/null; wait $P 2>/dev/null; free_port
}
echo "=== baseline (prefetch OFF) ===" | tee -a $OUT.runlog
env -u GGML_SCHED_PREFETCH_EXPERTS "$SRV" $SRV_COMMON > $OUT.srv_base.log 2>&1 &
BP=$!; wait_health && curl -s -m 120 -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d "$PROMPT" > $OUT.raw_base.json 2>&1
kill $BP 2>/dev/null; wait $BP 2>/dev/null; free_port
echo "=== candidate (prefetch ON) ===" | tee -a $OUT.runlog
GGML_SCHED_PREFETCH_EXPERTS=1 "$SRV" $SRV_COMMON > $OUT.srv_cand.log 2>&1 &
CP=$!; wait_health && curl -s -m 120 -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d "$PROMPT" > $OUT.raw_cand.json 2>&1
kill $CP 2>/dev/null; wait $CP 2>/dev/null; free_port

for l in base cand; do python -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])' < $OUT.raw_$l.json > $OUT.gen_$l.txt 2>&1; done
echo "=== LONG-PROMPT TEXT DIFF (empty = token-identical under large-batch prefill) ===" | tee -a $OUT.runlog
diff $OUT.gen_base.txt $OUT.gen_cand.txt | tee -a $OUT.runlog
echo "ALL DONE $(date)" | tee -a $OUT.runlog
