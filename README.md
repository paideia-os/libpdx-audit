# libpdx-audit

paideia-os shared library: audit-first output (every operation emits to
`/system/audit/user-events/` before any user-visible bytes leave the
tool).

## Status

**v1.0.0 — R49 wave close (M5-001).** All milestones M1..M5 landed. See
[`CHANGELOG.md`](CHANGELOG.md) for the per-milestone rollup, [`design/
architecture.md`](design/architecture.md) for the repo-internal shape,
and [`release/RELEASE.md`](release/RELEASE.md) for the dual-sign +
mirror-push runbook.

See `design/tooling/r49-r50-plan.md` §3.4 + §5.13 in the [paideia-os
](https://github.com/paideia-os/paideia-os) repo for the wave-level
rationale and the full milestone breakdown.

## Documentation

- [`doc/libpdx-audit.pdxdoc`](doc/libpdx-audit.pdxdoc) — the man-
  equivalent, rendered by `doc libpdx-audit` (source form; compiled
  form ships alongside the library at doc.M2 landing).
- [`design/architecture.md`](design/architecture.md) — internal shape,
  state machine, wire format, primitive swap policy.
- [`tests/README.md`](tests/README.md) — test harness protocol and
  the QEMU smoke matrix pending shell.M4 + a bootstrap consumer +
  R49-PREP-007.

## License

MIT — see [`LICENSE`](LICENSE).
