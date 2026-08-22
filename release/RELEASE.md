# libpdx-audit — release + mirror-push workflow (M5-001)

**Repo:** github.com/paideia-os/libpdx-audit
**Wave:** R49 shared library
**Version at first release:** 1.0.0
**Upstream policy:** `design/tooling/plan.md` §6.3 (paideia-os) — package
repository layout; `design/02-development-environment.md` §1140 + §1164
(paideia-os) — hybrid Ed25519+ML-DSA-65 signing, release-line key
custody; `design/tooling/r49-r50-plan.md` §5.13 (paideia-os) — M5-001
scope.

This document is the operator runbook for cutting a signed release of
libpdx-audit and pushing it to the paideia-os package mirror at
`https://pkgs.paideia-os/main/libpdx-audit/<version>/`. The workflow is
identical to the peer R49-library releases (libpdx-cap, libpdx-argv,
libpdx-semantic-pipe, libpdx-elevate) — cut this one first, use it as
the template for the peers.

The workflow has two blocking substrates. Both are documented in the
"Substrate readiness" section below; the ordering rule is that the
release manifest at `release/manifest.pdxsig.txt` and the source-form
`.pdxdoc` at `doc/libpdx-audit.pdxdoc` land at M5-001 (this issue)
BEFORE either substrate is available, so a future operator can cut
the release the moment both substrates go green without any repo-side
changes beyond a version bump.

---

## 1. Substrate readiness

**S1 — paideia-as v0.33-crypto-kdf toolchain reachable.** The release
build invokes `paideia-as build` to compile `src/*.pdx` and
`tests/*.pdx` at their versioned state, and `paideia-pq-sign::sign_
release_artifact` for the dual-signature step. Both require
paideia-as ≥ 0.33 (Argon2id + ChaCha20-Poly1305 + ML-DSA-65 substrate).
STATUS.md tracks the toolchain version this repo is CI-tested against.

**S2 — `pkgs.paideia-os` mirror endpoint reachable.** The mirror does
not yet exist as of R49 close. The plan (§6.3) commits to `https://
pkgs.paideia-os/main/` as the default repo URL; the mirror-push tool
(part of the `pkg` package, pkg.M5-002) HTTP-PUTs the compiled
`pkg.tar` + `manifest.pdxsig` pair into `libpdx-audit/1.0.0/` on that
tree. Until the mirror is standing, the release is "cut but not
mirrored" — the signed `manifest.pdxsig` still lands in the GitHub
release attachment set for out-of-band consumers.

**S3 — `doc` M2 reachable.** The compiled `.pdxdoc` at
`/pkgs/libpdx-audit-1.0.0/doc/libpdx-audit.pdxdoc` is produced by the
`doc compile` subcommand of the `doc` tool at doc.M2. The source form
at `doc/libpdx-audit.pdxdoc` in this repo is the input; the compiled
form is deterministic given the source. Until doc.M2 lands the
release attachment set includes the source form only, and consumers
render it verbatim (the format is human-readable text — the compiled
form adds cross-reference resolution, POSIX-difference indexing, and
pagination hints, none of which are required for correctness).

---

## 2. Cut-a-release procedure

The release is cut from a clean working tree at the tip of `main`, with
every open issue on the target milestone closed.

**Pre-flight.**

    git fetch origin
    git switch main
    git pull --ff-only
    git status                    # MUST be clean
    gh issue list --milestone M5 --state open --repo paideia-os/libpdx-audit
                                  # MUST be empty

**Step 1 — Version bump + CHANGELOG close.**

    # For the first release the CHANGELOG-1.0 entry landed at M5-001;
    # subsequent releases add a new entry per semver bump.
    $EDITOR CHANGELOG.md          # verify version + date at the top

**Step 2 — Tag.**

    git tag -a v1.0.0 -m "libpdx-audit v1.0.0 — R49 wave close"
    git push origin v1.0.0

**Step 3 — Build the compiled artifact set.** (Not runnable in this
repo alone — driven by the paideia-os workspace CI; documented here
so an operator without access to that workspace can reproduce.)

    paideia-as build src/audit_client.pdx  -o build/libpdx-audit.o
    paideia-as build src/audit_broker.pdx  -o build/libpdx-audit.o
    paideia-as build src/audit_record.pdx  -o build/libpdx-audit.o
    paideia-as build src/audit_hash.pdx    -o build/libpdx-audit.o
    paideia-as build src/syscall_shim.pdx  -o build/libpdx-audit.o
    paideia-as link  build/libpdx-audit.o  -o build/libpdx-audit.so
    doc compile      doc/libpdx-audit.pdxdoc -o build/libpdx-audit.pdxdoc

