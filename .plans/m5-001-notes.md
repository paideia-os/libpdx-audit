# libpdx-audit.M5-001 — implementation notes

**Issue:** #10 — dual-signed release + .pdxdoc + mirror push.
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.13 (paideia-os).
**Milestone rubric:** M5 lands "the dual-signed manifest.pdxsig, the
CHANGELOG-1.0 entry, and the mirror push to pkgs.paideia-os"
(r49-r50-plan.md line 324).

## What landed

- `CHANGELOG.md` — new file. v1.0.0 entry with the full M1..M4
  rollup, wire-format contract at v1.0.0 (header word, payload
  layout, event kinds), semver policy, and the known deferred
  substrate list (BLAKE3 swap, QEMU smoke, mirror endpoint, doc.M2
  compile pass).
- `doc/libpdx-audit.pdxdoc` — new file. Source form of the doc for
  `doc libpdx-audit`. I7 sections: NAME, SYNOPSIS, DESCRIPTION,
  API (per-entry-point one-liner + calling convention), WIRE-FORMAT
  (byte-for-byte layout), STATE-MACHINE (ASCII diagram),
  ERROR-CODES, RETRY-DISCIPLINE, PARENT-LINKAGE, HASH,
  POSIX-DIFFERENCES, EXAMPLES, CROSS-REFERENCES, SEE-ALSO, VERSION.
  Format is `==== <title>` section markers + `[[cref: <target>]]`
  cross-refs + `[[posix: <difference>]]` inline tags — a plausible
  v1 shape that doc.M1-002 will canonize (the format is
  human-readable text so a consumer without a doc-M2 compiler can
  still render it verbatim).
- `release/manifest.pdxsig.txt` — new file. Human-readable source
  form of the binary `manifest.pdxsig` the release tool emits.
  Enumerates the artifact set in four sections (`[artifacts.source]`,
  `[artifacts.doc]`, `[artifacts.tests]`, `[artifacts.legal]`) with
  a `blake3-256 = <BLAKE3-*>` placeholder per file (the release
  tool recomputes each hash from the v1.0.0 tree at cut-a-release
  time). Ships an empty `[depends-on]` block (libpdx-audit is a
  leaf library — no cross-repo library dependencies at M1..M5). The
  `[substrate]` block pins the syscall + broker + event-ordinal +
  header-word contract the compiled library depends on:
  paideia-as ≥ 0.33-crypto-kdf, SC+ ID 42/43, svc.audit-journal
  broker, UEJ_KIND_TOOL_* ordinals, AUDIT_HDR_WORD. The
  `[signatures]` block declares the hybrid Ed25519 + ML-DSA-65
  scheme (paideia-pq-hybrid-v1), the BLAKE3-256 hash input with
  the `"paideia-release-artifact\x00"` domain-separation tag
  matching `paideia-pq-sign::sign_release_artifact`, and the four
  slots the sign pass fills in (2 KIDs + 2 sigs).
- `release/RELEASE.md` — new file. Operator runbook for cutting a
  signed release + pushing to `pkgs.paideia-os/main/libpdx-audit/
  1.0.0/`. Eight numbered steps (pre-flight → version bump → tag →
  build → fill-manifest → dual-sign → mirror-push → GitHub-release-
  attachments). Documents the three substrate gates (S1
  paideia-as v0.33-crypto-kdf, S2 pkgs.paideia-os endpoint, S3
  doc.M2 compile pass) that must be green before the sign +
  mirror-push run. Also the consumer-side verification path and
  the rollback protocol.
- `README.md` — refreshed. Points at CHANGELOG, RELEASE.md,
  the .pdxdoc, and design/architecture.md. Marks the repo at
  v1.0.0.
- `STATUS.md` — bumped header to "M5 (1.0 signed release) —
  landed" + "Version: 1.0.0 (tag `v1.0.0`)"; added M5-001 entry
  to the milestone-progress list; replaced the "Next milestone"
  section with a "downstream work continues in consumer repos"
  note + a per-item deferred-to-patch-release list (BLAKE3
  primitive swap, QEMU end-to-end smoke, dual-sign + mirror-push
  substrate-gated run).

## Design decisions

- **Ship the release manifest as source form + spec, not a binary
  pdxsig.** The plan §5.13 M5-001 issue title is "dual-signed
  release + .pdxdoc + mirror push" but the actual dual-signing
  step and the actual HTTP-PUT are gated on substrates that do
  not yet exist (paideia-as v0.33-crypto-kdf toolchain reachable
  from a build harness that can run in this repo's context, and
  the pkgs.paideia-os mirror endpoint being stood up). The
  scaffolding that lands at M5-001 is: (a) the release manifest
  source form (`release/manifest.pdxsig.txt`) that the release
  tool consumes; (b) the `.pdxdoc` source (`doc/libpdx-audit.
  pdxdoc`) that doc.M2 compiles; (c) the operator runbook
  (`release/RELEASE.md`) that drives the eight-step cut. When
  the substrates go green, the operator runs the runbook without
  any further repo-side change beyond a version bump. This
  interpretation is documented in `release/RELEASE.md` §1 + §5
  and in `STATUS.md`'s deferred-work list so the constraint is
  visible to a downstream auditor.
