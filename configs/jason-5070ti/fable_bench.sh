#!/usr/bin/env bash
# Fable MoE optimization A/B/C benchmark — RTX 5070 Ti, Qwen3.6-35B-A3B
# A = prod-like (--no-mmap, no pin)   B = mmap + GGML_CUDA_REGISTER_HOST=1   C = mmap, no pin
# NOTE: GGML_CUDA_REGISTER_HOST enables on ANY value (getenv != nullptr), so it must be
# UNSET (not set to 0) for the no-pin configs.
set +e
BIN=/c/dev/llama-cpp-turboquant/build/bin/Release/llama-bench.exe
MODEL=/d/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf
COMMON="-m $MODEL -ngl 999 -ncmoe 28 -t 8 -fa 1 -b 2048 -ub 512 -ctk turbo4 -ctv turbo3 -p 512 -n 128 -r 10"
OUT=/tmp/fable_bench
echo "START $(date)" > $OUT.runlog

echo "=== B: mmap + pin (validates the Windows port fires) ===" | tee -a $OUT.runlog
GGML_CUDA_REGISTER_HOST=1 "$BIN" $COMMON -mmp 1 > $OUT.B.txt 2>&1; echo "B exit=$?" | tee -a $OUT.runlog

echo "=== A: prod-like, mmap OFF, no pin ===" | tee -a $OUT.runlog
env -u GGML_CUDA_REGISTER_HOST "$BIN" $COMMON -mmp 0 > $OUT.A.txt 2>&1; echo "A exit=$?" | tee -a $OUT.runlog

echo "=== C: mmap ON, no pin ===" | tee -a $OUT.runlog
env -u GGML_CUDA_REGISTER_HOST "$BIN" $COMMON -mmp 1 > $OUT.C.txt 2>&1; echo "C exit=$?" | tee -a $OUT.runlog

echo "ALL DONE $(date)" | tee -a $OUT.runlog
