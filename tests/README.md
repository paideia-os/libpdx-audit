# tests/

Empty at M1 by design. The audit round-trip matrix — begin/record/commit
happy path, broker-unavailable refusal, backoff correctness (3 retries),
parent-child linkage against a shell trace, and audit-journal replay
against a known trace — lands with `libpdx-audit.M4-001` and
`libpdx-audit.M4-002` per `design/tooling/r49-r50-plan.md` §5.13 in
paideia-os.

The M1 first-runnable proof of the three-call API described in
`design/architecture.md` §1 is carried by the consumer tool (`pkg`,
`shell`, or a small `examples/` binary added alongside M2), not by
this test tree.
