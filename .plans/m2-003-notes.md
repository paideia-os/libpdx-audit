# libpdx-audit.M2-003 — implementation notes

**Issue:** #5 — retry-with-backoff (bounded 3 retries, then hard-fail).
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.13 (paideia-os).

## What landed

- `src/audit_broker.pdx` — `audit_send_record` sys_ipc_send call is
  now wrapped in a bounded retry-on-EAGAIN loop.
  - Marshal (LEA + mov of the seven payload fields + hdr word write)
    happens ONCE before the loop; only the send itself repeats.
  - `xor r13, r13` initialises retry_count = 0 before the loop.
  - `asr_retry` label starts each attempt. Args are re-loaded
    (audit_broker_slot -> rdi, hdr -> rsi, payload -> rdx, 56 -> rcx)
    every iteration because rdi/rsi/rdx/rcx are all caller-save and
    sys_ipc_send may have clobbered them.
  - `call sys_ipc_send`; then:
    - `rax == 0` (SYS_IPC_SEND_OK): jump to asr_ok.
    - `rax == 1` (SYS_IPC_SEND_ERR_EAGAIN): if r13 < 3 do backoff +
      r13 += 1 + retry; else fall to asr_ipc_fail.
    - Any other non-zero (BAD_ID / PAYLOAD_LEN / EFAULT / CHANDEAD):
      fall to asr_ipc_fail immediately.
  - Backoff: fixed 4096-cycle spin (`mov rcx, 4096; asr_backoff: sub
    rcx, 1; cmp rcx, 0; jne asr_backoff`). No `dec` or `loop`
    mnemonic per the paideia-as instruction-set discipline; sub +
    cmp + jne is the equivalent shape.

## Design decisions

- **Retry only on EAGAIN.** SYS_IPC_SEND_ERR_EAGAIN (1) is the only
  transient error code from sys_ipc_send — it means the endpoint's
  single-slot pending queue is currently full (see
  `src/kernel/core/syscall/handlers/sys_ipc_send.pdx` in paideia-os).
  Every other non-zero return is a hard programming error:
  - BAD_ID (2): the cap slot is bogus — retrying won't fix a bad slot.
  - PAYLOAD_LEN (3): the payload exceeds PENDING_PAYLOAD_MAX_BYTES —
    same failure every time.
  - EFAULT (0xFF..FFF2): the hdr or payload user-address failed the
    walker — a userspace bug.
  - CHANDEAD (0xFF..FF98): the endpoint's owning task has exited —
    the endpoint won't come back to life.
  Retrying these would burn CPU on a guaranteed-fail path. Fall
  through to asr_ipc_fail immediately.
- **3 retries then hard-fail.** Matches the plan's "bounded — 3
  retries then hard-fail" line. r13 counts attempts; after 3 retries
  (a total of 4 send calls) r13 >= 3 fails the retry-budget gate
  and falls to asr_ipc_fail. The M2-002 sticky flag is set from
  that epilogue as before.
- **Fixed backoff, not exponential.** The plan says "backoff"
  without qualifying. Exponential backoff needs a wall-clock or
  monotonic-cycles primitive that R20b does not yet expose to
  userspace — the R21+ SMP milestone adds sys_clock_gettime. Fixed
  4096-cycle spin gives the current implementation a bounded pause
  between attempts (~1 μs at modern clocks) which is enough to let
  the audit-journal daemon (once wired) drain a pending message
  from a full endpoint queue. The comment in the source flags the
  R21+ upgrade path.
- **Marshal outside the loop.** The payload and hdr scratch are
  deterministic given the AuditRecord singleton state at the time
  of the call — they don't change between retries. Marshaling once
  saves ~14 LEA + ~7 field-load instructions per retry. The event_
  kind in r12 survives every retry (SysV callee-save).
- **r13 chosen for retry_count.** The M2-001 prologue already
  pushes r13 for alignment; the counter reuses that slot without
  adding another push. r13 is SysV callee-save so sys_ipc_send
  preserves it across every retry.
- **Backoff loop uses sub + cmp + jne, not dec + jne.** paideia-as's
  instruction set exposes sub as a first-class op; dec is not
  guaranteed encoded. The existing kernel audit_journal_broker.pdx
  uses `add rcx, 1` for counter increment — sub is the symmetric
  spelling for decrement.

## paideia-as conformance

- No `test` mnemonic; every zero-check is `cmp reg, 0`.
- Every `cmp reg, imm` uses an immediate ≤ 0x7FFFFFFF (max: 4096
  for the backoff-spin start, 3 for the retry budget, 1 for the
  EAGAIN comparison, 0 for the OK check).
- `r11` used only as LEA scratch. `r12` (event_kind) and `r13`
  (retry_count) properly pushed / popped in the M2-001 prologue /
  epilogues; the backoff spin uses only rcx (caller-save) so no
  additional push/pop is needed.
- Byte reads: none in M2-003 (retry state is all u64-wide).
- SysV push/pop parity: unchanged from M2-001. The retry loop does
  not add any `call` sites — the only nested calls remain
  audit_broker_bind (outside the loop) and sys_ipc_send (inside
  the loop, each iteration). rsp % 16 == 0 at both because the
  M2-001 prologue pushes two callee-save regs (r12, r13).

## Cross-module linkage

No new cross-module references over M2-002; the retry logic lives
entirely inside audit_send_record and reads/writes only its own
scratch (audit_broker_slot in .bss, plus r12/r13 across the retry
loop). The sticky-flag write in asr_ipc_fail still references
audit_broker_failed as introduced in M2-002.

## Failure ordering

Given the M2-003 retry + M2-002 sticky-flag interaction, the
observable behaviour is:

- Attempt 1: sys_ipc_send returns 0 → asr_ok, no flag write.
- Attempt 1: returns 1 (EAGAIN) → backoff, r13=1, retry.
- Attempts 2, 3, 4: same EAGAIN handling.
- Attempt 4: still EAGAIN → r13 >= 3, jump to asr_ipc_fail →
  flag set to 1, return AUDIT_ERR_SEND_FAILED.
- Any attempt returns a non-EAGAIN non-zero → jump directly to
  asr_ipc_fail → flag set, return AUDIT_ERR_SEND_FAILED. No retry.

Every M2-003 hard-fail path passes through the M2-002 sticky-flag
write; the consumer's audit_can_emit_output() guard is uniform
across "one hard error" and "three EAGAINs then give up".

## What did not land (queued for M3 and beyond)

- BLAKE3-truncated output-stream hash computation — M3-001.
- Parent-child linkage with shell's ShellCommandRecord via
  audit_id — M3-002.
- R49-PREP-007 kernel-side ordinal split (UEJ_KIND_TOOL_OUTPUT +
  EXIT into audit_journal_broker.pdx and uej_kind_valid) — paideia-os
  substrate task, not per-repo work.
- Exponential backoff (scaled per retry_count) — deferred to R21+
  when sys_clock_gettime and sched_yield primitives are available.
