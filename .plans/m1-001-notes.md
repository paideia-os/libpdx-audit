# libpdx-audit.M1-001 — implementation notes

**Issue:** #1 — scaffold + three-call API (`audit_begin`,
`audit_record_output`, `audit_commit`).
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.13 (paideia-os).

## What landed

- `caps.decl` — libpdx-audit declares the two syscalls the M1-002
  broker binding will make (`sys_svc_lookup`, `sys_ipc_send`) and the
  one KIND_IPC_ENDPOINT grant on `svc.audit-journal` the broker will
  mint at bind time. Declares the `PdxAuditRecord@0.1` output schema
  for the M3 semantic-pipe integration.
- `design/architecture.md` — full internal spec: public surface,
  AuditRecord shape + wire format, singleton storage model, state
  machine, audit_id allocation (M1-002), svc.audit-journal broker
  binding (M1-002), send failure discipline, paideia-as encoding
  conformance, and explicit non-goals for M1.
- `src/audit_record.pdx` — `AuditRecord` module: error-code constants,
  state constants, broker-slot sentinel, singleton .bss storage
  (audit_id_next + eight record slots + broker cache + payload/hdr
  scratch), `reset()` entry point that seeds `audit_id_next = 1` and
  `audit_broker_slot = 0xFFFF` alongside the eight-slot zero pass.
- `src/audit_client.pdx` — `AuditClient` module: three entry points
  (`audit_begin`, `audit_record_output`, `audit_commit`) with the
  full state-machine gate discipline from `design/architecture.md`
  §4. `audit_commit` stops after transitioning to `COMMITTED` — the
  send path (broker bind + sys_ipc_send) lands with M1-002.
- `tests/README.md` — pointer to `libpdx-audit.M4-001` and
  `libpdx-audit.M4-002` for the actual test matrix.
- `STATUS.md` — M1-001 marked landed; M1-002 marked pending.

## Design decisions

- **Singleton `.bss` storage.** Follows the `Tokenizer::argv_buf` /
  `Dispatch::builtin_names` precedent in `src/user/*.pdx` (paideia-os)
  and libpdx-argv's `ParsedArgs::flag_names`. Zero heap; one audit
  in flight per process is enough for the R49/R50 wave. M3-002 adds
  the caller-owned `AuditRecord*` variant for nested audits.
- **`audit_id_next` monotonic + lazy-init to 1.** The counter's
  post-increment shape hands out ids 1, 2, 3, … so `record_audit_id
  == 0` remains the reserved "no audit" sentinel. Lazy-init in
  `audit_begin` is defence-in-depth against a consumer that skipped
  `AuditRecord::reset()` at process start; `reset()` writes the same
  seed value.
- **State-before-id gate ordering.** `audit_record_output` and
  `audit_commit` both evaluate the state gate BEFORE the id gate.
  This ordering surfaces a stale audit_id passed after commit as
  `AUDIT_ERR_STATE` (a real usage bug — the caller is holding onto
  an id whose record has already been sealed) rather than as
  `AUDIT_ERR_ID_MISMATCH` (which would suggest the caller mixed up
  two live records).
- **`audit_commit` scaffold body has no send path.** M1-001's
  `audit_commit` transitions to `COMMITTED` and returns `AUDIT_OK`
  without touching the broker or `sys_ipc_send`. This keeps
  `audit_client.pdx` free of syscall-shim dependencies at M1-001 —
  the module is `!{mem} @{}`, encoder-checkable in isolation, and
  the scaffold is exercisable without the M1-002 substrate. M1-002
  wraps this body with `AuditBroker::audit_send_committed_record`
  and widens the effect union to `!{mem, sysreg} @{cap, sched}`.
- **56-byte wire format defined but not yet emitted.** Seven u64
  words in the payload; hdr is a single packed u64. Documented in
  `design/architecture.md` §2 so M1-002 has no design churn — it
  wires an already-specified marshal.

## paideia-as conformance

- Module names PascalCase basename (`AuditRecord`, `AuditClient`)
  with no directory prefix.
- No `test` mnemonic anywhere; every zero-check is `cmp reg, 0`.
- Every `cmp reg, imm` uses an immediate ≤ 0x7FFFFFFF (max value
  seen: `0xFFFF` — the broker-slot unresolved sentinel, only
  compared in M1-002; M1-001's compares are all against 0, 1, 2).
- `r11` used only as scratch (LEA temps for cross-module references).
  Never live across a call or expected to survive.
- Byte loads: none in M1-001 (all field accesses are u64-wide). The
  `xor rax, rax; mov_b rax, [ptr]` idiom will appear in the M1-002
  syscall_shim.pdx when arg marshalling requires it.
- SysV push/pop parity: no function in M1-001 touches
  `rbx`/`r12..r15`; every register mutated is caller-save.

## Cross-module linkage

`src/audit_client.pdx` references the nine AuditRecord slots by
unqualified linker name — the paideia-as toolchain resolves these
across compilation units per the `Tokenizer::argc` reference pattern
in `src/user/dispatch.pdx` (paideia-os) and libpdx-argv's cross-file
reference discipline.

## What did not land (queued for M1-002)

- `audit_id_next` monotonic increment lands here in M1-001 as-designed,
  BUT the "handed out from a real allocator" contract that M1-002
  targets specifically means factoring the id-allocation branch out
  into its own helper so future overflow / bootstrap changes have one
  edit site. M1-002 does not need to rework the caller-visible shape.
- `svc.audit-journal` broker binding: `src/audit_broker.pdx` module
  with `audit_broker_bind()` (svc_lookup + cache) and
  `audit_send_committed_record()` (marshal + sys_ipc_send).
- `src/syscall_shim.pdx` with the two syscall trampolines
  (`sys_svc_lookup` SC+ ID 43, `sys_ipc_send` SC+ ID 42).
- `audit_commit` body rewrite to call `audit_send_committed_record`
  post-transition and widen effects to `!{mem, sysreg} @{cap, sched}`.

## Build note

libpdx-audit M1 has no local build script yet. paideia-as ≥ v0.33
(for the `mov_b` narrow-load mnemonic + the `@align` attribute) will
build both modules once main invokes `paideia-as build
src/audit_record.pdx src/audit_client.pdx -o
build/libpdx-audit.pdxlib` — the exact invocation is a libpdx-audit.M2
concern, not M1, and matches the deferral in libpdx-argv's M1-001
notes.
