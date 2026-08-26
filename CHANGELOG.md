# libpdx-audit — CHANGELOG

## Unreleased (post-v1.0.0 enhancement pass)

Source-verified audit pass against the four real consumers (`rm`,
`cp`, `pkg`, `ls`) plus a caps/wire-declaration review; see
`design/enhancement-plan.md`. Entries below track individual
`ENH-*` issues as they land; a version bump + CHANGELOG rollup happens
at the next formal release cut.

- **ENH-007** `caps.decl` refresh — wire schema was still described as
  the M1 56-byte stub; now states the landed 64-byte / eight-u64-word
  `PdxAuditRecord@0.1` shape and adds an explicit `wire_ownership`
  block naming `AUDIT_HDR_WORD` framing as mandatory for any producer
  on `svc.audit-journal`.
- **ENH-005** `audit_can_emit_output` now fails closed by default:
  requires `audit_broker_failed == 0` AND `record_state IN {BEGUN,
  OUTPUT}`, not just the sticky flag. A process that never opened an
  audit (or already committed one) previously read "safe" via `.bss`
  zero-init.
- **ENH-006** `audit_begin`'s bare `0`-on-failure sentinel conflated a
  state-gate violation with a broker/send failure, and does not follow
  this org's negative-errno idiom (`ls`'s consumer-side check got this
  backwards — see the issue). New `AuditRecord::audit_last_error` slot
  + `AuditClient::audit_last_error()` accessor exposes the real cause
  (`AUDIT_ERR_STATE` vs. `AUDIT_ERR_BROKER_UNAVAILABLE` /
  `AUDIT_ERR_SEND_FAILED`) after a 0 return, without changing
  `audit_begin`'s wire-stable return convention. README + pdxdoc now
  carry an explicit caution against the negative-errno idiom here.
- **ENH-004** new `AuditRecord::audit_rearm()`, called automatically
  from `audit_begin` right after its IDLE gate passes. Fixes a
  second audit in one long-lived process (the shell's per-command
  loop is the motivating case) inheriting the FIRST audit's stale
  `record_exit_code` / `record_output_schema_ptr` / `record_output_
  hash` into its own INVOKE payload — `audit_begin` only ever
  overwrote `record_audit_id` / `record_op_name_ptr` /
  `record_op_args_ptr` / `record_state`. `audit_id_next`,
  `audit_broker_slot`, `audit_broker_failed`, and
  `record_parent_audit_id` are deliberately left untouched.
- **ENH-008** sticky-failure recovery policy, decided explicitly:
  `audit_broker_failed` stays sticky-forever until `reset()` — no
  new recovery primitive, since a per-audit clear would let a tool
  route around a failed journal send and defeat D3. New
  `AuditRecord::audit_broker_failure_cause` slot + `AuditClient::
  audit_broker_failure_cause()` diagnostic accessor distinguishes
  `AUDIT_ERR_BROKER_UNAVAILABLE` (bind never resolved) from
  `AUDIT_ERR_SEND_FAILED` (bind ok, send failed) once the sticky
  flag is set. See `design/architecture.md` §7.2.
