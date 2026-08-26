# libpdx-audit — enhancement plan (v1.x)

**Date:** 2026-08-25
**Baseline:** `main` @ `5d808fe`, tag `v1.0.0`
**Method:** source-verified read of `src/`, `tests/`, `caps.decl`,
`design/architecture.md`, `CHANGELOG.md`, `STATUS.md`, plus a read-only
adoption survey of all nine consumer clones.

This document is the audit-pass companion to `design/architecture.md`.
It records what the library actually is at v1.0.0, what its consumers
actually do, and the concrete issue plan for the gaps that belong to
**this** repo. It deliberately does not restate the M1–M5 milestone
history — `CHANGELOG.md` carries that.

---

## 1. Current state

### 1.1 What is real

Every entry point the README documents exists in source, with the
signature and the effect/capability tail the README claims. This is a
genuinely complete implementation of the shape it set out to build:

| Module | Entry points | Status |
|---|---|---|
| `AuditRecord` | `reset` + 6 error codes + 4 states + wire constants + 15 `.bss` slots | complete |
| `AuditClient` | `audit_begin`, `audit_record_output`, `audit_commit`, `audit_can_emit_output`, `audit_set_parent` | complete |
| `AuditBroker` | `audit_broker_bind`, `audit_send_record` + `audit_broker_name` | complete |
| `AuditHash` | `audit_hash_init`, `audit_hash_update`, `audit_hash_finalize` | complete (FNV-1a-64 placeholder) |
| `SyscallShim` | `sys_svc_lookup` (SC+ 43), `sys_ipc_send` (SC+ 42) | complete |

There are **no `TODO`/`FIXME`/unimplemented branches in `src/`**. The
only markers are the two knowingly-documented placeholders — the
FNV-1a-64 hash primitive standing in for BLAKE3, and the forward-declared
`UEJ_KIND_TOOL_OUTPUT`/`EXIT` ordinals pending the kernel-side
R49-PREP-007 split. Both are disclosed in `CHANGELOG.md` § *Known
deferred substrate*. The retry loop, the sticky-failure flag, the
state gates and the marshal are all fully written, and the register /
push-pop / cmp-immediate discipline is consistent throughout.

### 1.2 What the tests actually exercise

`tests/` holds two pure-leaf drivers (`test_broker_refusal.pdx`,
`test_replay_golden.pdx`, 7 + 8 subtests) that reach failure states by
direct `.bss` fault injection, plus a documentary golden
(`goldens/trace_001.md`).

Their coverage boundary is stated honestly in `tests/README.md` and is
worth restating plainly: **no test in this repo has ever executed
`audit_send_record`, `audit_broker_bind`, `audit_begin`,
`audit_record_output`, or `audit_commit`.** The drivers are confined to
the syscall-free subset (`reset`, `audit_can_emit_output`,
`audit_hash_*`, `audit_set_parent`) because the repo hosts no runnable
binary. So the marshal loop, the header word, the retry/backoff loop,
the bind sentinel discriminator and all three lifecycle sends are
**verified by code review only**. The wire bytes in
`goldens/trace_001.md` have never been compared against a real send.

That is a defensible position for a library with no executable — but it
means "M4 landed" describes the drivers, not the wire.

---

## 2. Consumer adoption reality

Verified by grepping `src/` in every consumer clone for real `call`
instructions into this library's symbols.

| Repo | `deps.list` claims | Real call sites | Verdict |
|---|---|---|---|
| `rm` | — | `src/audit.pdx:163` `call audit_begin`, `:236` `call audit_record_output`, `:294` `call audit_commit` | **real, all three** |
| `cp` | — | `src/audit.pdx:173` `call audit_begin` + `cp_audit_commit_wrap` | **real** |
| `pkg` | — | `src/audit_wire.pdx:100/146/168` — all three, used by five subcommands | **real, all three** |
| `ls` | — | `src/audit_shim.pdx:205` `call audit_begin`, `:280` `call audit_commit` | **real** (but see §2.2) |
| `mv` | `libpdx-audit 1.0.0 # src/audit.pdx` | **none** | **overstated — see §2.1** |
| `cat` | none (`deps.list` is explicit) | none — `src/audit_stub.pdx` is an in-tree stub | honestly declared |
| `doc` | — | none — `src/audit.pdx` is a local reimplementation with its own `audit_next_id` | not linked |
| `shell` | — | none — `src/command_record.pdx` encodes around an `audit_id` it never obtains | not linked |
| `mkdir` | — | none | not linked |

So the D3 audit-first pillar is genuinely load-bearing in four tools.
That is real adoption, not README theatre — this library is in better
shape on that axis than the org-wide pattern the README pass found.

### 2.1 mv's "destructive-op audit" is real traffic but bypasses this library

