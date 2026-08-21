# libpdx-audit.M1-002 — implementation notes

**Issue:** #2 — audit_id allocation + svc.audit-journal broker binding.
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.13 (paideia-os).

## What landed

- `src/syscall_shim.pdx` — new module `SyscallShim` with two
  trampolines:
  - `sys_svc_lookup(name_ptr, name_len)` — SC+ ID 43, arity 2, no
    r10 shuffle. Declares `!{mem, sysreg} @{cap}` to match the
    kernel handler at
    `src/kernel/core/syscall/handlers/sys_svc_lookup.pdx` in
    paideia-os.
  - `sys_ipc_send(cap_slot, hdr_va, payload_va, payload_len)` — SC+
    ID 42, arity 4, requires `mov r10, rcx` shuffle. Declares
    `!{mem, sysreg} @{cap, sched}` to match `sys_ipc_send_body`.
- `src/audit_broker.pdx` — new module `AuditBroker` with two entry
  points:
  - `audit_broker_bind()` — idempotent svc.audit-journal binding.
    Fast path is one load + one `cmp reg, 0xFFFF` against
    `AUDIT_BROKER_SLOT_UNRESOLVED`. Slow path calls `sys_svc_lookup`
    with the 20-byte NUL-padded name array and range-gates the
    returned slot via `cmp rax, 256; jae error` — every valid slot
    id is in `[0..255]`; every negative-errno sentinel has bit 63
    set (so its unsigned interpretation is > 256).
  - `audit_send_committed_record()` — bind + marshal + send. Loads
    the seven u64 fields from the AuditRecord singleton in wire
    order, writes UEJ_KIND_TOOL_INVOKE (130) at payload index [1]
    (M1 stub; M2-001 discriminates INVOKE/OUTPUT/EXIT), assembles
    the packed hdr word `0x0000_0038_0000_0120`
    (op=0x20 | ver=1 | reply_endpoint_id=0 | payload_len=56), then
    invokes `sys_ipc_send`.
- `src/audit_client.pdx` — rewrote `audit_commit`:
  - Effects widened from `!{mem} @{}` to `!{mem, sysreg} @{cap, sched}`.
  - After the state gate + id gate + COMMITTED transition, calls
    `audit_send_committed_record` and propagates its return code
    verbatim.
  - On send success, resets `record_state` to `AUDIT_STATE_IDLE` (via
    `rcx` — not `rax`, which carries the return code) so a subsequent
    `audit_begin` in the same process can start a fresh record. On
    send failure, leaves state at `COMMITTED` for post-mortem walking.
- `STATUS.md` — M1-002 marked landed; M1 milestone closed; M2
  described as next.

## Design decisions

- **Broker-slot cache lives in AuditRecord `.bss`.** Same singleton
  discipline as the eight in-progress record slots — one cached
  slot per process, populated on first bind, reused for every
  subsequent commit. Multi-cap-table (per-task) at R21+ SMP will
  need a rethink, but that is the same reshuffle every R49 library
  is deferring per libpdx-argv's M1-001 notes.
- **`cmp rax, 256; jae` discriminator.** The paideia-os
  `sys_svc_lookup_body` documents that the return value is either
  a slot id in `[0..255]` or a negative-errno sentinel (all with
  bit 63 set). A single unsigned `jae 256` cleanly discriminates
  the two ranges — same pattern the handler's own file header
  recommends for consumers.
- **Delegation to a broker-specific module.** `audit_client.pdx`
  stays free of any concrete `sys_svc_lookup` / `sys_ipc_send`
  reference; every syscall lives behind
  `AuditBroker::audit_send_committed_record`. This keeps the M2
  hardening (bounded retry, alternative transports, ring-buffer
  fallback under back-pressure) to a single edit site.
