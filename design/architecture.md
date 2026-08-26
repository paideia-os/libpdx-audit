# libpdx-audit — architecture

**Wave:** R49 shared library
**Repo:** github.com/paideia-os/libpdx-audit
**Upstream design:** `design/tooling/r49-r50-plan.md` §3.4 and §5.13 in
[paideia-os](https://github.com/paideia-os/paideia-os).

This document describes the internal shape of libpdx-audit. It does not
repeat the wave-level rationale from the paideia-os plan doc; read that
first for the D3 audit-first contract (every operation — read as well as
write — journals before it emits any user-visible output) and for why
libpdx-audit is a shared library rather than per-tool code.

## 1. Public surface

libpdx-audit exposes three modules to its consumers:

- `AuditRecord` (`src/audit_record.pdx`) — the in-memory audit record
  every consumer walks via the client API. Error-code constants and
  state-machine constants live here so callers can distinguish
  "broker unreachable" from "id mismatch" without pattern-matching on
  messages.
- `AuditClient` (`src/audit_client.pdx`) — three entry points:
  `audit_begin(op_name, op_args) -> u64`,
  `audit_record_output(audit_id, output_schema, output_hash) -> u64`,
  `audit_commit(audit_id, exit_code) -> u64`.
- `AuditBroker` (`src/audit_broker.pdx`, M1-002) — one entry point
  `audit_broker_bind() -> u64` that resolves the `svc.audit-journal`
  name via `sys_svc_lookup` and caches the resulting cap slot for
  every subsequent `audit_commit` in the process.

The consumer wires libpdx-audit into its own tool as follows:

```
AuditRecord::reset()                       // bootstrap init
let id  = AuditClient::audit_begin(op_name, args)
… tool does its work …
let err = AuditClient::audit_record_output(id, schema, hash)
if err != AuditRecord::AUDIT_OK { … }
… tool emits output …
let err = AuditClient::audit_commit(id, exit_code)
if err != AuditRecord::AUDIT_OK { … }        // exit 3 per I4 on error
```

The consumer never allocates an audit record itself in M1 — the
singleton lives in libpdx-audit's `.bss` (see §3 below). The multi-audit
shape (nested tool invocations, concurrent audits) lands post-M4 when
`libpdx-audit.M3-002` binds the shell's parent `ShellCommandRecord` to
child tools' records via `audit_id`.

## 2. AuditRecord shape

Bootstrap-scope layout (M1). All slots are 8-byte aligned; the record
holds one in-progress audit at a time. Sized to hold the fields needed
for the M1 wire format (56 bytes of payload).

| slot                        | type  | width | meaning                                          |
|-----------------------------|-------|-------|--------------------------------------------------|
| `audit_id_next`             | `u64` |  8 B  | monotonic counter; next id to hand out           |
| `record_audit_id`           | `u64` |  8 B  | audit id of the in-progress record (0 = none)    |
| `record_op_name_ptr`        | `u64` |  8 B  | pointer to op-name string (NUL-terminated)       |
| `record_op_args_ptr`        | `u64` |  8 B  | pointer to op-args string (NUL-terminated; may be 0) |
| `record_output_schema_ptr`  | `u64` |  8 B  | pointer to output-schema name (0 iff not yet recorded) |
| `record_output_hash`        | `u64` |  8 B  | BLAKE3-truncated output hash (M1 stub: caller-supplied u64; M3-001 streaming via AuditHash) |
| `record_exit_code`          | `u64` |  8 B  | tool exit code (written by audit_commit)         |
| `record_state`              | `u64` |  8 B  | one of AUDIT_STATE_*                             |
| `audit_broker_slot`         | `u64` |  8 B  | cached cap slot for svc.audit-journal (M1-002)   |
| `record_parent_audit_id`    | `u64` |  8 B  | parent audit id (M3-002; 0 iff top-level)        |

Pointers into consumer memory are **live pointers into caller-owned
memory**. libpdx-audit never mutates the strings — unlike libpdx-argv
which mutates argv in place on `--foo=bar`. The consumer must keep the
argv-backing pages alive from `audit_begin` through `audit_commit`; the
lifetimes match a single tool invocation, so this is the default.

The wire format sent by every lifecycle send is a fixed 64-byte
payload of eight u64 words (grew from 56 → 64 at M3-002 to carry
`parent_audit_id` at index [7]):

```
u64 audit_id              // record_audit_id                     [0]
u64 event_kind            // UEJ_KIND_TOOL_INVOKE/OUTPUT/EXIT    [1]
u64 exit_code             // record_exit_code                    [2]
u64 op_name_ptr           // record_op_name_ptr                  [3]
u64 op_args_ptr           // record_op_args_ptr                  [4]
u64 output_schema_ptr     // record_output_schema_ptr            [5]
u64 output_hash           // record_output_hash                  [6]
u64 parent_audit_id       // record_parent_audit_id (M3-002)     [7]
```

The IPC hdr uses the packed layout from `src/kernel/core/ipc/frame.pdx`
in paideia-os: op = 0x20 (AUDIT_EVENT), ver = 1, reply_endpoint_id = 0
(fire-and-forget), payload_len = 64. As a u64 constant this is
`0x0000_0040_0000_0120` (M3-002; was `0x0000_0038_0000_0120` at
M2 when payload_len was 56). M2-001 refines op / ver as the schema
evolves to match `UEJ_KIND_TOOL_INSTALL/REMOVE/INVOKE/ERROR`
(constants at `src/kernel/core/ipc/audit_journal_broker.pdx` in
paideia-os, 128..131). The kernel-side broker dispatch is still
stubbed (`audit_journal_broker_dispatch` returns `AJB_DISPATCH_STUB`)
so `sys_ipc_send` only enforces `payload_len ≤ PENDING_PAYLOAD_MAX_BYTES`,
well above 64 — the schema grow is safe until the daemon body lands
with a fixed schema at R49-PREP-007.

## 3. Storage model

In M1 all three modules keep their state in `.bss` — the singleton
pattern from `src/user/tokenizer.pdx` and `src/user/dispatch.pdx` in
paideia-os, and the same shape libpdx-argv uses. This is deliberate for
bootstrap:

- One audit-in-flight per process. Every R49/R50 tool opens exactly one
  top-level audit at `_start`, records it, then commits it before
  `sys_exit`. Nested audits (shell parenting child tools) are an
  M3-002 concern.
- Zero heap dependency. libpdx-audit predates any allocator in the R49
  wave; every buffer is a static array.
- Cached broker slot survives every `audit_commit` in the process.
  `audit_broker_slot` starts as `AUDIT_BROKER_SLOT_UNRESOLVED`
  (0xFFFF — a value outside every valid cap-slot range `[0..255]`) and
  is replaced by the first `audit_broker_bind` with a valid slot id.
  Subsequent commits skip the lookup.

Multi-audit-per-process (nested `pkg install` inside a `shell -c`
pipeline) lands with `libpdx-audit.M3-002` — the shape change is a
caller-owned `AuditRecord*` variant, not a rework of the M1 API.

## 4. State machine

`audit_begin / audit_record_output / audit_commit` transition
`record_state` through the following sequence:

```
                     audit_begin
    AUDIT_STATE_IDLE ────────────▶ AUDIT_STATE_BEGUN
                                    │
                                    │ audit_record_output
                                    ▼
                     audit_record_output          (ENH-003: OUTPUT is
                    (loops on itself) ⟲ AUDIT_STATE_OUTPUT   a legal predecessor
                                    │                        of itself — re-entrant)
                                    │ audit_commit
                                    ▼
                                  AUDIT_STATE_COMMITTED
                                    │
                                    │ (audit_commit resets to IDLE
                                    │  after the send returns)
                                    ▼
                                  AUDIT_STATE_IDLE
```

- `audit_begin` requires `record_state == IDLE` (else `AUDIT_ERR_STATE`).
- `audit_record_output` requires `record_state == BEGUN || record_state
  == OUTPUT` (post-1.0.0, ENH-003 — was BEGUN-only through v1.0.0) and
  `audit_id == record_audit_id`. It is optional — a read-only tool
  that emits no schema-typed output may skip it and go straight to
  `audit_commit`. Being re-entrant from OUTPUT lets a multi-target
  operation (e.g. `rm a b c`) call it once per target on a single
  open audit, each call emitting its own `UEJ_KIND_TOOL_OUTPUT` send
  — see §4.1.
- `audit_commit` requires `record_state == BEGUN || record_state ==
  OUTPUT` (both are legal predecessors) and `audit_id ==
  record_audit_id`. On success it resets to `IDLE` so a subsequent
  `audit_begin` in the same process can start a fresh record.

### 4.1 Repeated `audit_record_output` within one audit (ENH-003)

Through v1.0.0, `audit_record_output`'s state gate accepted only
`BEGUN`, so a second call on the same open audit saw `record_state ==
OUTPUT`, failed the gate, and returned `AUDIT_ERR_STATE` — silently,
from the caller's perspective, since most M3-era consumers treated a
record failure as non-fatal. `rm` is the motivating counter-example:
`RmAudit::audit_record_target` is documented to journal "every
successful removal", and `rm`'s remove path calls it once per target
from two call sites. For `rm a b c`, only target `a`'s OUTPUT record
landed; `b` and `c` were dropped on the floor, and a destructive
multi-target operation lost the forensic record of everything past
the first target.

The fix widens the gate to `BEGUN || OUTPUT`, mirroring
`audit_commit`'s existing dual-state pattern. This is purely additive
— no wire-format change, no new error code, no removed behaviour — so
every existing single-output caller is unaffected, and a caller that
never invokes `audit_record_output` more than once per audit sees no
behavioural difference at all.

Every entry point validates the state gate BEFORE the audit_id gate;
this ordering is deliberate — a stale audit_id passed to
`audit_record_output` when the record has already been committed
should be surfaced as `AUDIT_ERR_STATE`, not `AUDIT_ERR_ID_MISMATCH`.

## 5. audit_id allocation (M1-002)

`audit_id_next` is a monotonic u64 counter. `audit_begin` lazily
initialises it to 1 on first call (so `record_audit_id == 0` is a
reserved "no audit in progress" sentinel), then hands out the current
value and post-increments.

`u64` overflow after ~1.8e19 increments is not a shipping concern: a
process emitting one audit per microsecond would need 585,000 years to
wrap. The overflow branch is not implemented in M1.

Every audit_id fits inside a `cmp reg, imm` immediate (positive u64;
paideia-as encodes 64-bit compares via r11 spill for values above
`0x7FFFFFFF` per the encoder's r11-load discipline, so we route the
comparison through r11 in `audit_client.pdx`).

### 5.1 `audit_rearm` — per-audit content clearing (ENH-004)

`reset()` is a process-scoped, call-once primitive: it re-seeds
`audit_id_next = 1`, which a second audit in the same process MUST
NOT observe (monotonicity would break, and per §12 so would any
`parent_audit_id` linkage). But nothing before ENH-004 cleared
`record_exit_code`, `record_output_schema_ptr`, or
`record_output_hash` between audits — only `record_audit_id`,
`record_op_name_ptr`, `record_op_args_ptr`, and `record_state` get
overwritten by `audit_begin`. A second audit in a long-lived process
(the motivating case is a shell running one audit per command)
therefore emitted an INVOKE payload carrying the FIRST audit's exit
code / schema pointer / output hash at wire indices [2] / [5] / [6].

`AuditRecord::audit_rearm()` clears exactly those three content slots.
`audit_begin` calls it automatically immediately after its IDLE gate
passes and before allocating the new id, so the fix requires no new
caller discipline. It deliberately does NOT clear `audit_id_next`,
`audit_broker_slot`, or `audit_broker_failed` (all process-scoped;
see §7.2 for why `audit_broker_failed` recovery is a separate,
narrower policy decision), and does NOT clear
`record_parent_audit_id` — `audit_set_parent` writes that slot BEFORE
`audit_begin` while state is still IDLE, and `audit_begin` invokes
`audit_rearm` right after its own IDLE gate, so clearing the parent
slot here would erase what `audit_set_parent` just wrote for the
audit about to begin.

## 6. svc.audit-journal broker binding (M1-002)

`AuditBroker::audit_broker_bind()` returns `AUDIT_OK` on success and
`AUDIT_ERR_BROKER_UNAVAILABLE` on any of the four svc_lookup errors
(EINVAL / EFAULT / ENOENT / ENOSPC — see
`src/kernel/core/syscall/handlers/sys_svc_lookup.pdx` in paideia-os).

The bind is idempotent — if `audit_broker_slot` is already valid (i.e.
`< 256`, since svc_lookup returns a slot id in `[0..255]`), the bind
returns immediately.

`audit_commit` calls `audit_broker_bind` unconditionally at the top;
the fast path is one load + one compare.

The broker name string is a 20-byte array padded with three NULs after
the 17-char "svc.audit-journal". `sys_svc_lookup` is length-explicit
(does not read past `name_len` bytes) so the NUL padding is defensive;
it matches the kernel-side `audit_journal_broker_name` declaration at
`src/kernel/core/ipc/audit_journal_broker.pdx` in paideia-os
(byte-for-byte identical, deliberately, so a memcmp-equivalent test
in M4-002 can trivially verify the client and server agree on the
name).

## 7. Send failure discipline

If `audit_broker_bind` returns `AUDIT_ERR_BROKER_UNAVAILABLE`,
`audit_commit` returns that same code without attempting the send;
the consumer must exit 3 per I4 (system error) and MUST NOT emit
its output. This is the audit-first contract: a tool that cannot
prove its output was journalled is a tool whose output the operator
cannot trust.

If `sys_ipc_send` returns non-zero (any of `SYS_IPC_SEND_ERR_EAGAIN /
BAD_ID / PAYLOAD_LEN / EFAULT / CHANDEAD` — see
`src/kernel/core/syscall/handlers/sys_ipc_send.pdx` in paideia-os),
`audit_commit` returns `AUDIT_ERR_SEND_FAILED`. The consumer treats
this identically to the bind failure: exit 3, no output.

The bounded-retry-with-backoff path (M2-003) lives one milestone up.
M1 has no retry: a single send attempt either succeeds or hard-fails.
This is intentional — M2 tests will need to observe the hard-fail
edge before a retry layer is meaningful.

### 7.1 `audit_can_emit_output` fail-closed default (ENH-005)

`AuditClient::audit_can_emit_output()` is the guard consumers wrap
every stdout/stderr write in. Through v1.0.0 it read only the sticky
`audit_broker_failed` flag, which meant a process that never called
`audit_begin` at all — or one whose audit already committed — read
`1` (safe) via `.bss` zero-init, since the flag rises only on a
*failed* send, never an *absent* audit. Post-1.0.0 the guard requires
BOTH `audit_broker_failed == 0` AND `record_state IN {BEGUN, OUTPUT}`.
A tool that forgets to open an audit, or checks the guard after
`audit_commit` has already returned the record to `IDLE`, now
correctly refuses. This was safe to tighten immediately after v1.0.0
because no consumer called this entry point yet (see README §Callers);
once a consumer's M4 gate is wired against the old behaviour, the
same tightening would be a breaking change.

### 7.2 Sticky-failure recovery policy for long-lived consumers (ENH-008)

`audit_broker_failed` is set by either failure epilogue of
`audit_send_record` and, before ENH-008, cleared only by `reset()` —
which re-seeds `audit_id_next = 1`, so a long-lived process (the
motivating case is `shell`, which opens one audit per command for its
entire lifetime) cannot safely call it between audits without
destroying monotonicity (and, per §12, any `parent_audit_id`
linkage). One transient failure on one child's audit therefore
permanently suppressed output from the shell process for the rest of
its life.

**Explicit policy decision: sticky-forever is the intended contract.**
Under D3 audit-first, "the journal is gone" is not a transient
condition a process should try to paper over — a supervisor that
recovers from a broker outage restarts the affected tool rather than
asking a tainted process to keep emitting output. `audit_rearm()`
(§5.1, ENH-004) was the natural place to introduce a narrower
recovery primitive, and deliberately does NOT clear
`audit_broker_failed` or `audit_broker_failure_cause` — only
`reset()` does, exactly as before ENH-008. A consumer able to clear
its own "I failed to journal" flag on a per-audit basis would defeat
D3: any tool could route around one failed send by starting a fresh
audit. No new mutation primitive is added.

What ENH-008 does add is diagnosis, not recovery: a second sticky
slot, `audit_broker_failure_cause`, records WHICH of
`audit_send_record`'s two failure epilogues fired —
`AUDIT_ERR_BROKER_UNAVAILABLE` (asr_bind_fail — the broker was never
reachable) or `AUDIT_ERR_SEND_FAILED` (asr_ipc_fail — bind succeeded
but the send's retry budget exhausted or hard-failed). Previously an
operator saw only "output suppressed", with no way to tell those two
operationally distinct failures apart. `AuditClient::
audit_broker_failure_cause()` exposes it; both slots are zeroed
together by `reset()`.

## 8. Compliance with paideia-as encoding constraints

All three modules follow the constraints called out in
`design/kernel/paideia-as-conformance.md` (paideia-os repo) as they
apply to the userspace toolchain at v0.33+:

- Module names are PascalCase basename (`AuditRecord`, `AuditClient`,
  `AuditBroker`) — no directory prefix.
- No `test` mnemonic; every zero-check is `cmp reg, 0`.
- Every `cmp reg, imm` uses an immediate ≤ 0x7FFFFFFF (or 0xFFFF for
  the broker-slot unresolved sentinel; both encoder-safe as 32-bit
  sign-extended immediates).
- Register `r11` is scratch and is never assumed live across a call.
- Byte loads use `xor rax, rax; mov_b rax, [ptr]` per the paideia-as
  #1248 mitigation pattern (see the tokenizer.pdx cite in the module
  justifications). libpdx-audit performs no byte loads of its own in
  M1 — all field reads are u64-wide — but the syscall_shim.pdx
  trampolines keep the pattern available for later milestones.
- SysV callee-save discipline: any function that touches
  `rbx`/`r12..r15` (currently only `audit_commit` in M1-002, which
  preserves the audit_id + exit_code across the broker-bind call)
  pushes and pops the register in pairs so `rsp % 16 == 0` at the
  nested `call`.

## 9. What M1 explicitly does not do

Called out here so a reader of M1 code does not mistake absence for bug:

- No `UEJ_KIND_TOOL_INVOKE` / `OUTPUT` / `EXIT` split. M1 sends a
  single monolithic record via `sys_ipc_send`; the three-way split
  lands with `libpdx-audit.M2-001` once the broker has begun to
  differentiate between begin / output-record / commit events on
  its side.
- No bounded retry-with-backoff. M1's `audit_commit` makes a single
  send attempt. `libpdx-audit.M2-003` adds the 3-retry loop.
- No BLAKE3-truncated hash computation. M1 accepts a caller-supplied
  u64 in `audit_record_output`'s `output_hash` slot; the hash
  computation from the tool's actual output stream lands with
  `libpdx-audit.M3-001` (see §11 below).
- No parent-child linkage with shell's `ShellCommandRecord`. M1 hands
  out a bare audit_id per record; `libpdx-audit.M3-002` adds the
  `parent_audit_id` field alongside a shell-side hook.
- No output emission of the record shape. M1 sends the record over
  IPC; the semantic-pipe binding via libpdx-semantic-pipe lands with
  the M3 line.

## 11. M3-001 — streaming output-stream hash

The M3-001 upgrade to `audit_record_output`'s `output_hash` slot: the
library now provides a streaming digest a consumer folds its output
stream into as bytes are emitted. `AuditHash` (`src/audit_hash.pdx`)
exposes three entry points and one hidden `.bss` accumulator:

```
AuditHash::audit_hash_init()                       -> ()
AuditHash::audit_hash_update(ptr, len)             -> u64
AuditHash::audit_hash_finalize()                   -> u64
```

Consumer wire-up:

```
AuditHash::audit_hash_init()
… tool emits chunk N … AuditHash::audit_hash_update(chunk_ptr, chunk_len)
let h = AuditHash::audit_hash_finalize()
AuditClient::audit_record_output(id, schema, h)
```

`audit_record_output`'s signature is UNCHANGED — it still takes a
caller-supplied `u64` hash. M3-001 is additive: consumers that want the
audit-first hash-of-output-stream discipline (D3) call the streaming
API and pass its finalize result; consumers that have their own hash
source pass that directly, as they did at M2.

### 11.1 Hash primitive: FNV-1a-64 placeholder for BLAKE3-truncated

The plan (`design/tooling/r49-r50-plan.md` §5.13 M3-001 line) specifies
BLAKE3-truncated. paideia-as v0.33-crypto-kdf (per `design/user/model.md`
§11.2 in paideia-os) ships Argon2id + ChaCha20-Poly1305 + ML-DSA-65 —
BLAKE3 is not yet exposed as a stdlib intrinsic. Rather than block M3-001
on a paideia-as toolchain wave, this milestone ships FNV-1a-64 as the
underlying primitive and documents it as a swap-target:

- The streaming API (`init` / `update` / `finalize`) is BLAKE3-shaped.
- `record_hash_state` is a u64 slot; BLAKE3-256 truncated to first
  8 bytes fits identically. FNV-1a-64 already IS 64 bits — no
  truncation needed.
- When BLAKE3 arrives as a paideia-as intrinsic (post-v0.33), the
  internals of `audit_hash_update` (byte-wise xor-multiply) and
  `audit_hash_finalize` swap for calls to the intrinsic. Consumer
  code, the `.bss` slot, the wire format, and the return type all
  stay the same.

This mirrors the M2-001 stubbing pattern (UEJ_KIND_TOOL_OUTPUT and
UEJ_KIND_TOOL_EXIT forward-declared at ordinals 132/133 pending the
R49-PREP-007 kernel-side ordinal split).

FNV-1a-64 constants live in `AuditRecord`:

- `FNV_OFFSET_BASIS = 0xcbf29ce484222325` — seed state on init.
- `FNV_PRIME = 0x100000001b3` — multiplied into state after each
  XOR-fold.

Both exceed the 0x7FFFFFFF cmp-imm bound but are legal for a register
load: paideia-as encodes `mov r64, imm64` as MOVABS. Neither constant
ever appears in a cmp instruction.

### 11.2 State + storage

Two new slots in `AuditRecord`'s `.bss`:

| slot                 | type  | width | meaning                                          |
|----------------------|-------|-------|--------------------------------------------------|
| `record_hash_state`  | `u64` |  8 B  | FNV-1a-64 accumulator (BLAKE3-truncated later)   |
| `record_hash_active` | `u64` |  8 B  | 1 while accumulating; 0 before init / after final|

`reset()` zeros both — a fresh reset() at process start gives
`audit_hash_init` a clean starting point (rather than inheriting a
hash-in-flight from a prior audit within the same process). `audit_hash_init` seeds `record_hash_state` with `FNV_OFFSET_BASIS` and
writes `record_hash_active = 1`; `audit_hash_finalize` reads the state,
clears active to 0, returns the state.

### 11.3 New error code

- `AUDIT_ERR_HASH_INACTIVE = 5` — returned by `audit_hash_update` when
  `record_hash_active == 0`. Defence-in-depth: a caller that forgets
  to init would otherwise fold bytes into whatever the `.bss`
  zero-init left behind (state = 0, producing a valid-looking but
  meaningless hash). `audit_hash_finalize` returns 0 on inactive
  instead of an error code — the u64 return channel cannot
  discriminate zero-by-chance from zero-by-inactive, so the
  discipline is enforced at update-time.

### 11.4 Register + effects discipline

`AuditHash` functions are all `!{mem} @{}` — pure memory read/write, no
syscall, no cap consumption. `audit_hash_update` uses `r13` (state
accumulator loaded/stored across the loop) and `r8` (FNV_PRIME constant
loaded once); both are SysV callee-save and pushed/popped as a pair to
preserve `rsp % 16 == 0` for any future refactor that introduces a
nested call. Byte load uses `xor r10, r10; mov_b r10, [rdi + rcx]` per
the paideia-as #1248 mitigation pattern (matches `acpi/checksum.pdx`
and `acpi/hpet.pdx` in paideia-os kernel code — the `mov_b` primitive
does not zero-extend on its own).

