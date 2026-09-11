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

if command -v gitleaks &> /dev/null; then
    banner "=== [1/3] Scanning for exposed API keys ==="
    if ! run_step gitleaks detect --no-git --verbose; then
        fail "❌ ALERT: Hardcoded credentials or API keys detected!" \
            "Claude: remove the secret and use an environment variable instead."
    fi
fi

if ! command -v swift &> /dev/null; then
    fail "❌ NO SWIFT ON PATH" \
        "Claude: install the Swift toolchain (swift/README.md §6); there is nothing to validate without it."
fi

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

banner "\n=== [2/3] Linting the Swift package ==="
if ! run_step swift_lint; then
    fail "❌ SWIFT FORMAT VIOLATIONS" \
        "Claude: from swift/, run 'swift format --in-place --recursive --parallel Sources Tests Package.swift'."
fi

banner "\n=== [3/3] Testing the Swift package ==="
if ! run_step swift_tests; then
    fail "❌ SWIFT TEST FAILURE" \
        "Claude: Review the failing Swift test above. 'swift test' builds, so this covers the build too."
fi

exit 0
