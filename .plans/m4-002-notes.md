# libpdx-audit.M4-002 — implementation notes

**Issue:** #9 — audit-journal replay correctness against known trace.
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.13 (paideia-os).

## What landed

- `tests/test_replay_golden.pdx` — new `TestReplayGolden` module.
  Single public entry point `run() -> u64` (effects `!{mem} @{}`)
  covering eight subtests over the wire-format contract:
  1. `reset()` → `record_state = IDLE (0)`.
  2. FNV-1a-64 empty-stream self-check: `audit_hash_init()` then
     `audit_hash_finalize()` with no updates between returns
     `FNV_OFFSET_BASIS = 0xcbf29ce484222325`.
  3. `finalize` clears `record_hash_active` to 0.
  4. `audit_hash_update` before any `init` returns
     `AUDIT_ERR_HASH_INACTIVE (5)` — defence-in-depth gate.
  5. `init` then `update(ptr, 0)` returns `AUDIT_OK (0)` —
     len=0 is a legal no-op.
  6. len=0 no-op leaves `record_hash_state = FNV_OFFSET_BASIS`
     (the accumulator was not touched).
  7. `audit_set_parent(0x1234567)` with IDLE state returns
     `AUDIT_OK` and writes 0x1234567 into
     `record_parent_audit_id`.
  8. `audit_set_parent` with state != IDLE (fault-inject
     `record_state = BEGUN`) returns `AUDIT_ERR_STATE (1)` —
     parent linkage cannot be mutated mid-flight per
     `design/architecture.md` §12.1.
- Local `.bss` slot `trg_null_scratch : u8` — a 1-byte scratch
  buffer for the len=0 no-op and inactive-gate subtests. Kept
  aligned to 8 so `mov_b` byte loads (should any future subtest
  fold a byte) work without alignment concerns.
- `tests/goldens/trace_001.md` — new fixture. Documents the
  byte-for-byte 64-byte payload the QEMU harness will memcmp
  against `audit_payload_scratch` after each of the three
  lifecycle sends (INVOKE / OUTPUT / EXIT). Includes:
  - The header layout (`AUDIT_HDR_WORD = 0x0000004000000120`
    with per-field breakdown).
  - Per-send payload tables (indices [0..7], values or symbolic
    placeholders for consumer-owned pointers).
  - A canonical trace: `/bin/ls --long /home` invoked by a shell
    at command 42, child on its first audit, parent_audit_id =
    0x2a.
  - The M4-001 failure-path fixture (shared with the broker-
    refusal test): child exits 3, emits 0 bytes.
  - An update-and-maintenance section pointing at the code
    changes that require a fixture refresh (payload_len change,
    new UEJ_KIND ordinal, kernel-side schema lock at
    R49-PREP-007).
- `tests/README.md` — updated (see also M4-001 notes).
- `STATUS.md` — M4-002 marked landed.

## Design decisions

- **Split the M4-002 contract in two: library-observable subtests
  in code + wire-bytes fixture in markdown.** The wire-format
  contract has two failure modes: (a) library never populates the
  right AuditRecord slots before marshalling, or (b) marshalling
  writes the wrong bytes into `audit_payload_scratch`. (a) is
  library-observable — the .bss slots visible on entry to
  `audit_send_record` determine every byte the marshal loop
  writes. (b) is a QEMU-only assertion because the marshal loop
  runs INSIDE `audit_send_record`, right before `sys_ipc_send`,
  and short-circuiting the syscall to inspect the scratch after
  marshalling requires either a debug endpoint or a
  test-only marshal helper. The former is a QEMU concern; the
  latter would leak test scaffolding into production. The split
  covers (a) in code and treats (b) as a spec + QEMU-time
  assertion.
- **Empty-stream self-check for FNV-1a-64.** The canonical FNV
  spec defines `h_final(empty) = FNV_OFFSET_BASIS`. This is a
  known-vector test that requires no byte-level FNV arithmetic
  to verify — the constant is documented in `AuditRecord::
  FNV_OFFSET_BASIS` and referenced identically in the test. When
  BLAKE3 lands as a paideia-as intrinsic (post-v0.33), this
  subtest changes constant (BLAKE3 has its own IV / state
  initialisation) but the shape stays: init → finalize → equals
  the empty-stream digest. See `design/architecture.md` §11.1
  for the primitive swap rationale.
- **Fault-inject `record_state = BEGUN` for subtest 8.** The
  natural way to reach BEGUN is via `audit_begin`, but
  `audit_begin` calls `sys_ipc_send` (INVOKE). A direct .bss
  write bypasses the syscall and reaches the same observable
  state (`record_state = 1`) — which is what `audit_set_parent`'s
  gate actually reads. This is exactly parallel to the M4-001
  fault-inject of `audit_broker_failed = 1`.
