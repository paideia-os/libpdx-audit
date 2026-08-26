# libpdx-audit

paideia-os shared library: audit-first output — every operation journals
to the `svc.audit-journal` broker (whose daemon persists the stream under
`/system/audit/user-events/`) before any user-visible byte leaves the tool.

## Purpose

The D3 audit-first contract says a tool whose output was not journalled
is a tool whose output the operator cannot trust. Every R49/R50 tool
therefore opens exactly one top-level audit at `_start`, records what it
is about to emit, and commits the audit before `sys_exit` — and refuses
to emit anything if the audit path failed (`exit 3`, I4 system-error).
libpdx-audit is the one implementation of that discipline, so the wire
format, the state machine, and the failure semantics are a single edit
rather than per-tool code.

Concretely, the library does **not** write files. It resolves the
well-known service name `"svc.audit-journal"` to an IPC endpoint
capability via `sys_svc_lookup` (SC+ ID 43), then publishes a fixed
64-byte record over that endpoint with `sys_ipc_send` (SC+ ID 42) at
each of three lifecycle points — INVOKE, OUTPUT, EXIT. Materialising
that stream as journal entries under `/system/audit/user-events/` is the
audit-journal daemon's job; at v1.0.0 the kernel-side dispatch is still
a stub (`audit_journal_broker_dispatch` returns `AJB_DISPATCH_STUB`), so
the transport is live but the persistence layer is not yet.

All state lives in one `.bss`-resident `AuditRecord` singleton: one
audit in flight per process, zero heap dependency, and the broker cap
slot cached across every commit in the process.

## API surface

Signatures are copied from source. `!{…}` is the effect set, `@{…}` the
capability set, both as declared on the `pub let`.

### `src/audit_client.pdx` — `AuditClient` (the consumer-facing API)

| Signature | Purpose |
|---|---|
| `audit_begin(op_name, op_args) -> u64 !{mem, sysreg} @{cap, sched}` | Open an audit. Requires `record_state == IDLE`; allocates a monotonic `audit_id`, stores the two NUL-terminated string pointers, transitions IDLE → BEGUN, and emits `UEJ_KIND_TOOL_INVOKE`. Returns the id (> 0) or **0** on state-gate failure *or* send failure — **this is a bare 0 sentinel, not negative-errno**; do not `cmp rax, 0; jl` against it (always false). Call `audit_last_error()` after a 0 return to tell the two failure causes apart. |
| `audit_last_error() -> u64 !{mem} @{}` | Post-1.0.0 (ENH-006). The real cause of the most recent `audit_begin`: `AUDIT_OK` on success or before any call, `AUDIT_ERR_STATE` on the IDLE-gate branch, or the verbatim `AUDIT_ERR_BROKER_UNAVAILABLE` / `AUDIT_ERR_SEND_FAILED` from a failed INVOKE send. |
| `audit_broker_failure_cause() -> u64 !{mem} @{}` | Post-1.0.0 (ENH-008). Diagnostic-only companion to `audit_can_emit_output`: tells a bind failure (`AUDIT_ERR_BROKER_UNAVAILABLE`) apart from a send failure (`AUDIT_ERR_SEND_FAILED`) once the sticky `audit_broker_failed` flag is set. `AUDIT_OK` before any failure. Sticky-forever policy: only `reset()` clears it — this is diagnosis, not a recovery primitive. See `design/architecture.md` §7.2. |
| `audit_record_output(audit_id, output_schema, output_hash) -> u64 !{mem, sysreg} @{cap, sched}` | Declare the schema-typed output about to be emitted. Gates on state == BEGUN then on id match, transitions BEGUN → OUTPUT, emits `UEJ_KIND_TOOL_OUTPUT`. Optional: a tool with no schema-typed output may go straight to commit. |
| `audit_commit(audit_id, exit_code) -> u64 !{mem, sysreg} @{cap, sched}` | Close the audit. Legal from BEGUN or OUTPUT; stores `exit_code`, transitions to COMMITTED, emits `UEJ_KIND_TOOL_EXIT`, and on success resets state to IDLE so a later `audit_begin` starts fresh. On failure state stays COMMITTED for post-mortem. |
| `audit_can_emit_output() -> u64 !{mem} @{}` | The D3 output gate: returns `1` only when the sticky `audit_broker_failed` flag is clear **and** an audit is actually open (`record_state` is `BEGUN` or `OUTPUT`); returns `0` — caller must `exit 3` emitting nothing — otherwise, including when no audit was ever begun or one already committed (post-1.0.0 fail-closed fix, ENH-005). |
| `audit_set_parent(parent_audit_id) -> u64 !{mem} @{}` | Set the parent linkage before `audit_begin`. Gated on state == IDLE (`AUDIT_ERR_STATE` otherwise) — parent id is part of the audit's identity, not mutable mid-flight. `0` means top-level. |

