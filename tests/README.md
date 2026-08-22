# tests/ — libpdx-audit test suite (M4)

**Milestone lineage.** M4 in `design/tooling/r49-r50-plan.md` §5.13
(paideia-os) rubric line: `tests + smoke`. Two open issues under this
milestone in the `paideia-os/libpdx-audit` repo:

- **#8 — M4-001** broker-unavailable refusal test (tool exits 3, no
  output emitted).
- **#9 — M4-002** audit-journal replay correctness against known trace.

Both landed at M4.

## Files

- `test_broker_refusal.pdx` — M4-001 driver. Exports
  `TestBrokerRefusal::run() -> u64`. Verifies the M2-002 sticky-flag
  guard end-to-end at the API surface via .bss fault-injection.
  Returns 0 on pass or a 1..7 subtest ordinal on failure. Pure leaf
  (effects `!{mem} @{}` — no syscall).
- `test_replay_golden.pdx` — M4-002 driver. Exports
  `TestReplayGolden::run() -> u64`. Verifies the wire-format
  invariants that a supervisor replaying the audit journal depends
  on — state-machine reset, FNV-1a-64 empty-stream self-check,
  hash active-flag gates, len=0 no-op, parent-linkage propagation
  into the .bss slot marshal reads. Returns 0 on pass or a 1..8
  subtest ordinal on failure. Pure leaf (effects `!{mem} @{}`).
- `goldens/trace_001.md` — the M4-002 wire-bytes fixture (64-byte
  payload + header layout, per INVOKE / OUTPUT / EXIT lifecycle
  send). Documents the byte-for-byte contract the QEMU harness
  compares `AuditRecord::audit_payload_scratch` against once a
  runnable consumer tool hosts the driver.

## Return-code convention

Every M4 test driver in this tree returns a `u64` where:

- `0` — all subtests passed.
- `N > 0` — the ordinal of the first failing subtest. Ordinals are
  stable across driver runs so a smoke log can pinpoint which
  invariant broke.

A test harness (in a future consumer tool) walks the driver list,
sums the non-zero returns per driver, and exits `0` iff every driver
returned `0`.

## Why the drivers do not invoke `sys_ipc_send` directly

libpdx-audit is a shared library — no runnable executable of its own.
Every syscall the library issues (`sys_svc_lookup`, `sys_ipc_send`)
originates from `audit_send_record`, which is called transitively
from `audit_begin` / `audit_record_output` / `audit_commit`. In a
bare test-run (no kernel), those calls would trap. The drivers
therefore stay inside the pure-leaf subset of the API — reset,
`audit_can_emit_output`, `audit_hash_*`, `audit_set_parent` — and
fault-inject failure states directly into the AuditRecord `.bss`
slots. This covers every invariant the library owns; the full
kernel round-trip lives in the QEMU protocol below.

## QEMU smoke protocol (deferred)

The full M4 smoke matrix — spawn a bootstrap consumer under QEMU,
observe stdout/stderr and the audit-journal endpoint, verify wire
bytes match `goldens/trace_001.md` — needs three not-yet-landed
substrates:

1. **shell.M4** (`paideia-os/shell` §5.2 in the plan) so a
   consumer can be spawned with a bounded cap set.
2. **A runnable bootstrap consumer** — pkg.M2, cat.M2, or a
   small `examples/` binary hosted here — that links libpdx-audit
   and calls the drivers from its own test-runner main.
3. **R49-PREP-007** — the kernel-side `audit_journal_broker_dispatch`
   daemon body (currently returns `AJB_DISPATCH_STUB`; landed in
   paideia-os commit `2ff76d4`). Without a real daemon the
   sys_ipc_send target discards the payload; wire-byte replay
   needs a daemon that persists the payload for inspection.

Once those three are in place, the smoke matrix runs:

### M4-001 QEMU protocol

1. Boot QEMU with an image that has **no** `svc.audit-journal`
   broker registered (or that registers a broker whose backing
   endpoint has zero write rights).
2. Spawn the bootstrap consumer with the driver linked in.
3. Consumer runs `TestBrokerRefusal::run()`; if != 0, exit that
   ordinal.
4. Consumer then runs the failure-path fixture from
   `goldens/trace_001.md` — attempts a full three-call audit.
5. Assertions:
   - Consumer exits `3` (per I4 system-error).
   - Consumer emitted `0` bytes to stdout.
   - No audit record landed on any endpoint.

### M4-002 QEMU protocol

1. Boot QEMU with an image where `svc.audit-journal` is registered
   and the endpoint's pending queue is being drained by a debug
   observer that captures the payload bytes verbatim.
2. Spawn the bootstrap consumer with the driver linked in.
3. Consumer runs `TestReplayGolden::run()`; if != 0, exit that
   ordinal (library-observable invariants failed before wire test).
4. Consumer runs the canonical trace from `goldens/trace_001.md`.
5. Observer captures three 64-byte payloads (INVOKE / OUTPUT /
   EXIT).
6. Assertions (memcmp per section of `trace_001.md`):
   - Header word matches `AUDIT_HDR_WORD = 0x0000004000000120`.
   - Payload [1] transitions `130 → 132 → 133` across the three
     sends and no other order.
   - Payload [7] is `0x000000000000002a` on all three sends (the
     parent linkage from `audit_set_parent` — the M3-002 contract).
   - Every other slot matches the per-section table.

## What did not land in M4 (deferred to later waves)

- **BLAKE3 primitive swap.** `test_replay_golden.pdx` uses the FNV-
  1a-64 placeholder from M3-001. Once paideia-as exposes BLAKE3 as
  a stdlib intrinsic (post-v0.33-crypto-kdf), the empty-stream
  subtest changes constant (BLAKE3 has its own IV/state-init
  contract) and the golden trace's `<HASH_LS>` recomputes.
- **Bounded-retry backoff correctness.** M2-003's retry-on-EAGAIN
  loop needs a QEMU harness that can programmatically stall the
  endpoint's pending queue to induce EAGAIN. That harness is a
  paideia-os R21+ SMP-era artifact — the correctness of the
  loop is verified by the smoke matrix as a whole (a full audit
  that succeeds proves the retry path did not fire spuriously)
  and by code review of the `asr_retry` block in
  `src/audit_broker.pdx`.
- **Bootstrap-tool test runner.** A minimal `examples/`
  or `tools/test-runner.pdx` that links the two driver modules
  and calls their `run()` entry points from its `_start`. Landing
  this before any consumer tool exists would require duplicating
  the paideia-as build harness in this repo; the plan §5.13
  keeps the runner in the eventual consumer tool (pkg or shell)
  since every consumer needs the same libpdx-audit link discipline
  anyway.
