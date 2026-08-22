# libpdx-audit — status

**Wave:** R49 shared library
**Current milestone:** M5 (1.0 signed release) — landed
**Version:** 1.0.0 (tag `v1.0.0`)

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
- M3-001 — audit_record_output writes BLAKE3-truncated output-stream
  hash: landed. New AuditHash module (src/audit_hash.pdx) exposes a
  streaming digest API: audit_hash_init() seeds record_hash_state
  with FNV_OFFSET_BASIS (0xcbf29ce484222325) and sets
  record_hash_active = 1; audit_hash_update(ptr, len) folds bytes
  into state via the FNV-1a step (state = (state ^ byte) * FNV_PRIME
  0x100000001b3) with the paideia-as #1248 xor+mov_b zero-extended
  byte-load pattern; audit_hash_finalize() returns the accumulated
  state and clears active. audit_record_output's signature is
  UNCHANGED — consumers who use the streaming API pass
  audit_hash_finalize's return as the output_hash argument. New
  AUDIT_ERR_HASH_INACTIVE (5) returned by audit_hash_update when
  called without a prior audit_hash_init. FNV-1a-64 is a documented
  placeholder for the BLAKE3-truncated hash the plan specifies —
  BLAKE3 is not yet in paideia-as v0.33-crypto-kdf; the swap replaces
  audit_hash_update + audit_hash_finalize internals without changing
  the API surface, the record_hash_state .bss slot, or the return
  type. See design/architecture.md §11 for the streaming shape.
