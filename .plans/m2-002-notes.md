# libpdx-audit.M2-002 — implementation notes

**Issue:** #4 — failure semantics: broker unreachable → tool refuses
output (exit 3).
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.13 (paideia-os).

## What landed

- `src/audit_record.pdx` — added the sticky failure flag
  `audit_broker_failed : u64` (10th .bss slot). `.bss` zeroing means
  it starts 0 (healthy). Once written to 1 by any failed send path,
  only `reset()` clears it — no in-flight recovery in M2. The
  existing `reset()` gains the new slot in its zero-loop.
- `src/audit_broker.pdx` — `audit_send_record` now writes 1 to
  `audit_broker_failed` from both failure epilogues:
  - `asr_bind_fail` (broker unreachable — svc_lookup miss / cap-table
    full): the write happens before restoring rax to
    AUDIT_ERR_BROKER_UNAVAILABLE (3).
  - `asr_ipc_fail` (sys_ipc_send returned non-zero — EAGAIN /
    BAD_ID / PAYLOAD_LEN / EFAULT / CHANDEAD): the write happens
    before rax is set to AUDIT_ERR_SEND_FAILED (4).
  The write uses rcx (not rax — rax holds the return code) via r11.
- `src/audit_client.pdx` — new public helper `audit_can_emit_output()`
  -> u64. Effects `!{mem} @{}` — pure .bss read. Returns 1 if it is
  safe for the consumer to write user-visible output; 0 if the
  consumer MUST exit 3 per I4 without emitting anything. Consumer
  wraps every stdout/stderr write with a pre-check on this.
- `STATUS.md` — M2-002 marked landed; M2-003 marked next.

## Design decisions

- **Sticky flag, not a per-call return.** The three audit_send_record
  callsites (audit_begin, audit_record_output, audit_commit) each
  already return a non-OK code on failure — the consumer could infer
  "refuse output" from any of those. But requiring the consumer to
  track that state across the tool's own control flow is a category
  of bug the D3 audit-first upgrade should not depend on
  eliminating. The sticky flag centralises the invariant: any single
  failure anywhere in the audit lifecycle taints the whole
  invocation, and audit_can_emit_output() is a one-line pre-check
  the consumer wires ONCE at every output site.
- **audit_broker_failed monotonic within a process.** Once set, only
  reset() clears it. This matches the M1 semantic that
  audit_broker_slot is monotonic once bound — a broker that has
  proven itself unreliable stays untrusted for the rest of the
  process. A re-bind attempt after a transient outage would need a
  reset() at process start, which every consumer already does.
- **Guard is pure `.bss` read.** No syscall, no cap consumption; the
  effect tail is `!{mem} @{}` so consumers can call it from any
  context including deep inside their own hot paths. The overhead
  is one LEA + one load + one compare + one conditional jump.
- **Both bind failure and send failure set the flag.** The M2 doc
  says "if svc.audit-journal is unreachable OR full" — bind failure
  covers "unreachable" (svc_lookup miss), send failure covers "full"
  (endpoint pending queue full → EAGAIN) and every other terminal
  condition (BAD_ID / PAYLOAD_LEN / EFAULT / CHANDEAD). Symmetric
  treatment.
- **`audit_can_emit_output` return convention (1 = safe, 0 = refuse)
  inverts the .bss slot's polarity (0 = healthy, 1 = failed).** The
  double inversion is deliberate: the .bss slot follows the "zero
  is the initial safe state" convention every other AuditRecord
  slot uses; the API return follows the "positive = go, zero = stop"
  convention consumers naturally read as `if audit_can_emit_output()
  { emit } else { exit(3) }`.

## paideia-as conformance

- No `test` mnemonic; the flag read is `mov rax, [r11]; cmp rax, 0`.
- Every `cmp reg, imm` uses an immediate ≤ 0x7FFFFFFF (max: 1 for
  the flag write, 0 for the flag check).
- `r11` used only as LEA scratch. `rcx` used to write 1 through r11
  in the failure epilogues so rax (return code) is preserved.
- Byte reads: none in M2-002 (flag is u64-wide).
- SysV push/pop parity: `audit_can_emit_output` is a pure leaf, no
  callee-save touched. The two audit_send_record failure epilogues
  add a rcx write + LEA + store before the existing pop r13; pop r12;
  ret sequence — no additional pushes needed since rcx is caller-save.

## Cross-module linkage

New references:
- `audit_client.pdx` reads `audit_broker_failed` (in AuditRecord .bss).
- `audit_broker.pdx` writes `audit_broker_failed` (in AuditRecord .bss)
  from the two failure epilogues of audit_send_record.
- `audit_record.pdx`'s `reset()` gains a new zero-write for the same
  slot so a re-init clears the flag.

Every reference is unqualified, resolved by the paideia-as linker
across compilation units per the parser.pdx pattern.

## What did not land (queued for M2-003)

- Bounded retry-with-backoff (3 retries on SYS_IPC_SEND_ERR_EAGAIN
  before hard-fail). At M2-002 a single EAGAIN sets the sticky flag;
  M2-003 retries transient EAGAINs first and only sets the flag if
  all three retries fail. This is the ordering the plan documents.

## Consumer contract (D3 audit-first refresher)

Every R49/R50 tool wires the three-call API + the output guard as:

```
AuditRecord::reset()
let id = AuditClient::audit_begin(op_name, args)
if id == 0 { sys_exit(3) }             // begin failed (state or send)
…do work…
let err = AuditClient::audit_record_output(id, schema, hash)
if err != 0 { sys_exit(3) }             // record failed
if AuditClient::audit_can_emit_output() == 0 { sys_exit(3) }  // M2-002
…emit output…
let err = AuditClient::audit_commit(id, exit_code)
if err != 0 { sys_exit(3) }             // commit failed
```

The audit_can_emit_output() guard is redundant given the return-code
checks after each audit call — but the redundancy is the point:
consumers cannot forget to check, and the guard's cost is trivial.