- **Stub event kind for the M1 wire format.** The three-way
  INVOKE / OUTPUT / EXIT split is a kernel-side R49-PREP-007 change
  (currently the broker only has INSTALL / REMOVE / INVOKE / ERROR
  at ordinals 128..131 — no dedicated OUTPUT / EXIT ordinals yet).
  M1's `audit_send_committed_record` writes 130 (INVOKE) at index
  [1] and stashes the exit code at index [2] so a supervisor
  replaying the trace can still discriminate an EXIT-carrying
  record from a bare INVOKE. M2-001 revisits this once the
  kernel-side ordinals land.
- **Two-step MOVABS + store for the hdr word.** paideia-as does
  not encode `mov [mem], imm64` in a single instruction, so the
  packed hdr word (which does not fit in the 32-bit imm form) is
  written via `mov rax, imm64; mov [scratch], rax`. This is the
  same two-step every user-space caller in `src/user/echo_client.pdx`
  uses at paideia-os L215-217.

## paideia-as conformance

- Module names PascalCase basename (`SyscallShim`, `AuditBroker`)
  with no directory prefix.
- No `test` mnemonic anywhere; every zero-check is `cmp reg, 0`;
  every non-zero-check is `cmp reg, imm` with an encoder-safe
  immediate (max seen: `0xFFFF` for the broker sentinel, `256`
  for the slot discriminator).
- `r11` used only as scratch (LEA temps + one-off spills for cross-
  module references). Never live across a call.
- Byte loads: none in M1-002 (payload marshalling is u64-wide;
  the broker name is fetched as a whole array via `lea rdi,
  [rip + audit_broker_name]` and the kernel handler consumes it).
- SysV push/pop parity: no function in M1-002 touches
  `rbx`/`r12..r15`. `audit_broker_bind` and
  `audit_send_committed_record` both wrap calls (`sys_svc_lookup`
  and `sys_ipc_send` respectively) but need no state kept across
  those calls — cached broker slot lives in `.bss`, and the
  payload scratch is written via unconditional stores rather than
  cross-call live state. `rsp` stays `% 16 == 0` at every nested
  call because no push has happened.

## Cross-module linkage

`src/audit_client.pdx` gains a single cross-module call reference —
`audit_send_committed_record` (defined in `src/audit_broker.pdx`).
`src/audit_broker.pdx` references nine AuditRecord `.bss` symbols
plus two SyscallShim functions. Every reference is unqualified,
resolved by the paideia-as linker across compilation units per
the `Tokenizer::argc` reference pattern in `src/user/dispatch.pdx`
(paideia-os).

## What did not land (queued for M2 and beyond)

- Three-way `UEJ_KIND_TOOL_INVOKE / OUTPUT / EXIT` split — M2-001.
  Depends on R49-PREP-007 (kernel-side ordinal allocation).
- Broker-unreachable refusal test (tool exits 3, no output) —
  M2-002. `audit_commit` already returns the right error code;
  the test needs a synthetic broker-drop shim.
- Bounded retry-with-backoff (3 retries then hard-fail) — M2-003.
  Wraps `sys_ipc_send` inside `audit_send_committed_record`.
- BLAKE3-truncated output-stream hash computation — M3-001. The
  `output_hash` slot is currently caller-supplied.
- Parent-child linkage with `ShellCommandRecord` via `audit_id` —
  M3-002. Adds a `parent_audit_id` field and a shell-side hook.
- Cap-table-full recovery beyond the initial svc_lookup — deferred
  to R21+ SMP when per-task cap tables land.

## Build note

libpdx-audit M1 has no local build script yet. paideia-as ≥ v0.33
(for the `mov_b` narrow-load mnemonic + the `@align` attribute +
the `syscall` mnemonic) will build all four modules once main
invokes `paideia-as build src/audit_record.pdx src/audit_client.pdx
src/audit_broker.pdx src/syscall_shim.pdx -o
build/libpdx-audit.pdxlib` — the exact invocation is a
libpdx-audit.M2 concern, not M1.
