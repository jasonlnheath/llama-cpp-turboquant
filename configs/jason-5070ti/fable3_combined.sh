#!/usr/bin/env bash
# Combined F1+F2 test under MMAP mode. Does pin (F1) + prefetch (F2) together beat prod
# (--no-mmap + selective-copy = 953 pp t/s reference)? All configs use -mmp 1 (mmap on).
# F1 = GGML_CUDA_REGISTER_HOST (pin mmap'd weights); F2 = GGML_SCHED_PREFETCH_EXPERTS.
set +e
BIN=/c/dev/llama-cpp-turboquant/build/bin/Release/llama-bench.exe
MODEL=/d/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf
COMMON="-m $MODEL -ngl 999 -ncmoe 36 -t 8 -fa 1 -b 2048 -ub 512 -ctk turbo4 -ctv turbo3 -p 512 -n 128 -r 10 -mmp 1"
OUT=/tmp/fable3_combined
echo "START $(date)" > $OUT.runlog

echo "=== D: mmap + pin + prefetch (F1+F2) ===" | tee -a $OUT.runlog
env GGML_CUDA_REGISTER_HOST=1 GGML_SCHED_PREFETCH_EXPERTS=1 "$BIN" $COMMON > $OUT.D.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog

echo "=== E: mmap + pin + selective-copy (F1 only) ===" | tee -a $OUT.runlog
env GGML_CUDA_REGISTER_HOST=1 -u GGML_SCHED_PREFETCH_EXPERTS "$BIN" $COMMON > $OUT.E.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog

echo "=== F: mmap + prefetch, no pin (F2 only) ===" | tee -a $OUT.runlog
env -u GGML_CUDA_REGISTER_HOST GGML_SCHED_PREFETCH_EXPERTS=1 "$BIN" $COMMON > $OUT.F.txt 2>&1; echo "exit=$?" | tee -a $OUT.runlog

echo "ALL DONE $(date)" | tee -a $OUT.runlog
