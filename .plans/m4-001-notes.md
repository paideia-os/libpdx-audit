# libpdx-audit.M4-001 — implementation notes

**Issue:** #8 — broker-unavailable refusal test (tool exits 3, no
output emitted).
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.13 (paideia-os).

## What landed

- `tests/test_broker_refusal.pdx` — new `TestBrokerRefusal` module.
  Single public entry point `run() -> u64` (effects `!{mem} @{}`)
  covering seven subtests over the M2-002 sticky-flag guard:
  1. reset() zeroes `audit_broker_failed`.
  2. `audit_can_emit_output` returns 1 (safe) after reset.
  3. Fault-inject: write 1 into `audit_broker_failed` .bss slot.
  4. `audit_can_emit_output` returns 0 (refuse) with flag set.
  5. reset() clears the flag (M2-002 doc: "once set, only reset()
     clears it").
  6. Guard returns 1 (safe) after re-reset.
  7. `audit_broker_slot` = `AUDIT_BROKER_SLOT_UNRESOLVED` (0xFFFF)
     after reset — the M1-002 sentinel that gates the fast-path in
     `audit_broker_bind` and forces the next real `svc_lookup`.
- `tests/README.md` — updated to describe the test suite structure,
  return-code convention (0=pass, N=subtest-ordinal), and the
  deferred QEMU protocol.
- `tests/goldens/trace_001.md` — companion "failure-path fixture"
  section documents the QEMU protocol expected observable behaviour:
  child exits 3, emits 0 bytes to stdout, no audit record on any
  endpoint.
- `STATUS.md` — M4-001 marked landed.

## Design decisions

- **Fault-injection, not real broker miss.** libpdx-audit is a
  shared library with no runnable executable. Invoking
  `audit_send_record` directly would call `sys_ipc_send` which
  traps without a kernel. Fault-injection via a direct .bss write
  to `audit_broker_failed = 1` is functionally equivalent — that
  write is exactly what the M2-002 `asr_bind_fail` and
  `asr_ipc_fail` epilogues do when the real bind/send fails. The
  test then verifies the guard responds correctly to that .bss
  state. Full end-to-end (spawn under QEMU with no broker
  registered → observe exit 3 + no output) lives in the QEMU
  protocol documented in `tests/README.md` and requires shell.M4
  + a bootstrap consumer + R49-PREP-007 daemon body.
- **7 subtests, ordinal-encoded returns.** Returning 0/1 would
  answer "did it pass" but not "which invariant broke". Ordinal
  returns are cheap (one `mov rax, N; ret` per fail label) and
  make a smoke log actionable. Ordinals are stable across driver
  runs.
- **Pure leaf (`!{mem} @{}`).** Every subtest touches only .bss
  and calls two pure-leaf entry points (`reset`,
  `audit_can_emit_output`). No syscall, no cap consumption. This
  lets the driver run under any consumer, including one that
  hasn't asked for any of the widened effects that
  `audit_begin`/`audit_record_output`/`audit_commit` require.
- **r12/r13 pushed for alignment parity, not need.** The subtest
  sequence has no state to preserve across calls — each subtest is
  self-contained. r12/r13 are pushed as a pair to keep
  `rsp % 16 == 0` at every nested call, mirroring the SysV
  discipline in `audit_send_record`. A future refactor that
  introduces cross-subtest state (e.g. counting passes) can use
  those registers without adding push/pop.

## paideia-as conformance

- No `test` mnemonic; every zero-check is `cmp reg, 0` /
  `cmp reg, 1` / `cmp reg, 0xFFFF`.
- Every `cmp reg, imm` uses an immediate ≤ `0x7FFFFFFF`; 0xFFFF
  encodes as a sign-extended 32-bit immediate and is within the
  bound.
- `r11` used only as LEA scratch.
- Byte reads: none in M4-001 (all state is u64-wide).
- SysV push/pop parity: r12 + r13 pushed as a pair before any
  nested call; both popped in every return path (main + 6 fail
  labels). rsp % 16 == 0 at every `call`.
- Label prefix `tbr_` (test-broker-refusal). No bare `ok`/`fail`
  labels — those collide with paideia-as keywords per the
  project reserved-label discipline.

## Cross-module linkage

New references (all resolved by the paideia-as linker per the
`parser.pdx` pattern):

- Reads `audit_broker_failed` (in `AuditRecord` .bss).
- Reads `audit_broker_slot` (in `AuditRecord` .bss).
- Writes `audit_broker_failed` (fault-injection subtest 3).
- Calls `reset` (in `AuditRecord`).
- Calls `audit_can_emit_output` (in `AuditClient`, M2-002).

Zero new cross-repo dependencies; every symbol used already exists
in libpdx-audit's M1..M3 surface.

## Consumer contract

A future test-runner main in a bootstrap consumer wires the driver
as:

```
let fail = TestBrokerRefusal::run()
if fail != 0 { sys_exit(64 + fail) }    // ordinals reserved 64..71
```

Encoding failing ordinals as exit codes ≥ 64 keeps them distinct
from the D3 refuse-output exit 3 and from the standard 0..2
success/error codes; 64..71 (7 subtests) fits comfortably below
128.

## What did not land (deferred)

- **QEMU end-to-end smoke.** Needs shell.M4 + bootstrap consumer +
  R49-PREP-007 daemon. Documented in `tests/README.md` §M4-001
  QEMU protocol as the follow-up when those substrates land.
- **Cap-table exhaustion path.** M2-002 covers "broker unreachable
  OR full". The `audit_broker_failed` .bss slot is set from both
  the bind-fail epilogue (unreachable → ENOENT / EINVAL / EFAULT
  / ENOSPC) and the send-fail epilogue (full → EAGAIN after 3
  retries, or BAD_ID/PAYLOAD_LEN/EFAULT/CHANDEAD). The driver's
  fault-injection tests both paths through the same .bss slot —
  distinguishing them requires kernel-side error simulation, which
  is a QEMU-protocol concern.