- **ENH-003** `audit_record_output` is now re-entrant from `OUTPUT`
  (gate widened from `BEGUN`-only to `BEGUN || OUTPUT`, mirroring
  `audit_commit`'s existing dual-state gate). Through v1.0.0 a second
  call on one open audit hard-failed with `AUDIT_ERR_STATE` — a real
  gap for `rm`, whose `RmAudit::audit_record_target` journals every
  successful removal target from two call sites, so `rm a b c` only
  ever recorded target `a`. Purely additive: no wire-format change,
  no new error code. Not covered by a runnable test driver — like
  every other syscall-touching entry point in this repo, verified by
  code review only (see `design/enhancement-plan.md` §1.2).

## v1.0.0 — 2026-08-22 (R49 wave close, M5-001)

**First release.** Signed with the paideia-release-line hybrid
Ed25519 + ML-DSA-65 key pair per
`design/02-development-environment.md` §1140 (paideia-os). Ships
`.pdxdoc` for `doc libpdx-audit` and mirrors to
`https://pkgs.paideia-os/main/libpdx-audit/1.0.0/` per
`release/RELEASE.md`.

### Landed

- **M1-001** scaffold + three-call API (`audit_begin`,
  `audit_record_output`, `audit_commit`). State-machine gating +
  record-shape storage.
- **M1-002** `audit_id` allocation + `svc.audit-journal` broker binding
  via `sys_svc_lookup` (SC+ ID 43); `AuditBroker::audit_send_committed_
  record` marshals the wire payload + invokes `sys_ipc_send` (SC+ ID
  42); monotonic id allocation from 1.
- **M2-001** record shape matches `UEJ_KIND_TOOL_INVOKE=130` /
  `UEJ_KIND_TOOL_OUTPUT=132` / `UEJ_KIND_TOOL_EXIT=133`; three
  discriminable events per audit lifecycle via
  `AuditBroker::audit_send_record(event_kind)`.
- **M2-002** failure semantics: sticky `audit_broker_failed` flag on
  any send failure; new `AuditClient::audit_can_emit_output` guard;
  caller MUST exit 3 (I4 system-error) without emitting output.
- **M2-003** retry-with-backoff — bounded 3 retries on
  `SYS_IPC_SEND_ERR_EAGAIN` with a 4096-cycle spin backoff; every
  other non-zero return hard-fails immediately.
- **M3-001** streaming output-stream hash (FNV-1a-64 placeholder for
  BLAKE3-truncated). New `AuditHash` module — init/update/finalize.
  API surface stable across the eventual BLAKE3 primitive swap.
- **M3-002** parent-child linkage via `record_parent_audit_id` +
  `audit_set_parent`. Wire format grew 56 → 64 bytes; header word
  `0x0000_0040_0000_0120`. Consumers that never call `audit_set_
  parent` get parent = 0 (top-level) via `.bss` zero-init.
- **M4-001** broker-unavailable refusal test driver
  (`tests/test_broker_refusal.pdx`).
- **M4-002** audit-journal replay correctness driver +
  byte-for-byte fixture (`tests/test_replay_golden.pdx`,
  `tests/goldens/trace_001.md`).
- **M5-001** dual-signed release + `.pdxdoc` + mirror push. Ships
  `doc/libpdx-audit.pdxdoc` source form, `release/manifest.pdxsig.
  txt` release-manifest source, `release/RELEASE.md` operator
  runbook. Signed build + mirror push runs when substrates S1
  (paideia-as v0.33-crypto-kdf) and S2 (pkgs.paideia-os endpoint)
  go green per `release/RELEASE.md` §1.

### Known deferred substrate

- **BLAKE3 stdlib intrinsic.** M3-001 ships FNV-1a-64 as a
  documented placeholder; the swap to BLAKE3-truncated changes
  only the internal primitive, not the API surface.
- **QEMU end-to-end smoke.** The M4 drivers cover every
  library-observable invariant. The full spawn-under-QEMU +
  audit-endpoint payload capture + memcmp against
  `tests/goldens/trace_001.md` runs when shell.M4 + a bootstrap
  consumer + R49-PREP-007 (`audit_journal_broker_dispatch`
  daemon body) all land. See `tests/README.md` §QEMU smoke
  protocol.
- **pkgs.paideia-os mirror endpoint.** The mirror does not exist
  at R49 close. The signed `manifest.pdxsig` still lands in the
  v1.0.0 GitHub release attachment set for out-of-band consumers
  until the mirror stands.
- **`doc` M2 compile pass.** The `.pdxdoc` compiled binary form
  ships once doc.M2 lands. Until then consumers render the
  source form verbatim — the format is human-readable text.

### Wire-format contract at v1.0.0

    IPC header word     = 0x0000_0040_0000_0120
    Payload length      = 64 bytes (8 u64 words)
    Payload layout      = [audit_id, event_kind, exit_code,
                           op_name_ptr, op_args_ptr,
                           output_schema_ptr, output_hash,
                           parent_audit_id]
    Event kinds         = UEJ_KIND_TOOL_INVOKE (130)
                          UEJ_KIND_TOOL_OUTPUT (132)
                          UEJ_KIND_TOOL_EXIT   (133)

The wire format is a stable v1 contract. Any grow past 64 bytes
requires a package major version bump.

### Semver policy

- **Major** — wire-format grow beyond `[u64; 8]`, error-code
  renumber, state-machine graph change, or any API-surface removal.
- **Minor** — additive API surface (new `AuditClient::*` entry
  points, new `AuditHash::*` primitives), additive wire-format
  slots via a new `payload_len` header word.
- **Patch** — correctness fixes, primitive swap (FNV-1a-64 →
  BLAKE3-truncated), retry-loop constant tuning.
