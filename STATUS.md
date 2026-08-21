# libpdx-audit — status

**Wave:** R49 shared library
**Current milestone:** M1 (design + skeleton) — landed

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

## Upstream design

`design/tooling/r49-r50-plan.md` §3.4 + §5.13 in the
[paideia-os](https://github.com/paideia-os/paideia-os) repo carries the
wave-level rationale and the full milestone breakdown. See
`design/architecture.md` in this repo for the internal shape.

## Next milestone

M2 — Core implementation. Splits the M1 stub event kind
(UEJ_KIND_TOOL_INVOKE for every commit) into
UEJ_KIND_TOOL_INVOKE / OUTPUT / EXIT per event; hardens the send
failure discipline (M2-002 broker-unreachable refusal, M2-003 bounded
retry-with-backoff). Depends on R49-PREP-007 (event-kind split on the
kernel-side broker).
