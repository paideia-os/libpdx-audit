# libpdx-audit — status

**Wave:** R49 shared library
**Current milestone:** M3 (semantic-pipe / audit integration) — in progress

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

## Upstream design

`design/tooling/r49-r50-plan.md` §3.4 + §5.13 in the
[paideia-os](https://github.com/paideia-os/paideia-os) repo carries the
wave-level rationale and the full milestone breakdown. See
`design/architecture.md` in this repo for the internal shape.

## Next milestone

M4 — Tests + smoke. Begin/record/commit round-trip (M4 open-ended);
broker-unavailable refusal (M4-001: tool exits 3, no output); backoff
correctness (3 retries); parent-child linkage against a shell trace;
audit-journal replay against a known trace (M4-002). Depends on the
R49-PREP-007 kernel-side ordinal split reaching a runnable daemon
body so the replay can be verified end-to-end.