## 12. M3-002 — parent-child linkage with shell `ShellCommandRecord`

The M3-002 upgrade turns libpdx-audit's flat per-tool audit stream into
a linkable tree: every audit record now carries a `parent_audit_id`
slot that names its parent's `audit_id`. When a shell spawns a tool,
the shell's own `ShellCommandRecord` is the parent (its `audit_id`
comes from the shell's own `audit_begin`); the child sets that id
here — via `AuditClient::audit_set_parent(parent_id)` — before its own
`audit_begin`. All three of the child's lifecycle sends (INVOKE at
`audit_begin`, OUTPUT at `audit_record_output`, EXIT at `audit_commit`)
then carry the linkage in their wire payloads.

This is the D3 audit-first discipline handle consumers need: a
supervisor replaying the audit journal from a flat event stream can
reconstruct the per-shell-command tree without any implicit shell-side
ordering assumption.

### 12.1 New client entry point

```
AuditClient::audit_set_parent(parent_audit_id) -> u64
```

- `rdi` = parent_audit_id (0 iff top-level).
- Returns `AUDIT_OK` on success, `AUDIT_ERR_STATE` if
  `record_state != IDLE`.
- Must be called AFTER `AuditRecord::reset()` and BEFORE
  `AuditClient::audit_begin`. The IDLE gate enforces this — parent
  linkage is a property of the audit's identity and cannot be
  mutated mid-flight.

