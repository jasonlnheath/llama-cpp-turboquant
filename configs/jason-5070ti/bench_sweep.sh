#!/bin/bash
# MTP + TurboQuant benchmark sweep for RTX 5070 Ti
# Tests different --n-cpu-moe values to find optimal speed

LLAMA="/c/dev/llama-cpp-turboquant/build/bin/Release/llama-server.exe"
MODEL="D:/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf"
MMPROJ="D:/models/mmproj-BF16.gguf"
PORT=8099
RESULTS="/tmp/mtp_sweep_results.csv"

echo "n-cpu-moe,vram_mb,prompt_toks,comp_toks,tok_per_s,drafted,accepted,accept_rate" > $RESULTS
echo "Starting sweep..."
echo ""

# Kill any lingering servers
pkill -f "llama-server" 2>/dev/null
sleep 2

for MOE in 0 5 10 15 20 25 30 35; do
    echo "--- n-cpu-moe=$MOE ---"

    "$LLAMA" \
        -m "$MODEL" \
        --mmproj "$MMPROJ" \
        --host 127.0.0.1 \
        --port $PORT \
        -ngl 999 \
        --n-cpu-moe $MOE \
        -np 1 \
        -c 32768 \
        -t 8 \
        -fa on \
        --no-mmap \
        --mlock \
        -b 2048 \
        -ub 512 \
        -ctk turbo3 \
        -ctv turbo4 \
        --spec-type draft-mtp \
        --spec-draft-n-max 5 \
        --spec-draft-ngl 999 \
        --no-warmup \
        --fit off \
        --reasoning-budget -1 \
        --metrics \
        --slots > /tmp/mtp_sweep_${MOE}.log 2>&1 &
    PID=$!

    # Wait for server
    OK=0
    for i in $(seq 1 40); do
        if curl -s http://127.0.0.1:$PORT/health > /dev/null 2>&1; then
            OK=1; break
        fi
        sleep 2
    done

    if [ $OK -eq 0 ]; then
        echo "  FAILED to start"
        echo "$MOE,0,FAIL,0,0,0,0,0" >> $RESULTS
        kill $PID 2>/dev/null; wait $PID 2>/dev/null
        sleep 2
        continue
    fi

    sleep 3

    VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' ')

    # Run benchmark and save raw response to file
    curl -s -X POST http://127.0.0.1:$PORT/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{"messages":[{"role":"user","content":"Write a short poem about the sea."}],"max_tokens":200,"temperature":0.0}' \
        > /tmp/mtp_resp_${MOE}.json 2>/dev/null

    # Parse results from file
    python3 -c "
import json
with open('/tmp/mtp_resp_${MOE}.json') as f:
    d = json.load(f)
if 'error' in d:
    print('${MOE},${VRAM},ERR,0,0,0,0,0')
else:
    u = d.get('usage', {})
    t = d.get('timings', {})
    tps = t.get('predicted_per_second', 0)
    dn = t.get('draft_n', 0)
    da = t.get('draft_n_accepted', 0)
    rate = da/max(dn,1)*100
    line = '${MOE},${VRAM},' + str(u.get('prompt_tokens',0)) + ',' + str(u.get('completion_tokens',0)) + ',' + str(round(tps,1)) + ',' + str(dn) + ',' + str(da) + ',' + str(round(rate,1))
    print(line)
" >> $RESULTS 2>/dev/null

    # Print this result
    tail -1 $RESULTS

    kill $PID 2>/dev/null
    wait $PID 2>/dev/null
    sleep 3
done

echo ""
echo "============================================"
echo " RESULTS"
echo "============================================"
cat $RESULTS
echo ""
echo "Best speed:"
tail -n +2 $RESULTS | sort -t, -k5 -rn | head -3