### `src/audit_hash.pdx` — `AuditHash` (streaming output digest)

| Signature | Purpose |
|---|---|
| `audit_hash_init() -> () !{mem} @{}` | Seed `record_hash_state` with `FNV_OFFSET_BASIS` and set `record_hash_active = 1`. Idempotent; a re-init resets to the empty-stream state. |
| `audit_hash_update(ptr, len) -> u64 !{mem} @{}` | Fold `len` bytes at `ptr` into the accumulator, one FNV-1a step per byte (`state = (state ^ byte) * FNV_PRIME`). `len == 0` is a legal no-op. Returns `AUDIT_ERR_HASH_INACTIVE` if `audit_hash_init` was never called. |
| `audit_hash_finalize() -> u64 !{mem} @{}` | Return the accumulated hash and clear `record_hash_active` (single-use, matching `Hasher::finalize`). Returns `0` if inactive — deliberately not an error code, since `audit_record_output` takes a plain `u64`. |

The primitive is **FNV-1a-64, a documented placeholder** for the
BLAKE3-truncated hash the upstream plan specifies; BLAKE3 is not yet a
paideia-as intrinsic. The swap changes only the two loop bodies — the
signatures, the `.bss` slot, and the truncate-to-`u64` semantics are
identical either way.

### `src/audit_broker.pdx` — `AuditBroker` (binding + marshalling)

| Signature | Purpose |
|---|---|
| `audit_broker_bind() -> u64 !{mem, sysreg} @{cap}` | Idempotent bind of `svc.audit-journal`. Fast path returns `AUDIT_OK` when the cached slot is not `AUDIT_BROKER_SLOT_UNRESOLVED`; slow path calls `sys_svc_lookup` and accepts the result only when `< 256` (every negative-errno sentinel has bit 63 set, so `cmp rax, 256; jae` discriminates). |
| `audit_send_record(event_kind) -> u64 !{mem, sysreg} @{cap, sched}` | Marshal the eight-`u64` payload from the singleton, write the packed IPC header, and `sys_ipc_send`. Bounded retry: up to 3 retries on `SYS_IPC_SEND_ERR_EAGAIN` (1) with a 4096-cycle spin backoff; every other non-zero return hard-fails with no retry. Both failure epilogues set the sticky `audit_broker_failed` flag. |

Also exported: `audit_broker_name : [u8; 20] = "svc.audit-journal\0\0\0"`
and `AUDIT_BROKER_NAME_LEN : u64 = 17`, byte-for-byte the kernel-side
declaration.

### `src/audit_record.pdx` — `AuditRecord` (state, constants, storage)

`reset() -> () !{mem} @{}` — bootstrap init, called **once** per process
(not between audits: `audit_id_next` must stay monotonic across a
process). Zeroes the in-progress slots, then seeds `audit_id_next = 1`
and `audit_broker_slot = 0xFFFF`.

`audit_rearm() -> () !{mem} @{}` — post-1.0.0 (ENH-004). Clears exactly
the per-audit content slots a prior `audit_record_output` /
`audit_commit` may have populated (`record_exit_code`,
`record_output_schema_ptr`, `record_output_hash`) without touching
`audit_id_next`, `audit_broker_slot`, `audit_broker_failed`, or
`record_parent_audit_id`. `audit_begin` now calls this automatically
right after its IDLE gate passes, so a second audit in one process no
longer inherits the first audit's stale exit code / schema pointer /
output hash into its own INVOKE payload.

Exported constants:

- Error codes — `AUDIT_OK` 0, `AUDIT_ERR_STATE` 1,
  `AUDIT_ERR_ID_MISMATCH` 2, `AUDIT_ERR_BROKER_UNAVAILABLE` 3,
  `AUDIT_ERR_SEND_FAILED` 4, `AUDIT_ERR_HASH_INACTIVE` 5.
