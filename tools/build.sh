#!/usr/bin/env bash
# Per-repo build script. Runs paideia-as build over every .pdx source.
#
# Profiles (LA.M2-004 / #19 Phase B):
#
#   --profile=kernel     (default; behaviour preserved byte-for-byte
#                          against the pre-Phase-B invocation shape)
#     Compiles the on-tree audit_broker.pdx + syscall_shim.pdx (which
#     issue paideia-os SC+ syscalls) and every other src/*.pdx and
#     tests/*.pdx into loose .o files under build-out/. The satellite
#     variants (*_satellite.pdx) are SKIPPED entirely under this
#     profile so their exported symbols never collide with the
#     kernel variants at any downstream link.
#
#   --profile=satellite  (Phase B; produces a link-line archive)
#     Compiles audit_broker_satellite.pdx + syscall_shim_satellite.pdx
#     (which fail-open on the broker/lookup path and JSONL-emit audit
#     records to fd 2 via Linux write(2) / getpid(2) — no paideia-os
#     kernel dependency) INSTEAD OF the on-tree kernel variants, plus
#     audit_client.pdx + audit_record.pdx + audit_hash.pdx (identical
#     in both profiles). No tests are compiled — the test harness
#     stubs assume the kernel syscall shim. All resulting .o files
#     are then packed into build-out/libpdx-audit-satellite.a via
#     `ar rcs`; ld --gc-sections can prune unused entry points from
#     an archive, but not from loose objects, so this is the
#     link-line-friendly form satellite build.sh scripts consume via
#     `--extra-archive PATH`.
#
# Resolves paideia-as via (in order):
#   1. $PAIDEIA_AS env var
#   2. paideia-os checkout sibling to this repo: ../paideia-os/tools/paideia-as/target/release/paideia-as
#   3. $HOME/Development/PaideiaOS/tools/paideia-as/target/release/paideia-as
#   4. paideia-as on $PATH (must be >= 0.21.0)
#
# Requires paideia-as >= 0.21.0. The 0.9.0 shipped in $PATH by default does not
# accept the syntax used in this repo.

set -euo pipefail
cd "$(dirname "$0")/.."

MIN_VERSION="0.21.0"

# ------------------------------------------------------------------
# Argument parsing. Only --profile is currently accepted.
# ------------------------------------------------------------------
PROFILE="kernel"
for arg in "$@"; do
    case "$arg" in
        --profile=kernel)    PROFILE="kernel" ;;
        --profile=satellite) PROFILE="satellite" ;;
        --help|-h)
            cat <<'EOF'
usage: tools/build.sh [--profile={kernel,satellite}]

  --profile=kernel     (default) compile every src/*.pdx and tests/*.pdx
                       into loose .o files. Excludes *_satellite.pdx.
  --profile=satellite  compile the satellite-linkable subset (kernel
                       broker + syscall shim replaced by their
                       *_satellite variants) and pack the results into
                       build-out/libpdx-audit-satellite.a. Tests are
                       skipped under this profile.
EOF
            exit 0
            ;;
        *)
            echo "[build] FAIL: unknown argument '$arg' (try --help)" >&2
            exit 2
            ;;
    esac
done

resolve_paideia_as() {
    if [ -n "${PAIDEIA_AS:-}" ] && [ -x "$PAIDEIA_AS" ]; then
        echo "$PAIDEIA_AS"; return
    fi
    for cand in \
        "../paideia-os/tools/paideia-as/target/release/paideia-as" \
        "$HOME/Development/PaideiaOS/tools/paideia-as/target/release/paideia-as"
    do
        if [ -x "$cand" ]; then
            echo "$cand"; return
        fi
    done
    if command -v paideia-as >/dev/null 2>&1; then
        command -v paideia-as; return
    fi
    return 1
}

version_ge() {
    # $1 = have, $2 = want ; returns 0 if have >= want
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

PA="$(resolve_paideia_as || true)"
if [ -z "$PA" ]; then
    echo "[build] FAIL: paideia-as not found. Set PAIDEIA_AS or clone paideia-os as a sibling." >&2
    exit 2
fi
VER="$("$PA" --version | awk '{print $2}')"
if ! version_ge "$VER" "$MIN_VERSION"; then
    echo "[build] FAIL: paideia-as $VER is too old, need >= $MIN_VERSION (found $PA)" >&2
    exit 2
fi
echo "[build] profile=$PROFILE paideia-as $VER at $PA"

BUILD_DIR="build-out"
mkdir -p "$BUILD_DIR"

# ------------------------------------------------------------------
# Per-profile inclusion / exclusion list.
#   kernel    profile: skip *_satellite.pdx sources; keep everything else.
#   satellite profile: skip the kernel-only audit_broker.pdx + syscall_shim.pdx;
#                      keep audit_client / audit_record / audit_hash + the two
#                      *_satellite.pdx variants.
# ------------------------------------------------------------------
SAT_ONLY=(audit_broker_satellite.pdx syscall_shim_satellite.pdx)
KERNEL_ONLY=(audit_broker.pdx syscall_shim.pdx)

case "$PROFILE" in
    kernel)   SKIP_FILES=("${SAT_ONLY[@]}") ;;
    satellite) SKIP_FILES=("${KERNEL_ONLY[@]}") ;;
esac

should_skip() {
    local base="$1"
    local s
    for s in "${SKIP_FILES[@]}"; do
        if [ "$base" = "$s" ]; then return 0; fi
    done
    return 1
}

FAIL=0
COUNT=0
BUILT_OBJS=()

for pdx in src/*.pdx; do
    [ -f "$pdx" ] || continue
    base="$(basename "$pdx")"
    if should_skip "$base"; then
        continue
    fi
    COUNT=$((COUNT + 1))
    obj="$BUILD_DIR/${base%.pdx}.o"
    if ! "$PA" build --emit elf64 "$pdx" -o "$obj" 2>&1; then
        FAIL=$((FAIL + 1))
    else
        BUILT_OBJS+=("$obj")
    fi
done

# Tests only compile under the kernel profile. The satellite build has
# no test set — the in-tree test harness stubs (tests/syscall_shim_stub.
# pdx) assume the kernel syscall shim contract, which the satellite
# variants deliberately diverge from.
if [ "$PROFILE" = "kernel" ] && [ -d tests ]; then
    for pdx in tests/*.pdx; do
        [ -f "$pdx" ] || continue
        COUNT=$((COUNT + 1))
        obj="$BUILD_DIR/tests-$(basename "$pdx" .pdx).o"
        if ! "$PA" build --emit elf64 "$pdx" -o "$obj" 2>&1; then
            FAIL=$((FAIL + 1))
        fi
    done
fi

echo "[build] $COUNT source(s), $FAIL failure(s)"
[ "$FAIL" -eq 0 ] || exit 1

# ------------------------------------------------------------------
# Satellite profile: pack the built object set into a single archive so
# satellite ld lines can consume it via `--extra-archive PATH` and let
# `ld --gc-sections` prune unused entry points at final link.
# ------------------------------------------------------------------
if [ "$PROFILE" = "satellite" ]; then
    ARCHIVE="$BUILD_DIR/libpdx-audit-satellite.a"
    rm -f "$ARCHIVE"
    if ! command -v ar >/dev/null 2>&1; then
        echo "[build] FAIL: 'ar' not on PATH; satellite profile needs binutils" >&2
        exit 2
    fi
    ar rcs "$ARCHIVE" "${BUILT_OBJS[@]}"
    echo "[build] packed ${#BUILT_OBJS[@]} object(s) into $ARCHIVE"
fi

echo "[build] OK"
