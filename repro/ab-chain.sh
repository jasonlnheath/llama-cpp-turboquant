#!/usr/bin/env bash
# Chain A/B experiments overnight-style: each variant runs N minutes under the
# v3 deep-context driver; results appended to ~/logs/ab-summary.log.
set -u
cd "$(dirname "$0")"
MINS="${1:-45}"

echo "=== AB chain start $(date -Is), ${MINS}min each ===" >> ~/logs/ab-summary.log

# B: PDL off (upstream PDL machinery is the prime non-fork suspect)
AB_ENV="GGML_CUDA_PDL=0" ./ab-run.sh pdl-off "$MINS"
rc=$?; echo "pdl-off rc=$rc" >> ~/logs/ab-summary.log
[ $rc -eq 2 ] && exit 0   # crashed -> stop chain, evidence in summary

# C: no turbo KV (q8_0 both) - isolates turbo KV kernels
./ab-run.sh q8-kv "$MINS" -ctk q8_0 -ctv q8_0
rc=$?; echo "q8-kv rc=$rc" >> ~/logs/ab-summary.log
[ $rc -eq 2 ] && exit 0

# D: no speculative draft - isolates draft-mtp interplay
./ab-run.sh no-spec "$MINS" NOSPEC
rc=$?; echo "no-spec rc=$rc" >> ~/logs/ab-summary.log

echo "=== AB chain done $(date -Is) ===" >> ~/logs/ab-summary.log
