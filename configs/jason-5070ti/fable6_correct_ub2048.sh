#!/usr/bin/env bash
# Correctness gate for prod adoption: at -ub 2048 (same ubatch), prefetch OFF vs ON.
# Long prompt (~800 tok) guarantees prefetch fires in run B. temp 0, seed 42 = deterministic.
# Empty diff => prefetch is value-preserving at ub2048. (MTP excluded — it's decode-side,
# orthogonal to prefill prefetch; verified separately if needed.)
set +e
SRV=/c/dev/llama-cpp-turboquant/build/bin/Release/llama-server.exe
MODEL=/d/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf
PORT=8046
OUT=/tmp/fable6_correct
FLAGS="-m $MODEL --host 127.0.0.1 --port $PORT -ngl 999 --n-cpu-moe 36 -np 1 -c 8192 -t 8 -fa on --no-mmap -b 2048 -ub 2048 -ctk turbo4 -ctv turbo3 --no-warmup --jinja"
MSG=$(cat <<'EOF'
Read the following passage and then answer the question after it in three concise bullet points. Passage: The transition from vacuum tubes to transistors in the late 1940s and early 1950s is often cited as one of the most consequential shifts in the history of computing. Vacuum tubes, which powered the first generation of electronic computers, were bulky, fragile, and generated enormous amounts of heat, which meant that machines built from them filled entire rooms, consumed vast quantities of electricity, and required constant maintenance. The transistor, developed at Bell Laboratories, performed the same essential function, switching and amplifying electrical signals, but did so with a tiny solid-state device that was far smaller, far more reliable, and dramatically more efficient. This single change unlocked a generation of machines that were faster, cheaper, and small enough to be owned by a single department rather than a national government. The subsequent invention of the integrated circuit, which placed many transistors on a single piece of silicon, compounded these gains, and the steady miniaturization that followed became known informally as Moores law, describing the doubling of transistor counts roughly every two years. As counts rose and costs fell, computers moved from military and scientific niches into businesses, then into homes, and eventually into pockets, reshaping communication, commerce, entertainment, and science in ways the original pioneers could scarcely have imagined. Alongside hardware, software evolved in parallel: at first programmers wired physical panels or punched cards, but higher level languages, compilers, and operating systems progressively insulated programmers from machine detail and made it possible to write large, complex systems reliably. Networking tied machines together, first within organizations and then globally, giving rise to distributed systems, the internet, and eventually cloud computing, in which computation and storage are rented on demand across vast datacenters. More recently, the rise of graphics processing units and other accelerators, originally designed for rendering graphics, has driven a revolution in machine learning, because the same parallel arithmetic that draws pixels turns out to be ideally suited to training large neural networks. Question: In three bullet points, what were the most important consequences of replacing vacuum tubes with transistors?
EOF
)
PROMPT=$(python -c 'import sys,json; m=sys.stdin.read(); print(json.dumps({"messages":[{"role":"user","content":m}],"temperature":0,"seed":42,"max_tokens":200,"stream":False,"chat_template_kwargs":{"enable_thinking":False}}))' <<<"$MSG")
wait_health() { for i in $(seq 1 150); do curl -sf -m 2 http://127.0.0.1:$PORT/health >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
free_port()   { for i in $(seq 1 40); do netstat -ano 2>/dev/null | grep -q ":$PORT.*LISTEN" || return 0; sleep 1; done; }
echo "START $(date)" > $OUT.runlog

echo "=== A: ub2048 prefetch OFF ===" | tee -a $OUT.runlog
env -u GGML_SCHED_PREFETCH_EXPERTS "$SRV" $FLAGS > $OUT.srv_A.log 2>&1 &
A=$!; wait_health && curl -sf -m 120 -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d "$PROMPT" > $OUT.raw_A.json 2>&1
kill $A 2>/dev/null; wait $A 2>/dev/null; free_port
echo "=== B: ub2048 prefetch ON ===" | tee -a $OUT.runlog
GGML_SCHED_PREFETCH_EXPERTS=1 "$SRV" $FLAGS > $OUT.srv_B.log 2>&1 &
B=$!; wait_health && curl -sf -m 120 -X POST http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d "$PROMPT" > $OUT.raw_B.json 2>&1
kill $B 2>/dev/null; wait $B 2>/dev/null; free_port

for l in A B; do python -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])' < $OUT.raw_$l.json > $OUT.gen_$l.txt 2>&1; done
echo "=== A output ===" | tee -a $OUT.runlog; head -c 400 $OUT.gen_A.txt | tee -a $OUT.runlog; echo | tee -a $OUT.runlog
echo "=== B output ===" | tee -a $OUT.runlog; head -c 400 $OUT.gen_B.txt | tee -a $OUT.runlog; echo | tee -a $OUT.runlog
echo "=== DIFF (empty = prefetch value-preserving at ub2048) ===" | tee -a $OUT.runlog
diff $OUT.gen_A.txt $OUT.gen_B.txt | tee -a $OUT.runlog
echo "ALL DONE $(date)" | tee -a $OUT.runlog
