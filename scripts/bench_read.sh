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

# The tracked samples, as TestSupport.swift's Samples.names lists them. project_files/captures/ is
# gitignored, so a worktree or CI has only these to measure.
samples=(
    Default.KeyStepPro
    baseline.KeyStepPro
    initial_project.KeyStepPro
    project_5.KeyStepPro
    project_9.KeyStepPro
    user_empty_project.KeyStepPro
)

bench=swift/.build/bench_read
mkdir -p "$(dirname "$bench")" || exit 1
if ! swiftc -O swift/Sources/KSPKit/*.swift tools/bench_read.swift -o "$bench"; then
    echo "bench_read.swift did not compile" >&2
    exit 1
fi

readings=$(mktemp) || exit 1
trap 'rm -f "$readings"' EXIT

echo "machine:  $(uname -srm)"
echo "swift:    $(swiftc --version 2>&1 | head -n 1)"
echo

# One process per file, so a peak-memory figure belongs to one file and not the one before it.
for sample in "${samples[@]}"; do
    file="project_files/$sample"
    if [[ ! -f $file ]]; then
        echo "skipping $sample: not in this checkout" >&2
        continue
    fi
    echo "reading $sample ..." >&2

    if ! "$bench" --json "$file" >> "$readings"; then
        echo "bench_read failed on $sample" >&2
        exit 1
    fi
done

if [[ ! -s $readings ]]; then
    echo "no tracked sample projects found in project_files/" >&2
    exit 1
fi

echo
"$bench" --render < "$readings"

if ((emit_json)); then
    echo
    echo "--- raw readings ---"
    cat "$readings"
fi
