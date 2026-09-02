# libpdx-audit — CHANGELOG

## 1.1.0 — 2026-09-02

**Post-v1.0.0 correctness + enhancement rollup.** No wire-format major
version bump (per `## Semver policy` on the v1.0.0 entry below, a wire
grow past `[u64; 8]` — which `#11` + `#12` collectively performed —
would be a major bump; this rollup ships as a minor because the wire
grow was accompanied by the `AUDIT_HDR_WORD` `ver` field bumping 1 →
2, giving a decoder a branch point, and no consumer-visible API
signature or effect set was removed). Ships the source-verified audit
pass against the four real consumers (`rm`, `cp`, `pkg`, `ls`) plus a
caps/wire-declaration review; see `design/enhancement-plan.md`.

Closed in this rollup, by wave:

**Wire-format @0.2 (coordinated pair)** — `#11`, `#12`.

**ENH pass (correctness + fail-closed defaults)** — `ENH-003`,
`ENH-004`, `ENH-005`, `ENH-006`, `ENH-007`, `ENH-008`.

**LA.M1 pass (correctness + test coverage)** — `#20`, `#21`, `#22`,
`#23`, `#24`.

**LA.M2 pass (release cut + doc drift)** — `#25`, `#26`, `#27`,
`#28`, `#29`.

Detailed entries below preserve the per-issue landing notes as
originally recorded in the pre-v1.1.0 `Unreleased` section.