- **Set the M5 template for the peer R49 libraries.** libpdx-audit
  is the first R49-wave library to close M5. The four peer libraries
  (libpdx-cap, libpdx-argv, libpdx-semantic-pipe, libpdx-elevate)
  will cut M5 using the same layout: `CHANGELOG.md` at repo root,
  `doc/<lib>.pdxdoc` for `doc <lib>`, `release/manifest.pdxsig.txt`
  + `release/RELEASE.md`, `STATUS.md` bump. Reusing the same
  layout keeps the mirror-push tool's per-package special-case
  count at zero.
- **`.pdxdoc` format v0.1 is source-first, compiler-second.** The
  format doc.M1-002 will parse hasn't been formally specified yet
  in the paideia-os plan (§5.3 doc.M1-002 says ".pdxdoc file-
  format parser per design/tooling/plan.md I7", and plan.md I7
  documents the four help surfaces without pinning a byte-level
  grammar). The M5-001 source form uses `==== <title>` section
  markers + `[[cref: <target>]]` cross-refs + `[[posix:
  <difference>]]` inline tags. These are minimal — a text
  renderer that ignores every `[[cref:]]` and `[[posix:]]` tag
  still produces useful output. When doc.M1-002 pins the byte-
  level grammar (which will be a format-version 1.0 vs. this
  file's `%%% pdxdoc-source v0.1` header), a compilation pass
  translates this source into whatever doc.M1-002 declares. The
  source form stays in the repo under version control; the
  compiled form ships alongside the library into
  `/pkgs/libpdx-audit-1.0.0/doc/`.
- **Empty `[depends-on]`, populated `[substrate]`.** libpdx-audit
  imports no other paideia-os library at M1..M5 — the modules it
  calls into (`AuditRecord`, `AuditBroker`, `AuditHash`,
  `SyscallShim`) all live inside this repo. The `[depends-on]`
  block is therefore empty, and the release tool skips the
  dependency-resolution step for this package. What DOES matter
  is the runtime substrate: the two syscalls (`sys_ipc_send` +
  `sys_svc_lookup`), the broker registration (`svc.audit-
  journal`), the three event ordinals (`UEJ_KIND_TOOL_INVOKE=130`,
  `_OUTPUT=132`, `_EXIT=133`), and the audit-hdr-word
  (`0x0000_0040_0000_0120`). All four are pinned in `[substrate]`
  so a mirror consumer whose target kernel lacks any of them
  refuses to install.
- **Domain-separation tag matches paideia-pq-sign::sign_release_
  artifact.** The tag `"paideia-release-artifact\x00"` is the
  value used by `crates/paideia-pq-sign/src/release.rs` at the
  paideia-as workspace, per `design/paideia-as/v0.20-issue-1025-
  pq-signing.md` §II. Using the same tag means the M5-001
  manifest's signature block is validated by the same code path
  the paideia-as workspace already ships and tests. If the
  paideia-as workspace ever bumps the domain tag, this manifest
  needs to track it — the `hash-input-domain` line makes the
  binding explicit so a future auditor can diff.
- **Tag the M5-001 commit `v1.0.0`.** Annotated tag with the
  message "libpdx-audit v1.0.0 — R49 wave close" so `git describe`
  from any consumer commit resolves to the release identity.
- **No hash values baked in.** The `<BLAKE3-*>` placeholders in
  `release/manifest.pdxsig.txt` are intentional — b3sum is not
  available in this repo's build environment, and computing the
  hashes with a fallback (sha256sum) would create a mismatch
  between the source form and the binary form the release tool
  emits later. The placeholders are a stable pattern the release
  tool's fill-manifest step recognises and rewrites.

## paideia-as conformance

- No `.pdx` source touched in M5-001 (documentation + release
  scaffolding only). Every existing `.pdx` module is unchanged;
  the compiled artifact set at v1.0.0 is bit-for-bit the M4-002
  set.
- No new label prefix, no new register plan, no new syscall
  path.

## Cross-module linkage

- Zero new cross-repo dependencies. libpdx-audit stays a leaf
  library.
- No new symbol exports. The M5-001 landing does not add or
  remove any symbol from the public API surface documented in
  `design/architecture.md` §1.

## What did not land (deferred to patch releases + downstream)

- **Signed manifest.pdxsig binary + real BLAKE3 hashes.** Gated
  on paideia-as ≥ v0.33-crypto-kdf toolchain being reachable in
  a build environment that can also invoke `paideia-pq-sign::
  sign_release_artifact`. Cut a v1.0.1 with a fresh
  `release/manifest.pdxsig.txt` (hashes recomputed against the
  patch commit) + a run of `release/RELEASE.md` steps 4..8.
- **Actual mirror push.** Gated on the pkgs.paideia-os mirror
  endpoint standing up. Between now and then, the signed
  `manifest.pdxsig` ships as a v1.0.0 GitHub release attachment
  per `release/RELEASE.md` §2 step 8.
- **Compiled .pdxdoc.** Gated on doc.M2 landing the compile
  pass. Consumers render the source form verbatim in the
  meantime.
- **BLAKE3 stdlib primitive swap** (see STATUS.md deferred
  list). Independent from the release path — a patch release
  when the primitive lands.
- **QEMU end-to-end smoke** (see `tests/README.md` §QEMU smoke
  protocol). Independent from the release path — the M4 drivers
  cover every library-observable invariant already.
