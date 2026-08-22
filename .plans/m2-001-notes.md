# libpdx-audit.M2-001 — implementation notes

**Issue:** #3 — record shape matches UEJ_KIND_TOOL_INVOKE/OUTPUT/EXIT.
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.13 (paideia-os).

## What landed

- `src/audit_record.pdx` — added three lifecycle event-kind constants:
  `UEJ_KIND_TOOL_INVOKE = 130` (matches kernel-side ordinal at
  `src/kernel/core/ipc/audit_journal_broker.pdx` in paideia-os),
  `UEJ_KIND_TOOL_OUTPUT = 132`, `UEJ_KIND_TOOL_EXIT = 133`. OUTPUT and
  EXIT are forward-declared pending R49-PREP-007 (kernel-side ordinal
  split); the daemon body is still stubbed
  (`audit_journal_broker_dispatch` returns `AJB_DISPATCH_STUB`) so the
  transport layer does not validate the event_kind field.
- `src/audit_broker.pdx` — `audit_send_committed_record` superseded
  by `audit_send_record(event_kind)`. Same 56-byte fixed wire format;
  the caller-supplied event_kind is written at payload index [1]
  (previously hard-coded to 130). Register plan uses `push r12; push
  r13;` prologue: r12 stashes event_kind across the audit_broker_bind
  call, r13 is alignment-only (two pushes keep rsp % 16 == 0 for the
  nested sys_ipc_send). All three cleanup paths (asr_bind_fail,
  asr_ipc_fail, asr_ok) pop both registers before ret.
- `src/audit_client.pdx` — all three lifecycle entry points now emit
  an IPC send at their state transition:
  - `audit_begin` sends INVOKE after IDLE -> BEGUN.
  - `audit_record_output` sends OUTPUT after BEGUN -> OUTPUT.
  - `audit_commit` sends EXIT after {BEGUN|OUTPUT} -> COMMITTED
    (replaces the M1-002 audit_send_committed_record call).
  Effects widened for `audit_begin` and `audit_record_output` from
  M1's `!{mem} @{}` to `!{mem, sysreg} @{cap, sched}` matching
  `audit_send_record`. `audit_commit` was already at the wider tail.
- `STATUS.md` — M2-001 marked landed; M2-002 / M2-003 marked next.

## Design decisions

- **Fixed 56-byte payload across all three event kinds.** The wire
  layout is identical for INVOKE, OUTPUT, and EXIT — the event_kind
  discriminator at index [1] tells the supervisor which fields carry
  meaningful state at that phase. INVOKE at begin sees exit_code = 0
  and output_hash = 0 (those .bss slots have not yet been written by
  the client); OUTPUT sees exit_code = 0 but has the output slots
  populated; EXIT sees the full record. Forward-compatible with a
  future variable-length shape without breaking the M2 wire.
- **Forward-declared OUTPUT / EXIT ordinals.** The kernel side has
  UEJ_KIND_TOOL_INSTALL (128), REMOVE (129), INVOKE (130), ERROR
  (131) — no dedicated OUTPUT/EXIT. R49-PREP-007 will add them; in
  the meantime the client defines them locally as 132/133 (outside
  the current kernel-side range but inside the reserved [128..255]
  user-event band). Sends succeed because the daemon body is still
  stubbed and the transport does not validate the event_kind field
  before enqueue.
- **audit_begin returns 0 on both state-error and send-error.** M1's
  contract already used 0 as the audit_id-of-error sentinel (positive
  values are the actual id). M2-001 adds a second 0-return path
  (broker/send failure) which the consumer treats identically —
  exit 3, emit no output. Post-mortem discriminates via record_state
  (BEGUN on send failure vs. IDLE on gate failure).
- **record_state stays at BEGUN when the INVOKE send fails.** A
  well-behaved caller sees the 0 return and exits 3 immediately; a
  buggy caller ignoring the 0 return and calling audit_record_output
  passes the state gate but fails the id gate (record_audit_id is
  the just-allocated positive id, mismatching the 0 the caller
  received). This defence-in-depth surfaces the bug as
  AUDIT_ERR_ID_MISMATCH rather than silently succeeding.

## paideia-as conformance

- Module names unchanged (`AuditRecord`, `AuditClient`, `AuditBroker`) —
  PascalCase basename per `<BasenamePascalCase>` rule.
- No `test` mnemonic anywhere; every zero-check is `cmp reg, 0`.
- Every `cmp reg, imm` uses an immediate ≤ 0x7FFFFFFF (max seen:
  0xFFFF for the broker sentinel from M1-002, unchanged here).
- `r11` used only as LEA scratch. `r12`/`r13` in audit_send_record's
  prologue are properly pushed/popped in pairs for rsp % 16 == 0
  alignment at both nested calls (audit_broker_bind + sys_ipc_send).
  audit_client entry points touch no callee-save regs — the widened
  effect tail comes entirely from the transitive call into
  audit_send_record; arg preservation is handled by storing into
  .bss before the call.
- Byte reads: none in M2-001 (all field reads are u64-wide).
- SysV push/pop parity: audit_send_record pushes r12, r13 (two
  pushes; even count keeps rsp % 16 == 0 at both nested calls). All
  three cleanup labels (asr_ok, asr_ipc_fail, asr_bind_fail) pop in
  reverse order before ret. audit_client's three entry points now
  make cross-module calls but preserve no state across them.

## Cross-module linkage

`src/audit_client.pdx` gains no new .bss references over M1 but now
calls `audit_send_record` (renamed from `audit_send_committed_record`)
from all three lifecycle entry points instead of just audit_commit.
Every cross-module reference is unqualified — resolved by the
paideia-as linker across compilation units per the parser.pdx pattern.

## What did not land (queued for M2-002 and M2-003)

- Broker-failed sticky flag + `audit_can_emit_output()` guard for the
  consumer's D3 audit-first refusal discipline — M2-002.
- Bounded retry-with-backoff (3 retries on SYS_IPC_SEND_ERR_EAGAIN
  before hard-fail) — M2-003.
- Three-way kernel-side ordinal split (adding UEJ_KIND_TOOL_OUTPUT
  and UEJ_KIND_TOOL_EXIT at 132/133 to `audit_journal_broker.pdx`
  and widening `uej_kind_valid`) — R49-PREP-007, filed against
  paideia-os as a separate substrate task.
- Kernel-side daemon body — the audit_journal broker registration
  seam is landed (2ff76d4 in paideia-os) but `audit_journal_broker_
  dispatch` returns AJB_DISPATCH_STUB. The daemon is out of scope
  for libpdx-audit; it lands with a paideia-os service milestone
  once R49-PREP-007 has closed.

## Build note

libpdx-audit M2 has no local build script yet. paideia-as ≥ v0.33
(for the `mov_b` narrow-load mnemonic + the `@align` attribute +
the `syscall` mnemonic) will build all four modules once main
invokes `paideia-as build src/audit_record.pdx src/audit_client.pdx
src/audit_broker.pdx src/syscall_shim.pdx -o
build/libpdx-audit.pdxlib` — the exact invocation is a libpdx-audit.M2
concern to be wired later in the milestone.