**Step 4 — Recompute the manifest.** The release tool reads
`release/manifest.pdxsig.txt`, walks the `[artifacts.*]` sections, and
recomputes every `blake3-256 = <BLAKE3-*>` placeholder from the on-disk
tree at the v1.0.0 tag. Output is `build/manifest.pdxsig.filled.txt` —
identical structure, placeholders resolved.

    paideia-release fill-manifest \
        --source release/manifest.pdxsig.txt \
        --tree   . \
        --tag    v1.0.0 \
        --output build/manifest.pdxsig.filled.txt

**Step 5 — Dual-sign.** Two signature passes, one Ed25519 and one
ML-DSA-65, over the SAME canonical byte-stream (the manifest body
before the `[signatures]` marker, hashed with BLAKE3-256 with the
domain-separation tag `"paideia-release-artifact\x00"`).

    paideia-release sign \
        --manifest build/manifest.pdxsig.filled.txt \
        --key-ed25519  release-line-ed25519.sk \
        --key-ml-dsa65 release-line-ml-dsa-65.sk \
        --output   build/manifest.pdxsig

Key custody is per `design/02-development-environment.md` §1164:
hardware-backed in CI (TPM 2.0 on the release runner or a cloud KMS
that supports ML-DSA-65 once one becomes available — as of R49 the
KMS-support question is a documented TODO).

**Step 6 — Mirror push.** HTTP-PUT the compiled artifacts plus the
signed manifest into the mirror tree.

    paideia-release mirror-push \
        --repo   https://pkgs.paideia-os/main/ \
        --pkg    libpdx-audit \
        --version 1.0.0 \
        --files  build/libpdx-audit.so \
                 build/libpdx-audit.pdxdoc \
                 caps.decl \
                 build/manifest.pdxsig

Expected mirror layout after push (per `design/tooling/plan.md` §6.4):

    /pkgs/libpdx-audit-1.0.0/
        lib/libpdx-audit.so
        doc/libpdx-audit.pdxdoc
        caps.decl
        manifest.pdxsig
    /bin/  (no entry — libpdx-audit is a library, not a tool)

**Step 7 — Update `index.pdxsig`.** The mirror-level index appends a
`{name=libpdx-audit, version=1.0.0, blake3=<manifest-hash>}` tuple.
The mirror-push tool does this atomically as part of Step 6.

**Step 8 — GitHub release.** Attach `build/manifest.pdxsig`,
`build/libpdx-audit.so`, `build/libpdx-audit.pdxdoc`, and `caps.decl`
to the `v1.0.0` GitHub release. This is the fallback consumer path
for downstreams that have not configured a paideia-os mirror.

    gh release create v1.0.0 \
        --title "libpdx-audit v1.0.0" \
        --notes-file CHANGELOG.md \
        build/manifest.pdxsig \
        build/libpdx-audit.so \
        build/libpdx-audit.pdxdoc \
        caps.decl

---

## 3. Verification (consumer side)

`pkg install libpdx-audit` walks the mirror row's manifest and
verifies both signatures (AND-semantics per the hybrid scheme —
Ed25519 covers the classical adversary; ML-DSA-65 covers the
post-quantum adversary). Any single-signature failure REJECTS the
package.

    pkg install libpdx-audit --verify-only     # dry run, no install
    pkg keys show paideia-release-line          # inspect the signer

The `paideia_root_pk` fingerprint is the root of the release-key
trust chain — `pkg keys` displays it (pkg.M5-001 ships that command).

---

## 4. Rollback

If a defect is discovered post-mirror-push, `paideia-release rollback`
marks the version as withdrawn in `index.pdxsig` (a new
`{withdrawn=true}` field) and clients treat the version as
uninstallable but keep it visible for `pkg keys audit` walks. The
artifacts are NOT deleted — retention is the auditor's tool. A new
version is cut per Section 2.

---

## 5. What lands at M5-001 (this milestone)

Repo-side, M5-001 lands the source form of the release:

- `CHANGELOG.md` — v1.0.0 entry summarising M1..M4.
- `doc/libpdx-audit.pdxdoc` — source-form `.pdxdoc` for `doc
  libpdx-audit`.
- `release/manifest.pdxsig.txt` — release manifest source form.
- `release/RELEASE.md` — this document.
- `STATUS.md` — M5-001 marked landed.
- Git tag `v1.0.0` on the M5-001 commit.

The actual dual-sign + mirror-push run happens when substrates S1
and S2 (Section 1) go green in the paideia-os workspace CI; the
runbook above drives it without any further repo-side change.
