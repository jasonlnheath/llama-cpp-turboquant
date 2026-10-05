# Xid 8 debug session state - CLOSED 2026-10-05 ~07:30Z (PR shipped, merge awaits captain)

## FINAL DELIVERY: https://github.com/jasonlnheath/llama-cpp-turboquant/pull/2
Pipeline run 01M444PEW9QFMAC8SQPRK6YMFR completed (outcome: passed-with-override) at head fd7a48806:
all 9 steps green (review/test/document/lint/push/pr/ci). CI: every hosted leg GREEN except two
DOCUMENTED PRE-EXISTING platform defects (both proven on base a5eef8209): (1) macos webgpu
Dawn unaligned-OFFSET set_tensor defect (no narrow fix; needs byte-copy machinery; captain-
deferred follow-up); (2) macos-latest-x64 ACCEL+CPU topology defect (reproduced on base; pure-CPU
suite passes; dedicated fork follow-up). 19 donated-runner legs + Lint + build-cmake-pkg disabled
repo-side per captain rulings 013/018. Fixes the pipeline landed beyond the original branch:
slot-restore SIGSEGV (task null-deref, verified repro+fix), sycl build breaks (dead orphan + 12
undeclared-identifier sites), hip nodiscard (19+11 casts) + gfx908 VGPR allowlist (37 kernels),
wasm OpenMP flag (upstream precedent), moe-trace -Wcomment, fit.cpp 14 format sites, plus the
async-CPU drain, worker session propagation, and repro-kit hardening from earlier rounds.

## Captain rulings incorporated
- 013: Profile 1 RETAINED FOR POWER ("13% power savings you are ignoring"): the 885mV UV is the
  point; speed-neutral vs stock, stability-equal at sane clocks. Perf verdict stands as measured.
- 018: platform legs triaged fix-vs-skip as executed above; merge = captain's word.


## FINAL RESULTS TABLE (zero Xid / zero NVRM across the entire ~5.2 GPU-hour campaign)
| leg | build | clocks | load | duration | result |
|-----|-------|--------|------|----------|--------|
| smoke | fixed | P1 | sanity + stream | 5 min | GREEN (84-87 t/s) |
| perf P1 | fixed | P1 | house bench | - | pf 1549/1481/948; dec 83.7/75.7/40.0 |
| instrumented | fixed | P1 | v4 + cuda-gdb | 48 min | GREEN (0 stalls) |
| a | crashed | P1 | v4 | 45 min | GREEN |
| c | crashed + PDL=0 | P1 | v4 | 45 min | GREEN |
| SOAK | fixed | P1 | v4 | 120 min | GREEN (deliverable bar met) |
| b | crashed | STOCK | v4 | 45 min | GREEN (mem 13801 verified under load) |
| fixed-stock | fixed | STOCK | v4 | 20 min | GREEN |
| perf stock | fixed | STOCK | same prompts | - | pf 1544/1467/924; dec 84.5/81.2/41.1 |

## PERF VERDICT (captain ask): P1 vs stock, identical prompts, fixed build
prefill +0.3/+1.0/+2.6% for P1; decode -1.0/-6.8/-2.7% (stock faster at depth).
Small, mixed-sign, single-sample -> the mem +1500 OC buys essentially nothing on
this workload; clock choice should be made on stability grounds alone.

## ROOT-CAUSE ATTRIBUTION (final, honest)
1. The six Xid-8s all occurred in the mem +2000 era, which independently crashed
   unrelated GPU apps twice (10-03 GSP death; reboot-2 Xid 109 chain).
2. At Profile 1 (+1500) AND stock, neither crashed nor fixed build produced any
   Xid under sustained multi-client load (45m-2h windows, cuda-gdb armed once).
3. => Primary cause: card-level mem-OC instability at +2000 under sustained
   bandwidth-heavy decode. The PDL-mixing defect cannot be conclusively implicated
   or exonerated by these windows; it may have been an amplifier. The fix removes
   the fork's only structural divergence from proven-upstream decode-graph launch
   discipline, is perf-neutral, and is verified stable (2h+ soak).
4. Recommendation: run stock or Profile 1 clocks; ship the PDL-uniformity fix as
   correctness/hardening; do not attribute the historical crashes to it alone.

