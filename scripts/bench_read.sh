#!/usr/bin/env bash
set -o pipefail

# Invoked from arbitrary cwds; every step below assumes the repo root.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

emit_json=0
case "${1-}" in
    --json) emit_json=1 ;;
    "") ;;
    *)
        echo "usage: ./scripts/bench_read.sh [--json]" >&2
        exit 2
        ;;
esac

# The tracked samples, as tests/conftest.py:SAMPLE_NAMES lists them. project_files/captures/ is
# gitignored, so a worktree or CI has only these to measure.
samples=(
    Default.KeyStepPro
    baseline.KeyStepPro
    initial_project.KeyStepPro
    project_5.KeyStepPro
    project_9.KeyStepPro
    user_empty_project.KeyStepPro
)

readings=$(mktemp) || exit 1
trap 'rm -f "$readings"' EXIT

echo "machine:  $(uname -srm)"
echo "python:   $(uv run python -V 2>&1)"
echo

for sample in "${samples[@]}"; do
    file="project_files/$sample"
    if [[ ! -f $file ]]; then
        echo "skipping $sample: not in this checkout" >&2
        continue
    fi
    echo "reading $sample ..." >&2

    if ! uv run python tools/bench_read.py --json "$file" >> "$readings"; then
        echo "bench_read.py failed on $sample" >&2
        exit 1
    fi
done

if [[ ! -s $readings ]]; then
    echo "no tracked sample projects found in project_files/" >&2
    exit 1
fi

echo
uv run python tools/bench_read.py --render < "$readings"

if ((emit_json)); then
    echo
    echo "--- raw readings ---"
    cat "$readings"
fi
