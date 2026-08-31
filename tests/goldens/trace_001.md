# tests/goldens/trace_001.md — libpdx-audit M4-002 golden trace

**Milestone:** M4-002 — audit-journal replay correctness against a
known trace.

**Wire format:** `PdxAuditRecord@0.2` (libpdx-audit#11 + #12 — see
`design/architecture.md` §12.6 for the full rationale). Supersedes the
`@0.1` fixture this file previously documented.

**Purpose.** Byte-for-byte fixture the QEMU smoke matrix will compare
against `AuditRecord::audit_payload_scratch` after each of the three
lifecycle sends (INVOKE / OUTPUT / EXIT) for a canonical audit. The
in-repo `test_replay_golden.pdx` driver covers the invariants that
hold before the marshal runs (state machine, hash primitive, parent
propagation into the .bss slot); this file specifies the exact wire
bytes those .bss slots must produce.

Both agree on the same source of truth: `design/architecture.md` §2
(historical M3-002 wire format), §12.6 (current `@0.2` wire format),
and `src/audit_broker.pdx`'s `audit_send_record` marshalling
sequence + `audit_marshal_string` helper.

---

## Canonical trace

The trace is a single audit representing the invocation

    /bin/ls --long /home

by a shell-child running as user `founder`. The shell process has
**pid 3** and is on its 42nd command in the session (local counter
`0x2A`); the child (`ls`) process has been freshly spawned with
**pid 7** and this is its first audit (local counter `0x01`).

Per §12.6's `#12` fix, every wire `audit_id` is now
`(pid << 32) | local_id`, not the bare local counter:

- Shell's own `ShellCommandRecord` audit_id:
  `(3 << 32) | 0x2A` = **`0x000000030000002a`**
- Child's own audit_id:
  `(7 << 32) | 0x01` = **`0x0000000700000001`**

Note that both processes' LOCAL counters could easily collide (a
freshly-spawned child's first audit is always local counter 1, exactly
like every other process's first audit) — it is the pid component that
makes the two wire values above distinct. This is the concrete
scenario `#12` fixes: under `@0.1`, the child's wire audit_id would
have been the bare local counter `0x0000000000000001`, indistinguishable
from every OTHER process's first audit.

### Client-side setup (what the test harness executes)

```
AuditRecord::reset()
AuditClient::audit_set_parent(0x000000030000002a)    // shell's composed id
let id = AuditClient::audit_begin(
             op_name = &"ls\0",                       // 3 bytes at addr LS_NAME
             op_args = &"--long /home\0")              // 13 bytes at addr LS_ARGS
// id = 0x0000000700000001 (pid 7, first audit in this process).
// audit_begin internally: lazy-fetches audit_process_pid via
// sys_getpid() -> 7 (cached for the rest of the process), allocates
// local_id = 1 from audit_id_next, composes (7 << 32) | 1.

// tool streams its PdxFsDirEntry[] rows; hashes them:
AuditHash::audit_hash_init()
… update() calls with the rendered rows …
let h = AuditHash::audit_hash_finalize()              // = HASH_LS

let e = AuditClient::audit_record_output(
            audit_id = 0x0000000700000001,
            output_schema = &"PdxFsDirEntry@0.1\0",   // 18 bytes at addr LS_SCHEMA
            output_hash = HASH_LS)

… tool emits stdout …
AuditClient::audit_commit(audit_id = 0x0000000700000001, exit_code = 0)
```

Unlike `@0.1`, `op_name` / `op_args` / `output_schema` are no longer
symbolic VA placeholders in the tables below — `#11`'s fix is exactly
that `AuditBroker::audit_marshal_string` now copies the bytes
themselves into the wire payload, so the QEMU harness (running in the
broker's own address space, with no access to the sender's memory) can
decode them as plain text. `HASH_LS` remains symbolic since
`output_hash` depends on the runtime-rendered directory contents.

### Wire header (identical across all three sends)

    AUDIT_HDR_WORD (@0.2) = 0x0000_0100_0000_0220

