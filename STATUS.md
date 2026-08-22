# libpdx-audit — status

**Wave:** R49 shared library
**Current milestone:** M2 (core implementation) — landed

## Milestone progress

- M1-001 — scaffold + three-call API (audit_begin, audit_record_output,
  audit_commit): landed. State-machine gating + record-shape storage;
  audit_commit stops after the state transition (no send yet).
- M1-002 — audit_id allocation + svc.audit-journal broker binding:
  landed. Broker bound via sys_svc_lookup (SC+ ID 43) with slot cached
  in AuditRecord::audit_broker_slot; audit_commit now delegates to
  AuditBroker::audit_send_committed_record which marshals the 56-byte
  wire payload + invokes sys_ipc_send (SC+ ID 42). audit_id_next
  handed out monotonically starting at 1.
- M2-001 — record shape matches UEJ_KIND_TOOL_INVOKE/OUTPUT/EXIT:
  landed. AuditBroker::audit_send_committed_record superseded by
  AuditBroker::audit_send_record(event_kind); three lifecycle sends
  now occur per audit (INVOKE at begin, OUTPUT at record_output,
  EXIT at commit). audit_begin + audit_record_output effects widened
  to !{mem, sysreg} @{cap, sched}. UEJ_KIND_TOOL_OUTPUT (132) and
  EXIT (133) forward-declared pending R49-PREP-007 kernel-side
  ordinal split.
- M2-002 — failure semantics: broker unreachable → tool refuses
  output (exit 3): landed. Sticky AuditRecord::audit_broker_failed
  slot set to 1 on any audit_send_record failure (bind or send).
  New AuditClient::audit_can_emit_output() -> u64 helper reads the
  slot; returns 1 when safe, 0 when the consumer must exit 3 per I4
  without emitting output. reset() clears the flag.
- M2-003 — retry-with-backoff (bounded 3 retries then hard-fail):
  landed. audit_send_record wraps sys_ipc_send in a retry-on-EAGAIN
  loop; r13 counts attempts (0..3), with a fixed 4096-cycle spin
  backoff between attempts. Only SYS_IPC_SEND_ERR_EAGAIN (1) triggers
  retry; every other non-zero return (BAD_ID / PAYLOAD_LEN / EFAULT
  / CHANDEAD) hard-fails immediately. Exhausted retries fall through
  to the M2-002 sticky-flag + AUDIT_ERR_SEND_FAILED epilogue.

## Upstream design

`design/tooling/r49-r50-plan.md` §3.4 + §5.13 in the
[paideia-os](https://github.com/paideia-os/paideia-os) repo carries the
wave-level rationale and the full milestone breakdown. See
`design/architecture.md` in this repo for the internal shape.

## Next milestone

M3 — Semantic-pipe / audit integration. BLAKE3-truncated output-stream
hash computation (M3-001); parent-child linkage with shell's
ShellCommandRecord via audit_id (M3-002). Depends on shell.M2 and
libpdx-semantic-pipe.M2 per plan.md §5.13.