Consumers that never call `audit_set_parent` get `parent = 0` in
their wire records via `.bss` zero-init (or `reset()`'s zero pass).
`parent = 0` is the correct wire value for the shell itself, a
bootstrap tool spawned outside a shell, or any tool with no parent
audit context — the M2 shape (no linkage) remains the default.

### 12.2 New `.bss` slot

`record_parent_audit_id : u64` in `AuditRecord`. Zeroed by `reset()`.
Marshalled by `AuditBroker::audit_send_record` at payload index [7]
on every lifecycle send.

### 12.3 Wire-format grow (56 → 64 bytes)

The payload extends by one u64 word:

| index | field                    |
|------:|--------------------------|
|   [0] | `record_audit_id`        |
|   [1] | `event_kind`             |
|   [2] | `record_exit_code`       |
|   [3] | `record_op_name_ptr`     |
|   [4] | `record_op_args_ptr`     |
|   [5] | `record_output_schema_ptr` |
|   [6] | `record_output_hash`     |
|   [7] | `record_parent_audit_id` (M3-002) |

Constants change:

- `AUDIT_PAYLOAD_BYTES : u64 = 56` → `= 64`
- `AUDIT_HDR_WORD : u64 = 0x0000_0038_0000_0120` →
  `= 0x0000_0040_0000_0120` (only the payload_len field in the low
  32 bits — `0x38` → `0x40` — changes; `op = 0x20`, `ver = 1`,
  `reply_endpoint_id = 0` are unchanged)
- `audit_payload_scratch : [u64; 7]` → `[u64; 8]`

The kernel-side broker dispatch is still stubbed
(`audit_journal_broker_dispatch` returns `AJB_DISPATCH_STUB`) so
`sys_ipc_send` only enforces `payload_len ≤ PENDING_PAYLOAD_MAX_BYTES`,
well above 64. The schema grow is therefore safe until the daemon
body lands with a fixed schema at R49-PREP-007; when it does, the
kernel-side event schema will need the `parent_audit_id` field added
at the same index [7] to keep byte-for-byte agreement.

### 12.4 How the parent_audit_id reaches the child

Out of scope for libpdx-audit. The shell publishes its command-record
id via its spawn protocol — env var, InitCap sidecar entry, or a
typed-frame field on the child's stdin depending on which
`shell.M3-003` (`ShellCommandRecord via libpdx-audit before sys_execve;
close on wait` per r49-r50-plan.md §5.2) lands first. This library
only exposes the setter; the transport is a shell concern.

### 12.5 Register + effects discipline

`audit_set_parent` is a pure leaf (`!{mem} @{}`) — one .bss read for
the state gate, one .bss write for the parent slot. No syscall, no
cap consumption, no push/pop. Label prefix `asp_` per the
paideia-as reserved-label discipline (bare `ok` / `fail` collide
with keywords; `asp_ok` / `asp_bad_state` are unique).

## 13. M4 — test discipline

libpdx-audit is a shared library with no runnable executable of its
own. Its test drivers therefore live in `tests/*.pdx` as pure-leaf
paideia-as modules that a consumer tool's test-runner main (in a
future pkg.M2 / cat.M2 / dedicated `examples/` binary) links and
invokes.

