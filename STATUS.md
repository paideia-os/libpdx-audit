# libpdx-audit — status

**Wave:** R49 shared library
**Current milestone:** M1 (design + skeleton) — in progress

## Milestone progress

- M1-001 — scaffold + three-call API (audit_begin, audit_record_output,
  audit_commit): landed. State-machine gating + record-shape storage;
  audit_commit stops after the state transition (no send yet).
- M1-002 — audit_id allocation + svc.audit-journal broker binding:
  not yet started.

## Upstream design

`design/tooling/r49-r50-plan.md` §3.4 + §5.13 in the
[paideia-os](https://github.com/paideia-os/paideia-os) repo carries the
wave-level rationale and the full milestone breakdown. See
`design/architecture.md` in this repo for the internal shape.