`mv/deps.list` pins `libpdx-audit 1.0.0 # user-events journal client;
src/audit.pdx`, and `mv`'s README advertises destructive-op audit. The
audit *does* happen — but `mv/src/audit.pdx` is a self-contained
`module Audit` that declares its **own** `svc_lookup` / `ipc_send`
trampolines and its own 20-byte `"svc.audit-journal\0\0\0"` literal.
Its file header says so outright (L33–37): *"redeclare the constants
here to keep the mv crate self-contained — no libpdx-audit dependency
at M3-002."*

This is worse than a plain unwired dependency, because mv is talking to
the **same broker endpoint with a different wire contract**:

- `mv_audit_write_move` calls `ipc_send(slot, 0, mv_move_record, 80)` —
  an **80-byte** payload, against this library's 64-byte
  `PdxAuditRecord@0.1`.
- It passes **`hdr_va = 0`** — a null frame header, so none of
  `AUDIT_HDR_WORD`'s `op = 0x20 (AUDIT_EVENT) | ver = 1` discriminator
  reaches the broker.

Today `audit_journal_broker_dispatch` is a stub that discards
everything, so nothing breaks. When R49-PREP-007 lands a real daemon,
`svc.audit-journal` will be receiving two mutually undecodable record
shapes with no way to tell them apart. **The fix belongs in `mv`**
(migrate to `AuditClient`), not here — but this repo should state
plainly that it owns the wire contract on that endpoint (ENH-007).

### 2.2 ls links the library but cannot detect its failures

`ls/src/audit_shim.pdx:205` calls `audit_begin` for real, then checks
the result at `:208`:

```
        call audit_begin;
        // ---- Negative-errno detector (bit 63 set) ---------------------
        cmp rax, 0;
        jl  aulb_begin_fail;
```

`audit_begin` never returns a negative value — its documented failure
sentinel is **`0`** (both for the state gate and for send failure).
`0` is not `< 0`, so `aulb_begin_fail` is unreachable: on a broker
failure `ls` stashes `_au_id = 0`, returns `AU_OK`, and proceeds to
emit directory listings that were never journalled. That is a direct
D3 violation in the one read-only tool the org points at as the
capability/semantic-pipe exemplar.

The bug is `ls`'s to fix, but the *cause* is an API-ergonomics gap that
is ours: every other IPC-adjacent shim in this org (mv's `svc_lookup`,
mv's `ipc_send`, cp's TXN returns) uses the negative-errno convention
and the `cmp rax, 0; jl` idiom. `audit_begin` alone inverts it, and the
inversion is silent and fails **open**. See ENH-006.

---

## 3. Gaps that belong to this library

Ordered by severity. All eight are verified against source; none is
speculative.

### 3.1 The wire record cannot deliver its own content (ENH-001)

Payload words `[3] op_name_ptr`, `[4] op_args_ptr` and
`[5] output_schema_ptr` are **live virtual addresses in the sending
tool's address space**. `sys_ipc_send` bounces exactly `payload_len`
(64) bytes; it does not and cannot follow those pointers. The
audit-journal daemon is a separate process, so it receives three opaque
integers where the human-meaningful content of the audit record —
*which tool, which arguments, which schema* — is supposed to be.