## Open item for captain/firstmate at flip-back: which binary restores the :8037
production lane (old crashed build via restore-service.sh, or the fixed worktree
build pending merge). PR: jasonlnheath fork only, merge waits for captain.


## Operational lessons this campaign
- SIGKILL on llama-server (gdb-orphan case) left ~13.4GB driver-side stuck VRAM with no
  owning process; freed only after ~12 min deferred sweep. TERM to the correct pid: 2s
  clean exit, immediate VRAM release. Production unit restarts must avoid SIGKILL.
- pgrep -f 'build-debug/bin/llama-server' matches my own bash -c wrappers: always take
  pids from ss -tlnp / launch records, never from a bare pgrep -f match.
- cuda-gdb children ignore TERM after gdb dies (ptrace state): teardown order must be
  fifo 'kill' to gdb first, then the child.

002.msg (01:16Z) released the card; 003.msg (01:17Z) COUNTERMANDED it: reboot
imminent, driver wedged again under q2rtx/emulator (Xid 109 chain + Hyprland crash).
004.msg (01:18Z): reboot #2 completed 01:15Z; GPU legs stay gated until the
captain verifies Profile 1 (885mV UV + mem +1500) and says go. Non-GPU work may
continue. NO GPU process was ever started by this task between 002 and 003
(verified: only the unrelated CPU-only vision server on :8038 exists).

