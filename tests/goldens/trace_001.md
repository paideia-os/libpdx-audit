# tests/goldens/trace_001.md — libpdx-audit M4-002 golden trace

**Milestone:** M4-002 — audit-journal replay correctness against a
known trace.

**Purpose.** Byte-for-byte fixture the QEMU smoke matrix will compare
against `AuditRecord::audit_payload_scratch` after each of the three
lifecycle sends (INVOKE / OUTPUT / EXIT) for a canonical audit. The
in-repo `test_replay_golden.pdx` driver covers the invariants that
hold before the marshal runs (state machine, hash primitive, parent
propagation into the .bss slot); this file specifies the exact wire
bytes those .bss slots must produce.

Both agree on the same source of truth: `design/architecture.md` §2
(wire format), §12.3 (M3-002 grow to 64 bytes), and
`src/audit_broker.pdx`'s `audit_send_record` marshalling loop.

---

## Canonical trace

The trace is a single audit representing the invocation

    /bin/ls --long /home

by a shell-child running as user `founder`, whose shell command
record's `audit_id` is `0x000000000000_002a` (42 decimal — the shell
is on its 42nd command in the session). The child's own audit_id is
`0x0000000000000001` (first audit in the child's own process).

### Client-side setup (what the test harness executes)

```
AuditRecord::reset()
AuditClient::audit_set_parent(0x000000000000002a)     // 42
let id = AuditClient::audit_begin(
             op_name = &"ls\0",                       // 3 bytes at addr LS_NAME
             op_args = &"--long /home\0")             // 13 bytes at addr LS_ARGS
// id = 1 (first audit in this process, per audit_id_next lazy-init).

// tool streams its PdxFsDirEntry[] rows; hashes them:
AuditHash::audit_hash_init()
… update() calls with the rendered rows …
let h = AuditHash::audit_hash_finalize()              // = HASH_LS

let e = AuditClient::audit_record_output(
            audit_id = 1,
            output_schema = &"PdxFsDirEntry@0.1\0",   // 18 bytes at addr LS_SCHEMA
            output_hash = HASH_LS)

… tool emits stdout …
AuditClient::audit_commit(audit_id = 1, exit_code = 0)
```

The op_name / op_args / output_schema pointers are consumer-owned;
their exact virtual addresses depend on the linker layout and are
therefore captured as *symbolic placeholders* in the byte tables
below (`<LS_NAME_VA>` etc.). The QEMU harness resolves them from
its own linker map before running memcmp.

### Wire header (identical across all three sends)

    AUDIT_HDR_WORD (M3-002) = 0x0000_0040_0000_0120

Bit-level layout (little-endian u64):

| bits    | field              | value          |
|---------|--------------------|----------------|
| [0..7]  | `op`               | 0x20  (AUDIT_EVENT) |
| [8..15] | `ver`              | 1              |
| [16..31]| `reply_endpoint_id`| 0  (fire-and-forget) |
| [32..47]| `payload_len`      | 64  (0x40 — M3-002 grew from 0x38) |
| [48..63]| *reserved*         | 0              |

Any header byte deviating from these values fails the M4-002
replay assertion.

---

## Wire payload — INVOKE send (from `audit_begin`)

Eight u64 little-endian words. Total 64 bytes.

| idx | slot                        | value                          |
|-----|-----------------------------|--------------------------------|
| [0] | `record_audit_id`           | `0x0000000000000001`           |
| [1] | `event_kind`                | `0x0000000000000082`  (UEJ_KIND_TOOL_INVOKE = 130) |
| [2] | `record_exit_code`          | `0x0000000000000000`  (uninitialised at INVOKE) |
| [3] | `record_op_name_ptr`        | `<LS_NAME_VA>`                 |
| [4] | `record_op_args_ptr`        | `<LS_ARGS_VA>`                 |
| [5] | `record_output_schema_ptr`  | `0x0000000000000000`  (uninitialised at INVOKE) |
| [6] | `record_output_hash`        | `0x0000000000000000`  (uninitialised at INVOKE) |
| [7] | `record_parent_audit_id`    | `0x000000000000002a`  (42; from audit_set_parent) |

---

## Wire payload — OUTPUT send (from `audit_record_output`)

| idx | slot                        | value                          |
|-----|-----------------------------|--------------------------------|
| [0] | `record_audit_id`           | `0x0000000000000001`           |
| [1] | `event_kind`                | `0x0000000000000084`  (UEJ_KIND_TOOL_OUTPUT = 132) |
| [2] | `record_exit_code`          | `0x0000000000000000`  (still uninitialised) |
| [3] | `record_op_name_ptr`        | `<LS_NAME_VA>`                 |
| [4] | `record_op_args_ptr`        | `<LS_ARGS_VA>`                 |
| [5] | `record_output_schema_ptr`  | `<LS_SCHEMA_VA>`               |
| [6] | `record_output_hash`        | `<HASH_LS>`                    |
| [7] | `record_parent_audit_id`    | `0x000000000000002a`           |

`<HASH_LS>` is FNV-1a-64 of the rendered PdxFsDirEntry[] byte stream.
The QEMU harness computes it from its own render output before
memcmp — it is not a fixed constant because the directory contents
vary. What is asserted here is that the value marshalled at index [6]
equals whatever `audit_hash_finalize` returned, byte-for-byte.

---

## Wire payload — EXIT send (from `audit_commit`)

| idx | slot                        | value                          |
|-----|-----------------------------|--------------------------------|
| [0] | `record_audit_id`           | `0x0000000000000001`           |
| [1] | `event_kind`                | `0x0000000000000085`  (UEJ_KIND_TOOL_EXIT = 133) |
| [2] | `record_exit_code`          | `0x0000000000000000`  (`ls` succeeded) |
| [3] | `record_op_name_ptr`        | `<LS_NAME_VA>`                 |
| [4] | `record_op_args_ptr`        | `<LS_ARGS_VA>`                 |
| [5] | `record_output_schema_ptr`  | `<LS_SCHEMA_VA>`               |
| [6] | `record_output_hash`        | `<HASH_LS>`                    |
| [7] | `record_parent_audit_id`    | `0x000000000000002a`           |

Only `event_kind` (index [1]) and `exit_code` (index [2]) change
between OUTPUT and EXIT — every other slot is stable across the two
sends. A supervisor replaying the three-send stream can therefore
detect an out-of-order send by watching index [1] transition
`130 → 132 → 133` and no other order.

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
progress.

---

## When to update this fixture

- **Wire-format changes.** Any change to `AUDIT_PAYLOAD_BYTES`,
  `AUDIT_HDR_WORD`, or the payload slot ordering updates every
  `[N]` row and the header layout in tandem. The associated code
  change is in `src/audit_broker.pdx`'s `audit_send_record` marshal
  loop plus `AuditRecord::AUDIT_PAYLOAD_BYTES` + `AUDIT_HDR_WORD`.
- **New lifecycle event.** A new `UEJ_KIND_TOOL_*` ordinal
  (e.g. `UEJ_KIND_TOOL_ELEVATE` if libpdx-elevate's post-M3 work
  wants a linked event) adds a fourth section to this file with
  the same eight-slot layout.
- **Kernel-side schema lock.** When `R49-PREP-007` lands the
  audit_journal_broker daemon body, the kernel-side event schema
  becomes the source of truth; this fixture then becomes a
  cross-check rather than a spec, and any drift between them is
  a bug that fails M4-002.