Bit-level layout (little-endian u64):

| bits    | field              | value          |
|---------|--------------------|----------------|
| [0..7]  | `op`               | 0x20  (AUDIT_EVENT) |
| [8..15] | `ver`              | 2  (bumped from 1 at `@0.2`) |
| [16..31]| `reply_endpoint_id`| 0  (fire-and-forget) |
| [32..47]| `payload_len`      | 256  (0x100 — `@0.2` grew from 0x40) |
| [48..63]| *reserved*         | 0              |

Any header byte deviating from these values fails the M4-002
replay assertion.

---

## Wire payload — INVOKE send (from `audit_begin`)

`@0.2` hybrid layout: 256 bytes total — five numeric `u64` words,
three inline NUL-terminated string fields, 24 reserved bytes.

| offset | width | field              | value                                          |
|-------:|------:|--------------------|-------------------------------------------------|
|      0 |     8 | `audit_id`         | `0x0000000700000001`  (pid 7 << 32 \| local_id 1) |
|      8 |     8 | `event_kind`       | `0x0000000000000082`  (UEJ_KIND_TOOL_INVOKE = 130) |
|     16 |     8 | `exit_code`        | `0x0000000000000000`  (uninitialised at INVOKE) |
|     24 |     8 | `parent_audit_id`  | `0x000000030000002a`  (shell pid 3 << 32 \| local_id 42) |
|     32 |     8 | `output_hash`      | `0x0000000000000000`  (uninitialised at INVOKE) |
|     40 |    32 | `op_name`          | `"ls\0"` + 29 zero bytes |
|     72 |   128 | `op_args`          | `"--long /home\0"` + 115 zero bytes |
|    200 |    32 | `output_schema`    | 32 zero bytes  (`record_output_schema_ptr` is still `0` at INVOKE — `audit_marshal_string`'s `src_ptr == 0` path yields an all-zero field) |
|    232 |    24 | *reserved*         | 24 zero bytes |

`op_name` and `op_args` are already inlined at INVOKE because both are
`audit_begin`'s constructor arguments — `record_op_name_ptr` /
`record_op_args_ptr` are populated before the INVOKE send fires, so
these two fields are identical across all three lifecycle sends.
`output_schema` is the only string field that changes shape between
INVOKE and OUTPUT — it is `0` (all-zero field) until
`audit_record_output` populates `record_output_schema_ptr`.

---

## Wire payload — OUTPUT send (from `audit_record_output`)

| offset | width | field              | value                                          |
|-------:|------:|--------------------|-------------------------------------------------|
|      0 |     8 | `audit_id`         | `0x0000000700000001` |
|      8 |     8 | `event_kind`       | `0x0000000000000084`  (UEJ_KIND_TOOL_OUTPUT = 132) |
|     16 |     8 | `exit_code`        | `0x0000000000000000`  (still uninitialised) |
|     24 |     8 | `parent_audit_id`  | `0x000000030000002a` |
|     32 |     8 | `output_hash`      | `<HASH_LS>` |
|     40 |    32 | `op_name`          | `"ls\0"` + 29 zero bytes |
|     72 |   128 | `op_args`          | `"--long /home\0"` + 115 zero bytes |
|    200 |    32 | `output_schema`    | `"PdxFsDirEntry@0.1\0"` + 14 zero bytes |
|    232 |    24 | *reserved*         | 24 zero bytes |

`<HASH_LS>` is FNV-1a-64 of the rendered PdxFsDirEntry[] byte stream.
The QEMU harness computes it from its own render output before
memcmp — it is not a fixed constant because the directory contents
vary. What is asserted here is that the value marshalled at offset 32
equals whatever `audit_hash_finalize` returned, byte-for-byte.

---

## Wire payload — EXIT send (from `audit_commit`)

| offset | width | field              | value                                          |
|-------:|------:|--------------------|-------------------------------------------------|
|      0 |     8 | `audit_id`         | `0x0000000700000001` |
|      8 |     8 | `event_kind`       | `0x0000000000000085`  (UEJ_KIND_TOOL_EXIT = 133) |
|     16 |     8 | `exit_code`        | `0x0000000000000000`  (`ls` succeeded) |
|     24 |     8 | `parent_audit_id`  | `0x000000030000002a` |
|     32 |     8 | `output_hash`      | `<HASH_LS>` |
|     40 |    32 | `op_name`          | `"ls\0"` + 29 zero bytes |
|     72 |   128 | `op_args`          | `"--long /home\0"` + 115 zero bytes |
|    200 |    32 | `output_schema`    | `"PdxFsDirEntry@0.1\0"` + 14 zero bytes |
|    232 |    24 | *reserved*         | 24 zero bytes |

Only `event_kind` (offset 8) and `exit_code` (offset 16) change
between OUTPUT and EXIT — every other field is stable across the two
sends. A supervisor replaying the three-send stream can therefore
detect an out-of-order send by watching offset 8 transition
`130 → 132 → 133` and no other order.

---

## Field-decoding notes (`#11`)

- Every string field is copied byte-for-byte by
  `AuditBroker::audit_marshal_string`: up to `width - 1` source bytes
  (stopping early at the source's own NUL), then zero-padding through
  the end of the field — the field's LAST byte is always zero, so
  truncation (a source string ≥ the field width) still yields a
  NUL-terminated field rather than a decode hazard.
- A `0` source pointer (legal for `op_args` before it is set, and for
  `output_schema` before `OUTPUT`) produces an all-zero field — this
  is indistinguishable on the wire from an explicit empty string.
  Consumers that need to tell "never set" from "explicitly empty"
  apart must do so above this layer (out of scope for `@0.2`).
- The 24 reserved bytes at offset 232 are always zero. No `@0.2` code
  path writes them; a future `@0.3` revision that adds a field there
  would be the first to give them meaning.

---

## Failure-path fixture (M4-001 companion)

For the M4-001 broker-refusal QEMU protocol, the harness runs the
same setup against a QEMU image with **no** `svc.audit-journal`
broker registered. Expected observable behaviour:

- `AuditClient::audit_begin` returns `0` (its state/send-failure
  sentinel).
- `AuditClient::audit_can_emit_output` returns `0`.
- The child tool exits `3` (per I4 system-error convention).
- The child tool emits ZERO bytes to stdout (no partial output).

No wire bytes are expected on the audit-journal endpoint — the send
never happens because bind fails first, and even if bind somehow
succeeded, the sticky-flag write in `asr_bind_fail` gates further
progress. This is unaffected by `@0.2` — `sys_getpid`'s pid-fetch in
`audit_begin` happens before the bind attempt and always succeeds (it
takes no arguments and consumes no capability), so the failure path is
identical to `@0.1`.

---

## When to update this fixture

- **Wire-format changes.** Any change to `AUDIT_PAYLOAD_BYTES`,
  `AUDIT_HDR_WORD`, or the payload field ordering/offsets updates
  every row and the header layout in tandem. The associated code
  change is in `src/audit_broker.pdx`'s `audit_send_record` marshal
  sequence plus `AuditRecord::AUDIT_PAYLOAD_BYTES` +
  `AuditRecord::AUDIT_HDR_WORD` + the `AUDIT_OFF_*` / `AUDIT_*_BYTES`
  offset/width constants.
- **New lifecycle event.** A new `UEJ_KIND_TOOL_*` ordinal
  (e.g. `UEJ_KIND_TOOL_ELEVATE` if libpdx-elevate's post-M3 work
  wants a linked event) adds a fourth section to this file with
  the same layout.
- **Kernel-side schema lock.** When `R49-PREP-007` lands the
  audit_journal_broker daemon body, the kernel-side event schema
  becomes the source of truth; this fixture then becomes a
  cross-check rather than a spec, and any drift between them is
  a bug that fails M4-002. The daemon body must decode against the
  `@0.2` layout in `design/architecture.md` §12.6.3, not the
  historical `@0.1` layout in §2.