### 13.1 Driver protocol

Every M4 test driver in this repo exports a single public entry
point:

```
pub let run : () -> u64 !{mem} @{} = fn () -> unsafe { … }
```

The return value is:

- `0` — all subtests in the driver passed.
- `N > 0` — the ordinal of the first failing subtest. Ordinals are
  stable across driver runs so a smoke log can pinpoint the failing
  invariant.

Effects are constrained to `!{mem} @{}` — no syscall, no cap
consumption — so the driver runs under any consumer, including one
that has not requested the widened effects `audit_begin` /
`audit_record_output` / `audit_commit` need. This bounds the failure
surface: a test that returns non-zero has failed on a library
invariant, not on a syscall path libpdx-audit cannot control.

### 13.2 Fault-injection discipline

libpdx-audit is a library; without a kernel it cannot exercise its
own syscalls. Driver subtests reach failure states by direct
`.bss` writes to the AuditRecord slots the runtime error paths would
otherwise set. The three canonical fault-injection points at M4:

- `audit_broker_failed = 1` — simulates the M2-002 sticky-flag
  write from `asr_bind_fail` / `asr_ipc_fail`. Used by M4-001 to
  verify `audit_can_emit_output` returns 0 (refuse) with the flag
  set.
- `record_state = AUDIT_STATE_BEGUN` (1) — simulates the post-
  `audit_begin` state, reaching it without running the INVOKE
  send. Used by M4-002 to verify `audit_set_parent` refuses (state
  != IDLE → AUDIT_ERR_STATE per §12.1).