- States — `AUDIT_STATE_IDLE` 0, `BEGUN` 1, `OUTPUT` 2, `COMMITTED` 3.
- Wire — `AUDIT_PAYLOAD_BYTES` 64, `AUDIT_HDR_WORD` `0x0000004000000120`.
- Event kinds — `UEJ_KIND_TOOL_INVOKE` 130, `UEJ_KIND_TOOL_OUTPUT` 132,
  `UEJ_KIND_TOOL_EXIT` 133.
- Sentinels/primitives — `AUDIT_BROKER_SLOT_UNRESOLVED` `0xFFFF`,
  `FNV_OFFSET_BASIS`, `FNV_PRIME`.

Storage (all `pub let mut … : u64 = uninit @align(8)`, relying on `.bss`
zeroing): `audit_id_next`, `record_audit_id`, `record_op_name_ptr`,
`record_op_args_ptr`, `record_output_schema_ptr`, `record_output_hash`,
`record_exit_code`, `record_state`, `audit_broker_slot`,
`record_parent_audit_id`, `audit_broker_failed`, `record_hash_state`,
`record_hash_active`, `audit_last_error` (ENH-006),
`audit_broker_failure_cause` (ENH-008), plus the send scratch
`audit_payload_scratch : [u64; 8]` and `audit_hdr_scratch : u64`.

### `src/syscall_shim.pdx` — `SyscallShim`

| Signature | Purpose |
|---|---|
| `sys_svc_lookup(name_ptr, name_len) -> u64 !{mem, sysreg} @{cap}` | SC+ ID 43 trampoline. Resolves a broker name to a fresh `KIND_IPC_ENDPOINT` cap slot in `[0..255]`, or a negative-errno sentinel. |
| `sys_ipc_send(cap_slot, user_hdr_va, user_payload_va, payload_len) -> u64 !{mem, sysreg} @{cap, sched}` | SC+ ID 42 trampoline. Non-blocking send; arity 4 so it performs the SysV → SYSCALL `rcx → r10` shuffle. |

## Schemas exposed

`caps.decl` declares one output schema: **`PdxAuditRecord@0.1`**. Its
on-wire form is the fixed 64-byte payload `audit_send_record` marshals —
eight `u64` words, identical for all three lifecycle events, with only
`event_kind` varying:

| # | Offset | Field | Source slot | Meaning |
|---|---|---|---|---|
| 0 | 0  | `audit_id` | `record_audit_id` | monotonic per-process id, allocated from 1; `0` is the "no audit" sentinel |
| 1 | 8  | `event_kind` | argument | 130 INVOKE / 132 OUTPUT / 133 EXIT |
| 2 | 16 | `exit_code` | `record_exit_code` | written by `audit_commit`; `0` before it |
| 3 | 24 | `op_name_ptr` | `record_op_name_ptr` | live pointer to a caller-owned NUL-terminated string |
| 4 | 32 | `op_args_ptr` | `record_op_args_ptr` | live pointer, caller-owned; may be `0` |
| 5 | 40 | `output_schema_ptr` | `record_output_schema_ptr` | live pointer to the schema name; `0` until `audit_record_output` |
| 6 | 48 | `output_hash` | `record_output_hash` | truncated output digest (FNV-1a-64 today) |
| 7 | 56 | `parent_audit_id` | `record_parent_audit_id` | `0` iff top-level; else the parent's `audit_id` |

The IPC frame header is one packed `u64`, `AUDIT_HDR_WORD =
0x0000_0040_0000_0120` — op `0x20` (AUDIT_EVENT), ver 1,
`reply_endpoint_id` 0 (fire-and-forget), `payload_len` 64.

Two properties worth stating plainly, because they surprise readers who
expect a self-describing log line:

- **The record carries pointers, not bytes.** Fields 3, 4 and 5 are live
  virtual addresses into caller-owned memory. libpdx-audit never copies
  or mutates those strings, so the consumer must keep the backing pages
  alive from `audit_begin` through `audit_commit` (the lifetime of one
  tool invocation, so this is the default).
- **There is no timestamp and no actor field.** Neither appears anywhere
  in the source wire format. Both are the journal daemon's to stamp on
  receipt; consumers that need their own timing keep it in their own
  record (the shell's `ShellCommandRecord` carries `ts_begin_ns` /
  `ts_end_ns` itself).

Wire stability at v1.0.0: any grow past `[u64; 8]`, error-code
renumber, or state-machine change is a major bump. See
[`CHANGELOG.md`](CHANGELOG.md) § *Semver policy*.

## Callers

