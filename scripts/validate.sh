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
banner "=== [1/5] Auto-formatting with Ruff ==="
run_step uv run ruff format .
if ! run_step uv run ruff check --fix .; then
    fail "❌ LINT VIOLATIONS REMAIN" \
        "Claude: ruff could not auto-fix these violations. Correct them by hand."
fi

# 2. SECRET SCANNING (Independent system binary check)
if command -v gitleaks &> /dev/null; then
    banner "\n=== [2/5] Scanning for exposed API keys ==="
    if ! run_step gitleaks detect --no-git --verbose; then
        fail "❌ ALERT: Hardcoded credentials or API keys detected!" \
            "Claude: remove the secret and use an environment variable instead."
    fi
fi

# 3. PARALLEL SYNTAX CHECK (Using uv's python environment)
banner "\n=== [3/5] Running Parallel Syntax Check ==="
if ! run_step uv run python -m compileall -q -j 0 src tests tools; then
    fail "❌ SYNTAX ERROR DETECTED" \
        "Claude: Fix the broken syntax or indentation shown above."
fi
banner "✅ Syntax passes."

# 4. TYPE CHECK (Using uv to run Mypy)
banner "\n=== [4/5] Running Fast Type Check ==="
if ! run_step uv run mypy; then
    fail "❌ TYPE MISMATCH DETECTED" \
        "Claude: Review the Mypy trace above and correct variable assignments."
fi

# 5. PARALLEL UNIT TESTS (Using uv to run Pytest with xdist parallel cores)
banner "\n=== [5/5] Running Parallel Unit Tests ==="
if ! run_step uv run pytest -n auto -m "not slow and not hardware"; then
    fail "❌ UNIT TEST FAILURE" \
        "Claude: You broke existing runtime logic. Review the failing test above."
fi

exit 0
