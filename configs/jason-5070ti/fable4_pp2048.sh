#!/usr/bin/env bash
# Replicate the author's measurement: pp2048/ub2048 (NOT pp512/ub512), selective-copy DISABLED,
# so baseline = naive (mainline-like). Author: RTX 3060, ncmoe 26 → naive 1143, prefetch 1880.
# Question: what does the 5070 Ti do at this batch size? (expect higher than 3060)
set +e
BIN=/c/dev/llama-cpp-turboquant/build/bin/Release/llama-bench.exe
MODEL=/d/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf
OUT=/tmp/fable4_pp2048
# -n 0 = prefill only (author's metric). -ub 2048 = author's ubatch. -b 2048.
BASE26="-m $MODEL -ngl 999 -ncmoe 26 -t 8 -fa 1 -b 2048 -ub 2048 -ctk turbo4 -ctv turbo3 -p 2048 -n 0 -r 5"
BASE36="-m $MODEL -ngl 999 -ncmoe 36 -t 8 -fa 1 -b 2048 -ub 2048 -ctk turbo4 -ctv turbo3 -p 2048 -n 0 -r 5"
echo "START $(date)" > $OUT.runlog

echo "=== ncmoe26 mmap naive (author baseline ~1143) ===" | tee -a $OUT.runlog
env -u GGML_CUDA_REGISTER_HOST -u GGML_SCHED_PREFETCH_EXPERTS "$BIN" $BASE26 -mmp 1 > $OUT.A26.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog
echo "=== ncmoe26 mmap F2 prefetch (author ~1880) ===" | tee -a $OUT.runlog
env -u GGML_CUDA_REGISTER_HOST GGML_SCHED_PREFETCH_EXPERTS=1 "$BIN" $BASE26 -mmp 1 > $OUT.B26.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog
echo "=== ncmoe26 mmap F1+F2 (pin+prefetch) ===" | tee -a $OUT.runlog
env GGML_CUDA_REGISTER_HOST=1 GGML_SCHED_PREFETCH_EXPERTS=1 "$BIN" $BASE26 -mmp 1 > $OUT.C26.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog
echo "=== ncmoe36 mmap naive ===" | tee -a $OUT.runlog
env -u GGML_CUDA_REGISTER_HOST -u GGML_SCHED_PREFETCH_EXPERTS "$BIN" $BASE36 -mmp 1 > $OUT.A36.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog
echo "=== ncmoe36 mmap F1+F2 (pin+prefetch) ===" | tee -a $OUT.runlog
env GGML_CUDA_REGISTER_HOST=1 GGML_SCHED_PREFETCH_EXPERTS=1 "$BIN" $BASE36 -mmp 1 > $OUT.C36.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog

echo "ALL DONE $(date)" | tee -a $OUT.runlog