**Verified** — these repos contain `.pdx` source that calls this
library's entry points by name:

- [`cp`](https://github.com/paideia-os/cp) — `src/audit.pdx` (`CpAudit`)
  wraps `audit_begin` / `audit_commit` around `dispatch_copy`; begin
  fires before any `Print::print_err`.
- [`rm`](https://github.com/paideia-os/rm) — `src/audit.pdx` (`RmAudit`)
  uses all three: `audit_begin`, then `audit_record_output` per removal
  target with `RmSchema::SCHEMA_LABEL`, then `audit_commit`.
- [`pkg`](https://github.com/paideia-os/pkg) — `src/audit_wire.pdx`
  (`AuditWire`) factors the invoke/output/exit sequence out of all five
  subcommands and exits 3 when `audit_begin` returns 0.

**Declared but not yet linked:**

- [`mv`](https://github.com/paideia-os/mv) — `deps.list` pins
  `libpdx-audit 1.0.0` for `src/audit.pdx`, but that module's header
  states it redeclares the `sys_ipc_send` / `sys_svc_lookup`
  trampolines locally to stay self-contained at M3-002; the switch to
  this library is scheduled, not landed.
- [`shell`](https://github.com/paideia-os/shell) —
  `src/command_record.pdx` encodes `ShellCommandRecord` around an
  `audit_id` "issued by libpdx-audit's `audit_begin`" and documents the
  `audit_commit` pairing, but M3-003 ships the buffer encoders only;
  the call pair is an explicit substrate deferral to M4+.

No caller yet exercises `audit_set_parent` or `audit_can_emit_output`;
both exist ahead of the consumers that need them (shell parenting, and
the M4 strict-gating pass in `cp`/`rm`).

## Version

**v1.0.0** — tagged 2026-08-22 at the R49 wave close (M5-001), all
milestones M1–M5 landed. Per-milestone rollup, the wire-format contract,
the semver policy, and the four known deferred substrates (BLAKE3
intrinsic, QEMU end-to-end smoke, the `pkgs.paideia-os` mirror, the
`doc` M2 compile pass) are in [`CHANGELOG.md`](CHANGELOG.md).

`main` carries three post-tag commits — `tools/build.sh` plus two
paideia-as conformance build fixes (a `mov_b` SIB-scale form and a
missing statement terminator). No signature, effect, or wire-format
change since the tag.

Further reading: [`design/architecture.md`](design/architecture.md)
(state machine, storage model, primitive-swap policy),
[`doc/libpdx-audit.pdxdoc`](doc/libpdx-audit.pdxdoc) (the `doc
libpdx-audit` man page, source form),
[`tests/README.md`](tests/README.md) (harness protocol and the pending
QEMU matrix), [`caps.decl`](caps.decl) (capability requirement:
`KIND_IPC_ENDPOINT(write, svc.audit-journal) via svc_lookup`).

## Examples

Minimal lifecycle — a tool with no schema-typed output:

```
AuditRecord::reset()                              // once, at _start
let id = AuditClient::audit_begin(&"rm\0", op_args_ptr)
if id == 0 { sys_exit(3) }                        // I4: no output, ever
… tool does its work …
let e = AuditClient::audit_commit(id, exit_code)
if e != AuditRecord::AUDIT_OK { sys_exit(3) }
```

Hashing a streamed output and declaring its schema:

```
AuditHash::audit_hash_init()
… emit chunk1 … AuditHash::audit_hash_update(chunk1_ptr, chunk1_len)
… emit chunk2 … AuditHash::audit_hash_update(chunk2_ptr, chunk2_len)
let h = AuditHash::audit_hash_finalize()
let e = AuditClient::audit_record_output(id, &"PdxFsDirEntry@0.1\0", h)
if e != AuditRecord::AUDIT_OK { sys_exit(3) }
```

The D3 output gate, checked before every user-visible write:

```
if AuditClient::audit_can_emit_output() == 0 {
    sys_exit(3)                                   // refuse un-journalled output
}
… tool emits stdout …
```

A shell-spawned child linking itself into the parent's audit tree —
`audit_set_parent` must precede `audit_begin`, since the IDLE gate
refuses it once an audit is open:

```
AuditRecord::reset()
AuditClient::audit_set_parent(parent_id)          // 0 iff top-level
let id = AuditClient::audit_begin(&"ls\0", &"--long /home\0")
```

## License

MIT — see [`LICENSE`](LICENSE).