- **0x1234567 and 0x89ABCDE as parent-id sentinels.** Distinct,
  memorable 25-bit patterns well below the `cmp reg, imm`
  0x7FFFFFFF bound (so no MOVABS needed for the .bss compare).
  Chosen to be visually distinct from the ordinals and status
  codes so a log line reading `record_parent_audit_id ==
  0x1234567` is unambiguously the M4-002 fixture, not an
  accidental match against 42 (the shell-command id in
  `trace_001.md` — 0x2a).
- **Stage FNV_OFFSET_BASIS in r13 once.** The constant is used
  in two `cmp` sites (subtests 2 and 6). Loading it once via
  MOVABS into r13 and reusing across both compares (`cmp rax,
  r13`) saves 12 bytes of code vs. two MOVABS + two immediate
  compares (a MOVABS is 10 bytes; reg-to-reg cmp is 3). r13 is
  SysV callee-save so subsequent `call reset` / `call
  audit_hash_*` preserve it.
- **Placeholder `<HASH_LS>` in the golden.** The output-stream
  hash depends on the rendered `PdxFsDirEntry[]` bytes, which
  vary with the actual `/home` directory contents at test time.
  The golden captures the *shape* (index [6] holds whatever
  `audit_hash_finalize` returned) and the QEMU harness computes
  the reference value from its own render pass before memcmp.
  Any concrete hash value would either drift with directory
  contents or hardcode a specific QEMU root fs image — both
  brittle.

## paideia-as conformance

- No `test` mnemonic; every zero-check is `cmp reg, 0` /
  `cmp reg, 1` / `cmp reg, 5` / `cmp reg, 0x1234567` /
  reg-to-reg `cmp rax, r13`.
- Every immediate `cmp reg, imm` stays inside `0x7FFFFFFF`
  (max: 0x1234567 = 19 088 743, well below the bound).
  FNV_OFFSET_BASIS is 64-bit but loaded via MOVABS into r13
  before use — the compare is reg-to-reg, not cmp-with-imm64.
- `r11` used only as LEA scratch.
- Byte reads: none in the driver (subtest 4 passes rsi=8 into
  `audit_hash_update`, but the update returns HASH_INACTIVE
  before the byte load fires). All state is u64-wide.
- SysV push/pop parity: r12 + r13 pushed as a pair at the top;
  every return path pops both. rsp % 16 == 0 at every `call`
  (reset, audit_hash_init/update/finalize, audit_set_parent).
- Label prefix `trg_` (test-replay-golden). No bare
  `ok`/`fail`/`loop` labels — reserved-label discipline.

## Cross-module linkage

New references (all resolved by the paideia-as linker):

- Reads `record_state`, `record_hash_active`, `record_hash_state`,
  `record_parent_audit_id` (in `AuditRecord` .bss).
- Writes `record_state` (fault-injection subtest 8).
- Calls `reset` (in `AuditRecord`).
- Calls `audit_hash_init`, `audit_hash_update`, `audit_hash_finalize`
  (in `AuditHash`, M3-001).
- Calls `audit_set_parent` (in `AuditClient`, M3-002).

Zero new cross-repo dependencies. `trg_null_scratch` is
module-local — its symbol lives inside `TestReplayGolden`'s namespace
and does not appear in any other module's linkage set.

## What did not land (deferred)

- **Byte-for-byte marshal verification.** Requires a QEMU harness
  that can capture `audit_payload_scratch` after `audit_send_record`
  runs. Blocked on shell.M4 + a bootstrap consumer + R49-PREP-007
  daemon (see `tests/README.md` §M4-002 QEMU protocol). The fixture
  in `goldens/trace_001.md` documents the assertion for that future
  harness.
- **BLAKE3 primitive swap.** M3-001 uses FNV-1a-64 as a stated
  placeholder. The subtest 2 constant (`FNV_OFFSET_BASIS`) becomes
  the BLAKE3 empty-stream digest when the swap happens; the
  subtest structure is stable across the swap. See
  `design/architecture.md` §11.1.
- **Kernel-side schema lock cross-check.** When R49-PREP-007 lands
  the audit_journal_broker daemon body with a fixed event schema,
  the fixture in `goldens/trace_001.md` becomes a cross-check
  against the kernel-side schema declaration rather than a spec
  the library owns unilaterally. Any drift is a bug that M4-002
  should catch — a follow-up subtest could compare kernel-side
  event constants against the library-side `UEJ_KIND_TOOL_*` values
  once both sides are visible via a shared header.