- `record_hash_active = 0` (implicit via `reset`) — simulates the
  never-initialised state. Used by M4-002 to verify
  `audit_hash_update` returns AUDIT_ERR_HASH_INACTIVE (5).

These writes mirror exactly what the runtime paths do — the .bss
slot is the observable state the guards read. A test passing here
proves the same guard would fire under the real syscall failure
mode.

### 13.3 QEMU smoke deferral

The full end-to-end M4 assertions — spawn a bootstrap consumer
under QEMU, observe stdout/stderr and the audit-endpoint payload —
require three not-yet-landed substrates:

1. `shell.M4` (paideia-os/shell §5.2) so a consumer can be spawned
   with a bounded cap set.
2. A runnable consumer (`pkg.M2`, `cat.M2`, or a small
   `examples/` binary hosted here) that links libpdx-audit and
   calls the drivers from its own test-runner main.
3. `R49-PREP-007` — the kernel-side `audit_journal_broker_dispatch`
   daemon body. Without a daemon, `sys_ipc_send` discards the
   payload; wire-byte replay needs the daemon to persist bytes
   for observer capture.

`tests/README.md` §QEMU smoke protocol documents the M4-001 and
M4-002 protocol for that future harness in detail.

### 13.4 Golden fixture format

`tests/goldens/trace_001.md` is the canonical M4-002 wire-bytes
fixture. It documents:

