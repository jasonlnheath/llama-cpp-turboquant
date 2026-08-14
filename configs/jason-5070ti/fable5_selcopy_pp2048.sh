#!/usr/bin/env bash
# selective-copy (prod path) at pp2048/ub2048 — to compare against F1+F2 prefetch (2612 ncmoe36 / 3088 ncmoe26).
# selective-copy is RE-ENABLED here; prefetch OFF. Decides whether prefetch beats prod at large batch.
set +e
BIN=/c/dev/llama-cpp-turboquant/build/bin/Release/llama-bench.exe
MODEL=/d/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf
OUT=/tmp/fable5_selcopy
B26="-m $MODEL -ngl 999 -ncmoe 26 -t 8 -fa 1 -b 2048 -ub 2048 -ctk turbo4 -ctv turbo3 -p 2048 -n 0 -r 5"
B36="-m $MODEL -ngl 999 -ncmoe 36 -t 8 -fa 1 -b 2048 -ub 2048 -ctk turbo4 -ctv turbo3 -p 2048 -n 0 -r 5"
echo "START $(date)" > $OUT.runlog

echo "=== ncmoe36 --no-mmap selective-copy (PROD path) ===" | tee -a $OUT.runlog
env -u GGML_SCHED_PREFETCH_EXPERTS "$BIN" $B36 -mmp 0 > $OUT.S36nommap.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog
echo "=== ncmoe36 mmap selective-copy ===" | tee -a $OUT.runlog
env -u GGML_SCHED_PREFETCH_EXPERTS "$BIN" $B36 -mmp 1 > $OUT.S36mmap.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog
echo "=== ncmoe26 --no-mmap selective-copy ===" | tee -a $OUT.runlog
env -u GGML_SCHED_PREFETCH_EXPERTS "$BIN" $B26 -mmp 0 > $OUT.S26nommap.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog
echo "=== ncmoe26 mmap selective-copy ===" | tee -a $OUT.runlog
env -u GGML_SCHED_PREFETCH_EXPERTS "$BIN" $B26 -mmp 1 > $OUT.S26mmap.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog

echo "ALL DONE $(date)" | tee -a $OUT.runlog
