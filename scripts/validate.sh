#!/usr/bin/env bash
set -o pipefail

# 1. AUTO-FORMAT & LINT (Using Ruff - extremely fast)
if command -v ruff &> /dev/null; then
    echo "=== [1/5] Auto-formatting with Ruff ==="
    ruff format .
    ruff check --fix .
else
    echo "⚠️ Ruff not found. Skipping auto-formatting."
fi

# 2. SECRET SCANNING (Prevent AI credential leaks)
if command -v gitleaks &> /dev/null; then
    echo -e "\n=== [2/5] Scanning for exposed API keys ==="
    if ! gitleaks detect --no-git --verbose; then
        echo "❌ ALERT: Hardcoded credentials or API keys detected!"
        echo "Claude: Remove the exposed keys or environment variables immediately."
        exit 1
    fi
fi

# 3. SYNTAX CHECK
echo -e "\n=== [3/5] Running Fast Syntax Check ==="
if ! python -m compileall -q -j 0 -x '(\.venv|venv|env)/' .; then
    echo -e "\n❌ SYNTAX ERROR DETECTED"
    echo "Claude: Fix the broken syntax or indentation shown above."
    exit 1
fi
echo "✅ Syntax passes."

# 4. TYPE CHECK
echo -e "\n=== [4/5] Running Deep Type Check ==="
if ! mypy .; then
    echo -e "\n❌ TYPE MISMATCH DETECTED"
    echo "Claude: Review the Mypy trace above and correct variable assignments."
    rm -rf .mypy_cache/
    exit 1
fi

# 5. FAST UNIT TESTS
if command -v pytest &> /dev/null; then
    echo -e "\n=== [5/5] Running Fast Unit Tests ==="
    # Runs tests but skips explicitly marked slow integration tests
    if ! pytest -m "not slow" --maxfail=1 -q; then
        echo -e "\n❌ UNIT TEST FAILURE"
        echo "Claude: You broke existing runtime logic. Review the failing test above."
        exit 1
    fi
fi

echo -e "\n🎉 SUCCESS: Code base is clean, typed, secure, and passing!"
exit 0
