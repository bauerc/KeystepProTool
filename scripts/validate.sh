#!/usr/bin/env bash
set -o pipefail

# Hooks fire from arbitrary cwds; every step below assumes the repo root.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

# 1. AUTO-FORMAT & LINT (Using uv to run Ruff)
echo "=== [1/5] Auto-formatting with Ruff ==="
uv run ruff format .
uv run ruff check --fix .

# 2. SECRET SCANNING (Independent system binary check)
if command -v gitleaks &> /dev/null; then
    echo -e "\n=== [2/5] Scanning for exposed API keys ==="
    if ! gitleaks detect --no-git --verbose; then
        echo "❌ ALERT: Hardcoded credentials or API keys detected!"
        exit 2
    fi
fi

# 3. PARALLEL SYNTAX CHECK (Using uv's python environment)
echo -e "\n=== [3/5] Running Parallel Syntax Check ==="
if ! uv run python -m compileall -q -j 0 -x '(\.venv|venv|env)/' .; then
    echo -e "\n❌ SYNTAX ERROR DETECTED"
    echo "Claude: Fix the broken syntax or indentation shown above."
    exit 2
fi
echo "✅ Syntax passes."

# 4. TYPE CHECK (Using uv to run Mypy)
echo -e "\n=== [4/5] Running Fast Type Check ==="
if ! uv run mypy; then
    echo -e "\n❌ TYPE MISMATCH DETECTED"
    echo "Claude: Review the Mypy trace above and correct variable assignments."
    rm -rf .mypy_cache/
    exit 2
fi

# 5. PARALLEL UNIT TESTS (Using uv to run Pytest with xdist parallel cores)
echo -e "\n=== [5/5] Running Parallel Unit Tests ==="
if ! uv run pytest -n auto -m "not slow and not hardware"; then
    echo -e "\n❌ UNIT TEST FAILURE"
    echo "Claude: You broke existing runtime logic. Review the failing test above."
    exit 2
fi
