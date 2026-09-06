# tests/ — libpdx-audit test suite (M4 + LA.M1)

**Milestone lineage.** M4 in `design/tooling/r49-r50-plan.md` §5.13
(paideia-os) rubric line: `tests + smoke`. Two open issues under this
milestone in the `paideia-os/libpdx-audit` repo:

- **#8 — M4-001** broker-unavailable refusal test (tool exits 3, no
  output emitted).
- **#9 — M4-002** audit-journal replay correctness against known trace.

Both landed at M4.

## Files

- `test_broker_refusal.pdx` — M4-001 driver. Exports
  `TestBrokerRefusal::test_broker_refusal_run() -> u64` (renamed
  from the pre-LA.M1-002 (#21) bare `run` so a runner linking this
  driver alongside a sibling `run` sees no symbol collision).
  Verifies the M2-002 sticky-flag guard, the ENH-005 fail-closed-
  when-no-audit-is-open guard, the ENH-008 failure-cause
  diagnostic accessor, (LA.M1-003 (#22) subtests 11+12) the
  ENH-006 `audit_last_error` diagnostic accessor, and (#30 subtest
  13) the LA.M1-001 (#20) `audit_broker_bind` bss-zero fast-path
  range gate, end-to-end at the API surface. Returns 0 on pass or a
  1..13 subtest ordinal on failure. Effects `!{mem, sysreg} @{cap}`
  — subtests 1..12 are pure `.bss` fault-injection (no syscall);
  subtest 13 (#30) is the one exception, calling the REAL
  `audit_broker_bind` (still linked against the real
  `src/syscall_shim.pdx`, never the stub — see below) because no
  `.bss`-only assertion can distinguish "the fast path correctly
  deferred to `sys_svc_lookup`" from "the fast path never ran".
- `test_replay_golden.pdx` — M4-002 driver. Exports
  `TestReplayGolden::test_replay_golden_run() -> u64` (renamed per
  LA.M1-002 (#21)). Verifies the wire-format invariants that a
  supervisor replaying the audit journal depends on — state-
  machine reset, FNV-1a-64 empty-stream self-check, hash active-
  flag gates, len=0 no-op, parent-linkage propagation into the
  .bss slot marshal reads, (ENH-004) the `audit_rearm` selective-
  clear contract, and (LA.M1-004 (#23) subtests 10+11) two
  FNV-1a-64 known-vector checks — single-call over `"foobar"`
  against the reference vector `0x85944171f73967e8` plus a
  chunked-update (`"foo"` then `"bar"`) property test that
  verifies `record_hash_state` is persisted across
  `audit_hash_update` calls. Returns 0 on pass or a 1..11 subtest
  ordinal on failure. Pure leaf (effects `!{mem} @{}`).
- `test_marshal_harness.pdx` — LA.M1-005 (#24) driver. Exports
  `TestMarshalHarness::test_marshal_harness_run() -> u64`. Drives
  a full `reset()` → `audit_broker_bind` → `audit_begin` →
  `audit_record_output` → `audit_commit` lifecycle against the
  `syscall_shim_stub.pdx` link-time replacement, then memcmps the
  captured EXIT payload against a hand-authored @0.2 golden byte
  pattern. Returns 0 on pass or a 1..5 subtest ordinal on failure.
  Effects `!{mem, sysreg} @{cap, sched}` inherited from the
  lifecycle callees.
- `syscall_shim_stub.pdx` — LA.M1-005 (#24) test double. Exports
  the same three symbols as `src/syscall_shim.pdx`
  (`sys_svc_lookup`, `sys_ipc_send`, `sys_getpid`) with byte-for-
  byte identical signatures; captures `sys_ipc_send`'s arguments
  into four `.bss` slots (`stub_captured_slot`, `stub_captured_hdr`,
  `stub_captured_payload[256]`, `stub_captured_len`) and returns
  success without invoking any actual syscall. **Link-time
  discipline**: this file MUST replace `src/syscall_shim.pdx` in
  the link line for the `test_marshal_harness` runner binary and
  MUST NOT be linked alongside the real trampolines (duplicate-
  symbol errors). The QEMU drivers (`test_broker_refusal`,
  `test_replay_golden`) link the real `src/syscall_shim.pdx` and
  must not link this file. See the file's module header for the
  substitution rationale.
- `test_append_leaf.pdx` — LE.M2-002 (`#31`) driver. Exports
  `TestAppendLeaf::test_append_leaf_run() -> u64`. Exercises
  `AuditClient::audit_append_leaf` end to end: null-buffer refusal,
  undersized/oversized length refusal (both boundary sides of
  `[AUDIT_LEAF_MIN_BYTES=16, AUDIT_LEAF_MAX_BYTES=128]`),
  sink-unavailable fail-close under both the `.bss`-zero and the
  explicit `AUDIT_BROKER_SLOT_UNRESOLVED` (`0xFFFF`) sentinel,
  a byte-for-byte accepted-write verification (including the
  zero-padded tail past the accepted length) against a fault-injected
  valid kernel cap slot, and acceptance under the
  `AuditBrokerSatellite` bind sentinel (`0xFFFE`). Returns 0 on pass or
  a 1..7 subtest ordinal on failure. Pure leaf (effects `!{mem} @{}`)
  — `audit_append_leaf` never calls `audit_broker_bind` or
  `sys_ipc_send`, so this driver needs no syscall shim at all, real or
  stubbed.
- `goldens/trace_001.md` — the M4-002 wire-bytes fixture
  (`PdxAuditRecord@0.2`, post-1.0.0 issues `#11` + `#12`: 256-byte
  hybrid payload + header layout, per INVOKE / OUTPUT / EXIT
  lifecycle send). Documents the byte-for-byte contract the QEMU
  harness compares `AuditRecord::audit_payload_scratch` against once
  a runnable consumer tool hosts the driver.

## Return-code convention

Every M4 test driver in this tree returns a `u64` where:

- `0` — all subtests passed.
- `N > 0` — the ordinal of the first failing subtest. Ordinals are
  stable across driver runs so a smoke log can pinpoint which
  invariant broke.

A test harness (in a future consumer tool) walks the driver list,
sums the non-zero returns per driver, and exits `0` iff every driver
returned `0`.

## Why the M4 drivers do not invoke `sys_ipc_send` directly

libpdx-audit is a shared library — no runnable executable of its own.
Every syscall the library issues (`sys_svc_lookup`, `sys_ipc_send`)
originates from `audit_send_record`, which is called transitively
from `audit_begin` / `audit_record_output` / `audit_commit`. In a
bare test-run (no kernel), those calls would trap. The M4 drivers
(`test_broker_refusal`, `test_replay_golden`) therefore stay inside
the pure-leaf subset of the API — reset, `audit_can_emit_output`,
`audit_hash_*`, `audit_set_parent` — and fault-inject failure states
directly into the AuditRecord `.bss` slots. This covers every
invariant the library owns short of the marshal-side wire bytes; the
full kernel round-trip lives in the QEMU protocol below.

**LA.M1-005 (#24) exception.** The `test_marshal_harness` driver
DOES exercise the full three-call lifecycle (and therefore
`audit_send_record` + the marshal path), but only against the
`syscall_shim_stub.pdx` link-time replacement — the stub's
`sys_ipc_send` captures the payload into `.bss` and returns
success without invoking any real syscall, so a bare test-run
does not trap. This lets the driver verify the @0.2 wire-byte
marshal correctness end-to-end (which no fault-injected M4 driver
can reach) without needing kernel or QEMU. The trade-off is the
link-line discipline described in the driver's module header
(never link the stub alongside the real trampolines; never link
the M4 drivers with the stub).

**#30 exception.** `test_broker_refusal`'s subtest 13 calls the
REAL `AuditBroker::audit_broker_bind` (which transitively invokes
`sys_svc_lookup`) rather than fault-injecting around it, because no
`.bss`-only assertion can prove the LA.M1-001 (#20) range gate
still forces the `sys_svc_lookup` slow path on a `.bss`-zero
`audit_broker_slot` — every earlier subtest either never touches
that slot or only checks the sentinel `reset()` itself writes
(subtest 8), so none of them would catch a future revert of the
gate back to its pre-fix single-compare form. Unlike
`test_marshal_harness`, this subtest does NOT link the stub —
`test_broker_refusal` keeps its QEMU-driver classification (real
`src/syscall_shim.pdx`) so the M4-001 QEMU protocol below is
unaffected. Since a real `sys_svc_lookup` may legitimately succeed
or fail depending on whether `svc.audit-journal` is registered in
whatever environment runs this driver, subtest 13's assertion is
deliberately environment-independent: it fails only on the one
`.bss` signature — `audit_broker_bind` returned `AUDIT_OK` AND
`audit_broker_slot` is still the fault-injected `0` — that a
bypassed fast path (and only a bypassed fast path) can produce. In
a bare test-run without a kernel, this subtest's `sys_svc_lookup`
call would trap exactly as `test_marshal_harness`'s calls would
without the stub; both drivers only actually execute inside the
QEMU protocol described below or a future kernel-linked runner.

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
3. Consumer runs `TestBrokerRefusal::test_broker_refusal_run()`;
   if != 0, exit that ordinal. (#30: subtest 13 already attempts a
   real `audit_broker_bind` here — in this no-broker environment
   `sys_svc_lookup` fails and the subtest expects
   `AUDIT_ERR_BROKER_UNAVAILABLE`, which also leaves
   `audit_broker_slot` at its fault-injected `0` for step 4's fixture
   to re-attempt.)
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
3. Consumer runs `TestReplayGolden::test_replay_golden_run()`;
   if != 0, exit that ordinal (library-observable invariants
   failed before wire test).
4. Consumer runs the canonical trace from `goldens/trace_001.md`.
5. Observer captures three 256-byte payloads (INVOKE / OUTPUT /
   EXIT).
6. Assertions (memcmp per section of `trace_001.md`):
   - Header word matches `AUDIT_HDR_WORD = 0x0000010000000220`.
   - Payload offset 8 (`event_kind`) transitions `130 → 132 → 133`
     across the three sends and no other order.
   - Payload offset 24 (`parent_audit_id`) is
     `0x000000030000002a` on all three sends (the parent linkage
     from `audit_set_parent` — the M3-002 contract, composed per
     `#12`).
   - Every other field matches the per-section table, including the
     three inline string fields decoded as text (`#11`).

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
  or `tools/test-runner.pdx` that links the three driver modules
  and calls their namespaced entry points
  (`test_broker_refusal_run`, `test_replay_golden_run`,
  `test_marshal_harness_run`) from its `_start`. Landing this
  before any consumer tool exists would require duplicating the
  paideia-as build harness in this repo; the plan §5.13 keeps the
  runner in the eventual consumer tool (pkg or shell) since every
  consumer needs the same libpdx-audit link discipline anyway.
  The `test_marshal_harness` binary is a special case — it must
  link `tests/syscall_shim_stub.pdx` in place of
  `src/syscall_shim.pdx`; see the driver's module header for the
  link-line discipline.