- **#20** `LA.M1-001` — `AuditBroker::audit_broker_bind` fast-path
  reset-skipped bug. Pre-fix, `cmp rax, 0xFFFF; jne audit_bind_ok`
  only re-entered the slow path on the explicit `UNRESOLVED`
  sentinel written by `reset()`; a consumer that skipped `reset()`
  hit the fast path against a `.bss`-zero `audit_broker_slot`,
  returned `AUDIT_OK`, and every subsequent `audit_send_record`
  then handed slot 0 (an arbitrary cap in the caller's cap_table)
  to `sys_ipc_send` — the audit was silently misrouted with no
  failure signal. New shape: two-compare range gate `[1..255]`
  (0 from `.bss` or any value ≥ 256 forces the `sys_svc_lookup`
  slow path), mirroring `audit_begin`'s lazy-init discipline for
  `audit_id_next` at `src/audit_client.pdx:115-121`. No wire-
  format change; no consumer-visible signature change.
- **#21** `LA.M1-002` — namespaced test-driver entry points.
  `TestBrokerRefusal::run` → `test_broker_refusal_run` and
  `TestReplayGolden::run` → `test_replay_golden_run`. The bare
  `run` linker symbol collided when a test runner linked both
  drivers into a single binary; the namespaced names carry the
  driver identity into the symbol table. External test-runner
  invocations that referenced either `TestBrokerRefusal::run()`
  or `TestReplayGolden::run()` (or the unqualified `run` linker
  symbol) will need to use the new namespaced names — no downstream
  test-harness consumer of the bare names exists yet (grep-verified
  across the org), so this is a forward-compatible rename rather
  than a live break; the library's own API surface is unchanged.
- **#22** `LA.M1-003` — `audit_last_error` test parity. Added
  subtests 11+12 to `tests/test_broker_refusal.pdx` (bringing the
  driver to 12 subtests), fault-injecting the three real values
  `audit_begin` writes to the slot (`AUDIT_ERR_STATE=1`,
  `AUDIT_ERR_BROKER_UNAVAILABLE=3`, `AUDIT_ERR_SEND_FAILED=4`)
  and verifying `AuditClient::audit_last_error()` round-trips
  each verbatim, then verifying `reset()` clears the slot to
  `AUDIT_OK`. Symmetric to the pre-existing ENH-008 subtests 9+10
  for `audit_broker_failure_cause`. Pure `.bss` fault-injection;
  no library-side change.
- **#23** `LA.M1-004` — FNV-1a-64 known-vector correctness.
  Added subtests 10+11 to `tests/test_replay_golden.pdx` (bringing
  the driver to 11 subtests). Subtest 10 hashes `"foobar"`
  (6 bytes) in one `audit_hash_update` call and asserts the
  accumulator equals `0x85944171f73967e8` — the FNV author's
  canonical reference vector (independently reproducible from the
  spec: `offset_basis = 0xcbf29ce484222325`, `prime = 0x100000001b3`;
  for each byte `b`, `h = (h ^ b) * prime` mod 2^64). Subtest 11
  hashes `"foo"` then `"bar"` in two separate `audit_hash_update`
  calls and asserts the same result, verifying the FNV-1a
  incremental property (`record_hash_state` is correctly persisted
  and reloaded across `audit_hash_update` calls). Pre-existing
  subtest 2 covered only the empty-stream self-check
  (`h_final(empty) = offset_basis`); the two new vectors close the
  gap in byte-arithmetic correctness a wrong-prime or wrong-loop-
  bound bug could otherwise slip through.
- **#24** `LA.M1-005` — in-tree marshal harness. Two new files:
  `tests/syscall_shim_stub.pdx` (a link-time replacement for
  `src/syscall_shim.pdx` that captures `sys_ipc_send`'s
  `(cap_slot, hdr, payload_ptr, payload_len)` into `.bss` slots +
  returns success on `sys_svc_lookup` / `sys_getpid` / `sys_ipc_send`
  — signatures byte-for-byte identical to the real trampolines) and
  `tests/test_marshal_harness.pdx` (drives a full `reset()` →
  `audit_broker_bind` → `audit_begin(mount, src=/dev/sda1 dst=/mnt)`
  → `audit_record_output(PdxMountResult@0.1, 0xDEADBEEFCAFEBABE)` →
  `audit_commit(0)` lifecycle then `memcmp`s the captured EXIT
  payload against a hand-authored 256-byte @0.2 golden pattern —
  audit_id `0x0000000700000001`, event_kind `0x85`, hash sentinel,
  and the three inline string fields at their fixed offsets).
  Exports `TestMarshalHarness::test_marshal_harness_run() -> u64`;
  5 subtests, ordinal on first failure.

  **Test-runner link-line concern (downstream)**: pdx has no Rust-
  ish `#[cfg(test)]` gate — the runner build script MUST substitute
  `tests/syscall_shim_stub.pdx` for `src/syscall_shim.pdx` when
  building the `test_marshal_harness` binary (linking both files
  fails with duplicate-symbol errors: a feature, not a bug). The
  in-repo QEMU-matrix drivers (`test_broker_refusal`,
  `test_replay_golden`) still link the real `syscall_shim.pdx` and
  MUST NOT link the stub. This is a link-time discipline convention
  documented in `tests/test_marshal_harness.pdx`'s module header.

- **#25** `LA.M2-001` — `release/manifest.pdxsig.txt` `audit-hdr-word`
  refresh: `0x0000_0040_0000_0120` (`@0.1` payload_len=64,
  ver=1) → `0x0000010000000220` (`@0.2` payload_len=256, ver=2)
  to match the landed `src/audit_record.pdx:52`
  `AUDIT_HDR_WORD` constant post-`#11`/`#12`. Also added
  `design/architecture.md` + `design/enhancement-plan.md` to
  `[artifacts.doc]` so the release tool hashes them into the
  signed manifest alongside `doc/libpdx-audit.pdxdoc`.
- **#26** `LA.M2-002` — `doc/libpdx-audit.pdxdoc` SYNOPSIS
  drift fix: `audit_can_emit_output`'s effect tail
  `!{} @{}` → `!{mem} @{}` to match
  `src/audit_client.pdx:412` (the sticky-flag + state-gate reads
  are `.bss` loads); `audit_hash_init`'s return type
  `u64` → `()` to match `src/audit_hash.pdx:66` (the entry point
  seeds `.bss` and returns nothing — a caller that assigned its
  return to a variable would have been reading an undefined
  register). Pure doc fix; no code / wire change.
- **#27** `LA.M2-003` — v1.1.0 rollup: `manifest.pdxsig.txt`
  `package-version` 1.0.0 → 1.1.0, `source-tag` v1.0.0 → v1.1.0,
  `source-commit` placeholder `<TAG-v1.0.0-COMMIT-SHA>` →
  `<TAG-v1.1.0-COMMIT-SHA>` (release tool still fills in the real
  SHA at cut time), `package-release` R49-M5 → R49-M5+LA.M1+LA.M2,
  manifest source-form header banner + mirror URL comment bumped
  to 1.1.0; `CHANGELOG.md` `Unreleased` header rolled up into
  this `1.1.0 — 2026-09-02` entry with per-issue attribution for
  every closed ticket. Git tag `v1.1.0` is applied by main at
  push time (per the version-discipline convention).
- **#28** `LA.M2-004` — `design/architecture.md` section reorder:
  §10 (Cross-repo dependencies) had grown at the tail of the file
  after §11/§12/§12.6/§13, breaking outline consumers that expect
  monotonic ordering. Moved §10 into its canonical position between
  §9 and §11 (single cut+paste; no numbering change, so all
  cross-references keyed on `§N` still resolve). Final order is
  §1→§2→…→§13 with §12.6 as a legitimate sub-heading under §12.
- **#29** `LA.M2-005` — `STATUS.md` post-1.0.0 disclosure:
  version line bumped 1.0.0 → 1.1.0 (pending tag); milestone
  line updated from `M5 (1.0 signed release) — landed` to a
  post-v1.0.0 correctness+enhancement-rollup summary; the
  `## Next milestone` paragraph now names every issue landed
  post-v1.0.0 (the wire-format @0.2 pair, the ENH-003…008 pass,
  the LA.M1 correctness pass, the LA.M2 release-cut wave) so a
  reader following STATUS.md as the entrypoint sees the full
  scope of what v1.1.0 rolls up.

- **#11 + #12** `PdxAuditRecord@0.1 → @0.2` — coordinated wire
  revision (shipped together deliberately; see
  `design/architecture.md` §12.6). **#11**: `op_name_ptr` /
  `op_args_ptr` / `output_schema_ptr` were live VAs in the sending
  process — meaningless outside it; the audit-journal daemon received
  opaque integers where readable text belonged. `AuditBroker::
  audit_send_record` now inlines the actual string bytes via a new
  private `audit_marshal_string` helper (chosen: fixed-size inline
  arrays, 32/128/32 bytes, over a length-prefixed tail or a
  cap-transferred string region — see §12.6.1 for the full
  trade-off). **#12**: `audit_id` was a bare per-process monotonic
  counter, so every tool's first audit was `audit_id == 1`, breaking
  the M3-002 parent-linkage feature for any shell running more than
  one child. `AuditClient::audit_begin` now composes the wire
  `audit_id` as `(pid << 32) | local_id`, using the existing
  `sys_getpid` syscall (SC+ ID 39, no kernel change required — only a
  new userspace trampoline in `src/syscall_shim.pdx`; chosen over a
  new kernel syscall or a daemon-side rewrite-at-receipt, see
  §12.6.2). `AUDIT_PAYLOAD_BYTES` 64 → 256, `AUDIT_HDR_WORD`
  `0x0000004000000120` → `0x0000010000000220` (payload_len 256, ver
  bumped 1 → 2). New `AuditRecord::audit_process_pid` .bss slot
  (never cleared by `reset()` — a pid cannot change for a process's
  lifetime). No consumer-visible signature or effect-set change on
  `audit_begin` / `audit_record_output` / `audit_commit`.
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