- The header word (`AUDIT_HDR_WORD = 0x0000004000000120`) with per-
  field bit layout.
- Three per-send payload tables (INVOKE / OUTPUT / EXIT), each
  eight `u64` rows corresponding to `audit_payload_scratch` indices
  [0..7].
- Concrete values where the library owns them (audit_id,
  event_kind, exit_code, parent_audit_id); symbolic placeholders
  (`<LS_NAME_VA>`, `<HASH_LS>`, …) where the value depends on
  consumer-owned memory or a runtime-computed hash.
- A companion M4-001 failure-path fixture (child exits 3, emits 0
  bytes, no wire payload).
- A change-management section calling out what code changes require
  a fixture refresh (payload_len change, new UEJ_KIND ordinal,
  kernel-side schema lock at R49-PREP-007).

The QEMU harness memcmp's `audit_payload_scratch` against the
concrete rows after each lifecycle send; symbolic rows are
resolved against the harness's own linker map or computed
independently.

## 10. Cross-repo dependencies

Per r49-r50-plan.md §5.13:

- **libpdx-audit.M1 depends on §5.0 R49-PREP-006** — the
  `svc.audit-journal` broker registration seam + `UEJ_KIND_TOOL_*`
  event constants at `src/kernel/core/ipc/audit_journal_broker.pdx`
  in paideia-os (landed as commit `2ff76d4`, `Closes #1628`).
- libpdx-audit.M2 depends on shell.M2 (parent-child linkage) and
  libpdx-semantic-pipe.M2 (audit records travel on a semantic pipe).
- libpdx-audit.M2 also depends on the R49-PREP-006 event constants
  splitting into `UEJ_KIND_TOOL_INVOKE / OUTPUT / EXIT` (currently
  a single INVOKE / EXIT pair with REMOVE / ERROR held for future
  use); the split is deferred to R49-PREP-007.

paideia-as ≥ v0.33 is required by the module encoder (needed for the
`mov_b` narrow-load mnemonic and for the `@align` attribute on `.bss`
slots). Older paideia-as revisions predate the #1248 mitigation and
should not be used to build libpdx-audit.