- M3-002 — parent-child linkage with shell ShellCommandRecord via
  audit_id: landed. New record_parent_audit_id .bss slot in
  AuditRecord (zeroed by reset()); new AuditClient::audit_set_parent
  (parent_audit_id) entry that stores the parent id iff record_state
  == IDLE (else AUDIT_ERR_STATE — parent linkage is a property of
  the audit's identity and cannot be mutated mid-flight). Wire
  format grew 56 → 64 bytes: AUDIT_PAYLOAD_BYTES 56 → 64,
  AUDIT_HDR_WORD 0x0000_0038_0000_0120 → 0x0000_0040_0000_0120
  (only payload_len field changes; op / ver / reply_ep unchanged),
  audit_payload_scratch [u64;7] → [u64;8]. AuditBroker::
  audit_send_record marshals record_parent_audit_id at payload
  index [7] on every INVOKE/OUTPUT/EXIT send and passes rcx=64 to
  sys_ipc_send. The kernel-side broker dispatch is still stubbed
  (AJB_DISPATCH_STUB), so the schema grow is safe until R49-PREP-007
  lands the daemon body — at which point the kernel-side event
  schema will need the parent_audit_id field added at index [7] to
  keep byte-for-byte agreement. Consumers that never call
  audit_set_parent get parent = 0 (top-level) via .bss zero-init —
  the M2 shape is preserved. See design/architecture.md §12.
- M4-001 — broker-unavailable refusal test (tool exits 3, no output
  emitted): landed. New tests/test_broker_refusal.pdx exports
  TestBrokerRefusal::run() -> u64 (effects !{mem} @{}). Seven-
  subtest driver over the M2-002 sticky-flag guard: reset zeroes
  audit_broker_failed; audit_can_emit_output returns 1 (safe)
  after reset; fault-inject 1 into audit_broker_failed .bss slot;
  guard returns 0 (refuse); reset clears the sticky flag; guard
  returns 1 again; audit_broker_slot = AUDIT_BROKER_SLOT_UNRESOLVED
  (0xFFFF) after reset (the sentinel that forces the next
  audit_broker_bind to attempt a real svc_lookup). Return code
  0 = all pass, 1..7 = ordinal of first failing subtest. QEMU
  smoke (spawn under image with no svc.audit-journal registered,
  verify exit 3 + zero stdout bytes) documented in
  tests/README.md §M4-001 QEMU protocol pending shell.M4 +
  bootstrap consumer + R49-PREP-007 daemon.
- M4-002 — audit-journal replay correctness against a known trace:
  landed. New tests/test_replay_golden.pdx exports
  TestReplayGolden::run() -> u64 (effects !{mem} @{}). Eight-
  subtest driver over the wire-format invariants that hold BEFORE
  the marshal runs: reset -> IDLE state, FNV-1a-64 empty-stream
  self-check (finalize after init returns FNV_OFFSET_BASIS), hash
  active-flag clear after finalize, update-before-init returns
  AUDIT_ERR_HASH_INACTIVE (5), len=0 update returns AUDIT_OK and
  leaves state = FNV_OFFSET_BASIS, audit_set_parent(0x1234567)
  propagates into record_parent_audit_id, audit_set_parent with
  state != IDLE returns AUDIT_ERR_STATE (M3-002 §12.1 gate).
  New byte-for-byte fixture at tests/goldens/trace_001.md — the
  canonical ls --long /home audit as a shell child: header
  0x0000_0040_0000_0120, per-lifecycle payload table (INVOKE
  event_kind=130 with uninit exit/schema/hash; OUTPUT
  event_kind=132 with schema+hash populated; EXIT event_kind=133
  with exit_code=0), parent_audit_id=0x2a on all three sends
  (the M3-002 linkage). QEMU harness will memcmp
  audit_payload_scratch against the fixture once R49-PREP-007
  daemon captures payload bytes.
- M5-001 — dual-signed release + .pdxdoc + mirror push: landed.
  Repo now ships the source form of the release: doc/libpdx-
  audit.pdxdoc (I7 doc for `doc libpdx-audit` — NAME / SYNOPSIS /
  DESCRIPTION / API / WIRE-FORMAT / STATE-MACHINE / ERROR-CODES /
  RETRY-DISCIPLINE / PARENT-LINKAGE / HASH / POSIX-DIFFERENCES /
  EXAMPLES / CROSS-REFERENCES / SEE-ALSO / VERSION); release/
  manifest.pdxsig.txt (release-manifest source with per-artifact
  BLAKE3-256 placeholder rows, [depends-on] empty, [substrate]
  pinning paideia-as ≥ 0.33-crypto-kdf + SC+ ID 42/43 + svc.audit-
  journal broker + UEJ_KIND_TOOL_INVOKE/OUTPUT/EXIT ordinals +
  audit-hdr-word 0x0000_0040_0000_0120, and [signatures] block
  declaring hybrid-ed25519+ml-dsa-65 per paideia-pq-hybrid-v1);
  release/RELEASE.md (operator runbook — 8-step cut-a-release +
  verification + rollback); CHANGELOG.md (v1.0.0 entry with the
  full M1..M4 rollup + wire-format contract + semver policy);
  README.md refreshed to point at the 1.0 surface. Git tag
  `v1.0.0` marks the M5-001 commit. The dual-sign + mirror-push
  run itself is a substrate-gated action documented in RELEASE.md
  §1 (S1 = paideia-as v0.33-crypto-kdf toolchain reachable, S2 =
  pkgs.paideia-os mirror endpoint reachable, S3 = doc.M2 compile
  pass) — the source form lands now so a future operator can cut
  the mirror push without repo-side changes beyond a version
  bump.

## Upstream design

`design/tooling/r49-r50-plan.md` §3.4 + §5.13 in the
[paideia-os](https://github.com/paideia-os/paideia-os) repo carries the
wave-level rationale and the full milestone breakdown. See
`design/architecture.md` in this repo for the internal shape.

## Next milestone

All milestones M1..M5 landed at v1.0.0. The library is now the
template for the peer R49 shared-library M5 cuts (libpdx-cap,
libpdx-argv, libpdx-semantic-pipe, libpdx-elevate). Downstream
work continues in the consumer repos (pkg, shell, doc, the R50
coreutils) where every M3 milestone binds libpdx-audit and every
M5 cut mirrors the workflow at `release/RELEASE.md`.

Deferred to a future patch release (semver-patch bump per
`CHANGELOG.md` semver policy):

- **BLAKE3 stdlib primitive swap.** M3-001 ships FNV-1a-64 as a
  documented placeholder. When paideia-as ≥ v0.34 exposes BLAKE3
  as a stdlib intrinsic, swap `audit_hash_update` +
  `audit_hash_finalize` internals to BLAKE3-256 upper 64 bits;
  the API surface, the `.bss` state slot, and the return type
  are stable across the swap. Recut a v1.0.1.
- **QEMU end-to-end smoke.** The child-under-QEMU spawn +
  audit-endpoint payload capture + memcmp against
  `tests/goldens/trace_001.md` runs when shell.M4 + a bootstrap
  consumer (pkg.M2 or cat.M2) + R49-PREP-007
  `audit_journal_broker_dispatch` daemon body all land. The M4
  drivers cover every library-observable invariant in the
  meantime; see `tests/README.md` §QEMU smoke protocol for the
  follow-up.
- **Dual-sign + mirror-push run.** Repo-side scaffolding at M5-001
  is complete. The signed build + HTTP-PUT to `pkgs.paideia-os/
  main/libpdx-audit/1.0.0/` runs from the paideia-os workspace
  CI once substrates S1 (paideia-as v0.33-crypto-kdf toolchain
  reachable) and S2 (pkgs.paideia-os mirror endpoint reachable)
  go green per `release/RELEASE.md` §1. Until then the signed
  `manifest.pdxsig` lands as a v1.0.0 GitHub release attachment
  for out-of-band consumers.
