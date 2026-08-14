#!/usr/bin/env bash
set -o pipefail

# Hooks fire from arbitrary cwds; every step below assumes the repo root.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

hook_mode=0
already_blocked=0
if [[ ${1-} == "--hook" ]]; then
    hook_mode=1
    payload=$(cat)
    # Set by Claude Code when this same hook already blocked the stop once.
    if grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$payload"; then
        already_blocked=1
    fi
fi

log=$(mktemp) || exit 1
trap 'rm -f "$log"' EXIT

banner() { ((hook_mode)) || echo -e "$1"; }

run_step() {
    if ((hook_mode)); then
        "$@" > "$log" 2>&1
    else
        "$@" 2>&1 | tee "$log"
    fi
}

# First block: stderr + exit 2, the only channel Claude sees on a blocked stop.
# Second time round: stdout + exit 0, so a red build cannot wedge the session.
fail() {
    local headline=$1 instruction=$2 fd=2 status=2
    if ((already_blocked)); then
        fd=1
        status=0
        headline="⚠️  Still failing after one forced fix — not blocking again."$'\n'"$headline"
    fi
    {
        echo -e "\n$headline"
        ((hook_mode)) && tail -n 60 "$log"
        echo "$instruction"
    } >&"$fd"
    exit "$status"
}

# 1. AUTO-FORMAT & LINT (Using uv to run Ruff)
banner "=== [1/8] Auto-formatting with Ruff ==="
run_step uv run ruff format .
if ! run_step uv run ruff check --fix .; then
    fail "❌ LINT VIOLATIONS REMAIN" \
        "Claude: ruff could not auto-fix these violations. Correct them by hand."
fi

# 2. SECRET SCANNING (Independent system binary check)
if command -v gitleaks &> /dev/null; then
    banner "\n=== [2/8] Scanning for exposed API keys ==="
    if ! run_step gitleaks detect --no-git --verbose; then
        fail "❌ ALERT: Hardcoded credentials or API keys detected!" \
            "Claude: remove the secret and use an environment variable instead."
    fi
fi

# 3. PARALLEL SYNTAX CHECK (Using uv's python environment)
banner "\n=== [3/8] Running Parallel Syntax Check ==="
if ! run_step uv run python -m compileall -q -j 0 src tests tools; then
    fail "❌ SYNTAX ERROR DETECTED" \
        "Claude: Fix the broken syntax or indentation shown above."
fi
banner "✅ Syntax passes."

# 4. TYPE CHECK (Using uv to run Mypy)
banner "\n=== [4/8] Running Fast Type Check ==="
if ! run_step uv run mypy; then
    fail "❌ TYPE MISMATCH DETECTED" \
        "Claude: Review the Mypy trace above and correct variable assignments."
fi

# 5. PARALLEL UNIT TESTS (Using uv to run Pytest with xdist parallel cores)
banner "\n=== [5/8] Running Parallel Unit Tests ==="
if ! run_step uv run pytest -n auto -m "not slow and not hardware"; then
    fail "❌ UNIT TEST FAILURE" \
        "Claude: You broke existing runtime logic. Review the failing test above."
fi

# 6. SWIFT PACKAGE (M8 port; skipped where the toolchain is absent, as with gitleaks above)
if command -v swift &> /dev/null; then
    banner "\n=== [6/8] Linting and testing the Swift package ==="

    # Command Line Tools ship Swift Testing as a framework but, unlike a full Xcode, leave it off
    # the compiler's search path and off the runtime's. Worse, the _Testing_Foundation cross-import
    # overlay has no .swiftinterface there at all, so any test importing both Testing and Foundation
    # fails to build without the frontend flag. Measured on CLT 6.2.3; under Xcode this stays empty.
    swift_flags=()
    developer_dir=$(xcode-select -p 2> /dev/null)
    clt_frameworks="$developer_dir/Library/Developer/Frameworks"
    if [[ $developer_dir == */CommandLineTools && -d $clt_frameworks/Testing.framework ]]; then
        swift_flags=(
            -Xswiftc -F -Xswiftc "$clt_frameworks"
            -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
            -Xlinker -rpath -Xlinker "$clt_frameworks"
        )
    fi

    swift_lint() {
        (cd swift && swift format lint --strict --recursive --parallel Sources Tests Package.swift)
    }
    swift_tests() { (cd swift && swift test "${swift_flags[@]}"); }

    if ! run_step swift_lint; then
        fail "❌ SWIFT FORMAT VIOLATIONS" \
            "Claude: from swift/, run 'swift format --in-place --recursive --parallel Sources Tests Package.swift'."
    fi
    if ! run_step swift_tests; then
        fail "❌ SWIFT TEST FAILURE" \
            "Claude: Review the failing Swift test above. 'swift test' builds, so this covers the build too."
    fi

    # 7. PORT PARITY (M10 onwards). Each port milestone ends in a byte-comparison against the
    # Python rather than in a feature, and this is M10's: the same file through both readers and
    # both output modes has to come out identical, character for character. The Swift CLI is gated
    # off Linux, so CI cannot run this -- it is a dev-machine gate only.
    banner "\n=== [7/8] Comparing ksp-swift-cli dump against ksp-dump ==="
    if ! run_step ./scripts/port_parity.sh; then
        fail "❌ THE TWO PORTS DISAGREE" \
            "Claude: the Swift dump no longer reproduces the Python's output. The Python is the reference implementation; fix the Swift."
    fi
    banner "✅ Both ports agree."

    # 8. WRITER PARITY (M11 onwards). The same again for the write path: both writers over every
    # sample, byte for byte. Needs only swiftc, since KSPKit has no dependencies -- but it writes
    # 3.5 MB files, so it stays beside port_parity as a dev-machine gate rather than a CI one.
    banner "\n=== [8/8] Comparing the Swift writer against the Python's ==="
    if ! run_step ./scripts/writer_parity.sh; then
        fail "❌ THE TWO WRITERS DISAGREE" \
            "Claude: the Swift writer no longer reproduces the Python's bytes. The Python is the reference implementation; fix the Swift."
    fi
    banner "✅ Both writers agree."
else
    banner "\n=== [6/8] No swift on PATH -- skipping the swift/ package ==="
fi

exit 0
