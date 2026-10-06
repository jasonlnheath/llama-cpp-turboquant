#!/usr/bin/env bash
# Append a clock-state snapshot to a log (leg attribution evidence, plan v2).
# Usage: clock-snap.sh <logfile> [label]
set -u
LOG="$1"; LABEL="${2:-snap}"
{
  echo "=== clock-snap $LABEL $(date -Is) ==="
  nvidia-smi -q -d CLOCK 2>&1
  nvidia-smi --query-gpu=clocks.max.mem,clocks.max.sm,power.limit,clocks.mem,clocks.sm --format=csv 2>&1
} >> "$LOG"