## ROOT-CAUSE MODEL UPDATE (2026-10-04): memory-OC instability is now a co-primary candidate
- Card was running a tuned profile; mem +2000 CRASHED OTHER APPS tonight (q2rtx/
  emulator Xid 109 chain -> reboot #2; plus the 10-03 PenguinBurner full GSP death).
  Driver-family instability is not exclusive to our CUDA path - and tonight's
  wedges are further memory-clock evidence (logged per 004.msg).
- Six llama Xid-8s all happened in the tuned-profile era (mem +2000). Sustained
  decode is mem-bandwidth-heavy; mem-OC corruption can wedge a channel (Xid 8,
  7s notify timeout) exactly as observed - and would also explain why no fork
  kernel hang construct was found, why wedges predate their sync point, and why
  no single-client repro ever fired.
- The PDL-uniformity divergence (fixed in 4f462ab4e) remains a real structural
  defect but its causal weight is now uncertain: possibly THE bug, possibly an
  amplifier, possibly innocent. Only clock-isolated A/B discriminates.
- Attribution logic for the v2 matrix:
  * crashed build crashes at STOCK clocks -> fork path is crash-capable; fix is
    load-bearing; PR proceeds with strong evidence.
  * crashed build survives Profile 1 AND stock under multi-client repro while
    all six crashes were at mem +2000 -> root cause shifts to memory OC; fix
    reclassifies as hardening/defense-in-depth; PR ships with honest attribution
    and the OC conclusion goes to the captain (already managing profiles).
  * fixed build wedges anywhere (even Profile 1) -> immediate needs-decision
    escalation with instrumented dumps; driver/hardware-level conclusion.

## NEW this session (2026-10-03 evening)

### Evidence lost
- /tmp/qwen38-crash6.core GONE (reboot cleared /tmp); coredumpctl copies of
  10-02 + 10-03 crashes both "missing" (rotated). No core analysis possible.

### Journal mining (boot -1, pre-reboot kernel log preserved)
- 6 llama-server Xid 8s: ALWAYS exactly "krcWatchdog: GPU is probably locked!
  Notify Timeout: 7s" + Xid 8 channel 0x00000003, nothing else. GSP stays
  healthy on those (no heartbeat timeout, no Xid 175) -> CHANNEL-level lock,
  not full GSP death. Driver recovered after process kill each time.
- 2026-10-03 16:23 (PenguinBurner, ~2h after our last crash): FULL GSP death -
  heartbeat timeout, kgmmu TLB invalidation failure, Memory Subsystem Error,
  Xid 175 RPC timeout cascade -> reboot. Different, worse failure class.
  => driver/GSP instability on this box is NOT exclusive to our CUDA path.
- Crash #6 log detail (739.48): previous task ended 739.43.56, eviction
  "making room" 739.43.56, new task prefill running FINE at 1650 t/s for ~3.7s
  (progress logged!), then CUDA launch-timeout surfaced at mmq launch check.
  => other channels kept working while one channel was wedged; wedge predated
  the surfacing sync. Same pattern for crash #5 (13ms after task start).

### Static code audit (all fork-added CUDA code vs upstream 8f5ab832c)
- Every fork kernel audited for hang constructs (unbounded loops, divergent
  __syncthreads, mismatched shuffle masks, spin/atomic loops, cooperative
  launches): NONE FOUND. All loops bounded; all barriers uniform; index math
  in-bounds for the production geometry (turbo4-K/turbo3-V, head_dim 256,
  GQA 6:1, QK_TURBO4=128 / QK_TURBO3=32 blocks).
- Active fork kernels in this server's decode: k_set_rows_turbo4 (K write),
  k_set_rows_turbo3 (V write), k_turbo_wht fwd (Q) + inv (out), per layer.
  Verify batches (3 tok) -> TILE kernel; prefill -> MMA_F16; both convert
  turbo->f16 via fork dequantize kernels (bounded, audited). MoE decode =
  upstream MMVQ (+ fork zero_skipped_rows guard kernel, dead -1 path).
- moe-pack paths (mmid -1 ids, quantize -1 guards) are DEAD CODE for this
  server (no GGML_MOE_CACHE_PROFILE); guards are block-uniform anyway.

### ROOT-CAUSE-CANDIDATE FOUND (structural, fork-specific, fixed)
PDL uniformity divergence, verified in the CRASHED binary's SASS
(~/Work/llama-cpp-moecache/build objects, cuobjdump; sm_120a encodes
griddepcontrol.wait as ACQBULK, .launch_dependents as PREEXIT):
  rope.cu.o   ACQBULK=28   mmvq.cu.o  ACQBULK=276   fattn.cu.o ACQBULK=38
  set-rows.cu ACQBULK=20 (upstream f16/f32 k_set_rows only)
  turbo-wht.cu ACQBULK=0   mmid.cu.o  ACQBULK=0     <-- fork kernels RAW
On sm_120 (CUDA 13.3, PTX>=90) GGML_CUDA_PDL defaults ON: every upstream
hot decode kernel launches via ggml_cuda_kernel_launch with the
programmatic-stream-serialization attribute (recorded into the captured CUDA
decode graph, replayed ~76K times/task-set). The fork's turbo kernels were
the ONLY raw-launched nodes in that stream, and contained no PDL intrinsics:
each sat between PDL-attributed nodes inside the captured graph. Mixing is
CUDA-legal (upstream itself mixes raw MMQ in prefill streams), but this exact
pattern - raw nodes only in the decode path, only in this fork+config - is
the one structural divergence from every stable upstream sm_120 deployment,
on a driver (610.57.04) with independently demonstrated GSP/channel bugs.
Mechanism (hypothesis): driver graph-node PDL-edge handling around the
non-participating nodes wedges a compute channel under sustained replay;
watchdog fires at 7s; next sync aborts. Fits: mid-decode + task-boundary
crashes, wedge predating surface, no app-visible corruption, no repro
(1h35m load incl. cuda-gdb run - timing-dependent driver path).

### FIX (committed on fm/llama-moecache-xid8-fix)
1. set-rows.cu / turbo-wht.cu / mmid.cu: turbo + zero_skipped kernels
   converted to the canonical upstream PDL pattern:
   - plain kernel params + local GGML_CUDA_RESTRICT aliases (arch-dependent
     qualifiers on params break cudafe stub generation - learned the hard way)
   - ggml_cuda_pdl_sync() before first global read, ggml_cuda_pdl_lc() after
     (mirrors upstream k_set_rows exactly)
   - launched via ggml_cuda_kernel_launch (PDL attr applied when PTX>=90;
     GGML_CUDA_PDL=0 still falls back to raw - A/B lever preserved)
   Verified in rebuilt build-debug SASS: turbo kernels now emit ACQBULK +
   PREEXIT (set-rows 34, turbo-wht 7, mmid 1).
2. fattn.cu: ggml_cuda_turbo_mma_fused() was default-ON despite the commit
   title "(opt-in)" and two comments saying VEC-default/opt-in (landed
   inverted in b3e51cf3d, kept in #4). Now truly opt-in
   (GGML_TURBO_MMA_FUSED=1). Inert for this server (mixed turbo4/turbo3
   never matched the K==V gate) but removes a silently-active untested path
   for matched-type configs; set =1 to restore MMA on other lanes if wanted.
CPU-side validation: turbo roundtrip test passes (cosine 0.986-1.0);
build-debug full tree builds + links clean (RelWithDebInfo).

### Unchanged prior evidence (still valid)
- Six Xid-8 crashes 09-26..10-03, all channel 0x3, 7s notify timeout.
- No repro in ~1h20m plain + 15m cuda-gdb-instrumented v3 load (90K prefills,
  33 t/s decode, cache-reuse, aborts). Production-only trigger gap: real fleet
  traffic is multi-client interleaved (/v1/chat/completions, tools, JSON
  schema, streaming aborts, /slots + /metrics polling) - repro drivers were
  single-client /completion. Next repro round should interleave 2-3 clients.
- Driver 610.57.04, RTX sm_120 (16G), CUDA 13.3, open kernel module.

## Validation plan v2 (SUPERSEDES v1 below; resume only on captain's post-Profile-1 go)
Clock-state protocol: Profile 1 and stock legs are captain/firstmate actions; I
never change clocks myself. Before every leg I passively record clocks
(nvidia-smi -q -d CLOCK + application clocks) into the leg's log so attribution
is airtight. All legs: multi-client v4 driver, xid-watch armed, ~/logs/ evidence.
1. Smoke (5 min): fixed build (worktree build-debug) @ Profile 1. Sanity gen + speed.
2. Instrumented repro attempt (45 min): fixed build under cuda-gdb fifo
   (run-instrumented.sh now honors BIN env for the fixed binary), v4 driver,
   stall-detector armed. Wedge -> 'info cuda kernels' names the kernel.
3. A/B isolation matrix (45 min each, most diagnostic first):
   a. crashed build @ Profile 1 (crash arm under the new profile)
   b. crashed build @ STOCK clocks (clean fork-vs-OC isolation leg)
   c. crashed build @ Profile 1 + GGML_CUDA_PDL=0 (PDL-hypothesis leg)
   d. conditional: q8-kv / no-spec arms only if a/b crash
4. Soak (the deliverable bar): fixed build @ Profile 1, v4 DUR>=7200, zero
   Xid/abort, logs saved as PR evidence.
5. Cheap strengthener if time allows: fixed build @ stock, 30 min (expect pass).
Then: no-mistakes pipeline, PR to jasonlnheath fork, merge waits for captain.

## Validation plan v1 (2026-10-03, pre-OC-evidence - kept for history)
1. Smoke: start build-debug server (worktree binary), 5-min sanity gen.
2. Repro attempt on FIXED build with multi-client interleaved driver
   (repro/load-driver-v4.sh: deep-decodes + abort churn + schema tasks +
   /slots //metrics poller, 3 concurrent workers), cuda-gdb fifo
   stall-detector armed (repro/run-instrumented.sh).
   If wedge caught: 'info cuda kernels' names the kernel -> real root cause.
3. A/B chain (repro/ab-chain.sh, 45 min each; ab-run.sh now honors AB_BIN):
   - fixed-build default config (expect: no crash; this is the fix arm)
   - AB_BIN=<crashed build> default config (old behavior, crash arm if lucky)
   - AB_BIN=<crashed build> AB_ENV="GGML_CUDA_PDL=0" (PDL-off on old binary)
   - q8-kv / no-spec arms on crashed build (isolate turbo KV / draft-mtp)
4. Post-fix soak: >= 2h sustained generation on fixed build, zero Xid/abort,
   xid-watch armed; save log as evidence.
5. Escalate to needs-decision ONLY if fixed build still wedges: then it is
   driver-level (evidence: this audit + A/B results) -> captain decides
   driver downgrade vs mitigation (cache-type fallback / no draft-mtp).

## Environment notes (unchanged)
- No sudo NOPASSWD systemctl here; user-level systemd-run or setsid launchers.
- ptrace_scope=1; cuda-gdb only as parent (fifo approach in repro/).
- system unit llama-qwen38 INACTIVE (firstmate paused). Restore via
  repro/restore-service.sh (setsid, port 8037) or captain restarts unit.