The README documents the pointer semantics accurately ("The record
carries pointers, not bytes") and correctly notes the consumer must
keep the pages alive from begin to commit. But keeping them alive only
matters within the sender; it does not make them readable by the
journal. Strip the pointers and a `PdxAuditRecord@0.1` reduces to
`{audit_id, event_kind, exit_code, output_hash, parent_audit_id}` — an
audit trail that can tell you *that* something ran and what it exited
with, but never *what it was*.

`rm` makes this concrete: `rm/src/audit.pdx:74` defines
`OP_NAME : [u8;3] = "rm\0"` and comments *"the audit-journal reader
will read the NUL-terminated string when it renders the record."* It
cannot.

This must be resolved **before** R49-PREP-007 fixes the kernel-side
schema, or the daemon locks in a record shape that structurally cannot
carry its payload. It is a wire-format major bump either way.

### 3.2 `audit_id` is not unique, so `parent_audit_id` cannot resolve (ENH-002)

`reset()` seeds `audit_id_next = 1` and `audit_begin` hands out
`1, 2, 3, …` **per process**. Every tool's first audit is therefore
`audit_id == 1`.

The entire M3-002 parent-linkage feature depends on a child writing its
parent's `audit_id` into payload `[7]` so a supervisor can rebuild the
per-shell-command tree "without any implicit shell-side ordering
assumption" (architecture §12). But in a flat journal, `parent_audit_id
= 1` names the first audit of *every process that ever ran*. The
linkage is unresolvable exactly when it is needed — under a shell
running many children.

`goldens/trace_001.md` papers over this by choosing `parent = 0x2a`,
which implies a shell already 42 audits deep; nothing in the allocator
guarantees a child cannot also reach 42.

The id needs a process-distinguishing component (kernel-supplied id,
`(pid, local)` tuple, or a daemon-side rewrite at receipt). Also a
major bump, and it should land in the same wire revision as ENH-001.

### 3.3 `audit_record_output` is single-shot; multi-record consumers lose data (ENH-003)

`audit_record_output` gates on `record_state == AUDIT_STATE_BEGUN` and
transitions `BEGUN → OUTPUT`. A second call therefore sees `state ==
OUTPUT`, fails gate 1, and returns `AUDIT_ERR_STATE`. **One output
record per audit is the hard ceiling.**

`rm` is built on the opposite assumption. `rm/src/audit.pdx` documents
`audit_record_target` as journalling *"every successful removal"*, and
`rm/src/remove.pdx` calls it from two sites (`:489` in the `--wipe`
branch, `:559` in the default branch), once per target. For
`rm a b c`, target `a` is journalled and `b` and `c` return
`AUDIT_ERR_STATE` into `audit_records_err` — silently, because rm
treats record failure as non-fatal at M3. The forensic record of a
multi-target destructive operation is missing every target after the
first.

`cat`'s stub is written per-file and `ls`'s frame is per-listing, so
they inherit the same ceiling the moment they wire up for real.

Permitting `OUTPUT → OUTPUT` re-entry (each emitting its own
`UEJ_KIND_TOOL_OUTPUT` send) is additive, needs no wire change, and is
a semver-minor.

### 3.4 Stale fields leak into the next audit's INVOKE (ENH-004)

`audit_commit` resets `record_state` to `IDLE` on success, and the
README says this lets "a later `audit_begin` start fresh". It does not.
`audit_begin` writes only `record_audit_id`, `record_op_name_ptr`,
`record_op_args_ptr` and `record_state`. It never clears
`record_exit_code`, `record_output_schema_ptr` or `record_output_hash`.

So the second audit in a process sends an `INVOKE` carrying the *first*
audit's exit code at `[2]`, its schema pointer at `[5]` and its output
hash at `[6]`. `goldens/trace_001.md` specifies INVOKE as having
"uninit exit/schema/hash", which holds only for the first audit after a
fresh `reset()`.

The obvious workaround — call `reset()` between audits — is explicitly
forbidden: `reset()` re-seeds `audit_id_next = 1`, destroying
monotonicity (and, per §3.2, the linkage). The library has a
process-scoped lifecycle primitive and no audit-scoped one. It needs an
`audit_rearm()` that clears the per-audit content slots while
preserving `audit_id_next`, `audit_broker_slot` and (deliberately)
`audit_broker_failed`.

Every consumer today is single-audit-per-process, so this is latent —
but `shell`, the designated M3-002 parent, is by construction
many-audits-per-process.

### 3.5 `audit_can_emit_output` fails open (ENH-005)

The gate is one load and one compare on `audit_broker_failed`. `.bss`
zeroing means it returns **1 (safe to emit)** for a process that never
called `audit_begin` at all — the flag only rises on a *failed* send,
never on an *absent* audit.

The D3 contract is "a tool whose output was not journalled is a tool
whose output the operator cannot trust". The current gate enforces
"not *unsuccessfully* journalled". A tool that forgets to open an
audit, or exits a path before `audit_begin`, passes cleanly. For the
one primitive whose entire job is to fail closed, the default is
backwards.

Adding `record_state ∈ {BEGUN, OUTPUT}` to the predicate closes it.
This is safe to do now precisely because — as the README states — **no
consumer calls `audit_can_emit_output` yet**; tightening it later, once
`cp`/`rm`/`cat` have wired their M4 gates, would be a breaking change.
The window is open today.

### 3.6 The failure sentinel invites the ls-class bug (ENH-006)

Covered in §2.2. `audit_begin` returns `0` on failure and a positive id
on success, while the surrounding codebase reads IPC-adjacent returns
as negative-errno. One of the four real consumers got the check
backwards in a way that silently disables the D3 refusal. `audit_begin`
also conflates two distinct failures (state-gate vs send) into the same
`0`, so a consumer cannot tell "I misused the API" from "the journal is
down".

### 3.7 `caps.decl` misdeclares the wire format (ENH-007)

`caps.decl` — a shipped manifest, not prose — still reads:

> `# Declared output schemas — the M1 wire format is a stub 56-byte
> fixed-layout record. The full UEJ_KIND_TOOL_INVOKE / OUTPUT / EXIT
> schema binding via libpdx-semantic-pipe lands in M3`

The record has been 64 bytes since M3-002 and the INVOKE/OUTPUT/EXIT
split landed at M2-001. This is the one artifact a resolver reads to
learn what the package emits, and it describes a format two milestones
stale. Same edit should add the wire-ownership statement §2.1 argues
for.

### 3.8 Sticky failure has no recovery story for long-lived consumers (ENH-008)

`audit_broker_failed` is set on any send failure and cleared only by
`reset()` — which, per §3.4, a long-lived process cannot safely call.
For a shell, one transient failure on one child's audit permanently
suppresses all output from the shell process for its lifetime.

Under a strict D3 reading that may be *correct* — if the journal is
gone, stop trusting output. But it is currently an accident of the
implementation rather than a decision, and the library gives an
operator no way to distinguish "one send EAGAIN'd past its retry
budget" from "the journal daemon is down". This needs a documented
policy and probably a failure-cause slot, not a blanket clear.

---

## 4. Issue plan

Eight issues, all filed against milestone **Enhancement v1.x —
libpdx-audit** (milestone 6). Nothing here is make-work: each traces to
a specific line of source cited above.

| Issue | ENH | Title | §  | Effort | Deps |
|---|---|---|---|---|---|
| #11 | ENH-001 | Wire record carries unreadable sender pointers | 3.1 | L | none |
| #12 | ENH-002 | `audit_id` not globally unique — parent linkage unresolvable | 3.2 | M | #11 |
| #13 | ENH-003 | Allow repeated `audit_record_output` per audit | 3.3 | M | none |
| #14 | ENH-004 | Add `audit_rearm()` — per-audit clean slate | 3.4 | S | none |
| #15 | ENH-005 | `audit_can_emit_output` must fail closed | 3.5 | S | none |
| #16 | ENH-006 | Disambiguate `audit_begin` failure sentinel | 3.6 | S | none |
| #17 | ENH-007 | Refresh `caps.decl` + assert wire ownership | 3.7 | XS | none |
| #18 | ENH-008 | Sticky-failure recovery policy | 3.8 | S | #14 |

#11 + #12 together constitute the v2 wire revision and should ship as
one coordinated change with a paideia-os companion. #13 through #18 are
v1.1 and independently landable.

### 4.1 Sequencing note

ENH-001 and ENH-002 are **blocking on R49-PREP-007**, not blocked by
it. Once the kernel-side `audit_journal_broker_dispatch` daemon body
lands with a fixed schema, the pointer-bearing 64-byte record becomes a
frozen cross-repo contract and both fixes get an order of magnitude
more expensive. The daemon should not be written against
`PdxAuditRecord@0.1` as it stands.

---

## 5. Companion work in other repos (not filed here)

Recorded for the agents that own those repos; **no issues were filed
outside `libpdx-audit`**.

- **`mv`** — migrate `src/audit.pdx` to `AuditClient` and retire the
  local trampolines + the 80-byte / null-header send (§2.1); or drop
  the `libpdx-audit` row from `deps.list` if the migration is not
  imminent.
- **`ls`** — fix the `cmp rax, 0; jl` failure detector at
  `src/audit_shim.pdx:208`; it must be `cmp rax, 0; je` (§2.2).
- **`rm`** — depends on ENH-003 before per-target journalling works
  (§3.3).
- **`shell`** — depends on ENH-002 and ENH-004 before
  `ShellCommandRecord` parenting is meaningful (§3.2, §3.4).
- **`paideia-os`** — R49-PREP-007 should not lock the daemon schema
  until ENH-001/ENH-002 land (§4.1); the `UEJ_KIND_TOOL_OUTPUT`/`EXIT`
  ordinal split at 132/133 still needs to land kernel-side; and the
  daemon needs a sender-identity source, since the wire record has no
  actor field and cannot get one from the payload.

---

## 6. Version verdict

**v1.0.0 is defensible as an implementation and premature as a wire
contract.**

The code is complete, internally consistent, disciplined about its
paideia-as constraints, honest in its documentation about what is a
placeholder, and genuinely linked by four consumers. As "the R49
shared-library template", it earns the tag.

What it should not have carried is `CHANGELOG.md`'s claim that *"the
wire format is a stable v1 contract"*. That format cannot transport its
own op-name, args or schema across the process boundary it exists to
cross (§3.1), and its identity field cannot support the linkage feature
built on top of it (§3.2). Both are structural, and both force the
major bump the semver policy reserves for wire growth.

Recommendation: leave `v1.0.0` tagged as-is (it accurately marks what
shipped), land ENH-003…ENH-008 as v1.1.0, and treat ENH-001 + ENH-002
as **v2.0.0** with a coordinated `PdxAuditRecord@0.2` schema and a
paideia-os daemon companion. Do not let R49-PREP-007 freeze `@0.1`.
