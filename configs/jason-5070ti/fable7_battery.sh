#!/usr/bin/env bash
# A/B prompt battery: send prompts of increasing size to 8036, record prefill rate.
# Unique prompts (size-tagged) so --cache-reuse doesn't mask real prefill. temp 0.
# Usage: fable7_battery.sh <label>
set +e
LABEL="${1:-cfg}"
BASE="Computing hardware evolved through generations defined by switching technology: vacuum tubes gave way to transistors, then integrated circuits, then microprocessors, each step smaller cheaper faster and more reliable than the last, while software and networking evolved in parallel to produce the modern interconnected accelerated world. "
for size in 150 500 1200 2500; do
  MSG=$(python -c "import sys; p=sys.stdin.read(); n=max(1,$size//40); print(f'(size$size test) Summarize in one sentence. '+p*n)" <<<"$BASE")
  PROMPT=$(python -c 'import sys,json; m=sys.stdin.read(); print(json.dumps({"messages":[{"role":"user","content":m}],"temperature":0,"seed":42,"max_tokens":30,"stream":False,"chat_template_kwargs":{"enable_thinking":False}}))' <<<"$MSG")
  RESP=$(curl -sf -m 120 -X POST http://127.0.0.1:8036/v1/chat/completions -H 'Content-Type: application/json' -d "$PROMPT")
  echo "$RESP" | python -c "
import sys,json
d=json.load(sys.stdin); t=d.get('timings',{})
print('$LABEL','size=$size','prompt_n='+str(t.get('prompt_n')),'pp_t/s=%.1f'%t.get('prompt_per_second',0),'tg_t/s=%.1f'%t.get('predicted_per_second',0))
" 2>&1 || echo "$LABEL size=$size  ERROR"
done
echo "$LABEL DONE"
