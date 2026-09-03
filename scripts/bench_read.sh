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

# The tracked samples, as tests/conftest.py:SAMPLE_NAMES and TestSupport.swift:Samples.names list
# them. project_files/captures/ is gitignored, so a worktree or CI has only these to measure.
samples=(
    Default.KeyStepPro
    baseline.KeyStepPro
    initial_project.KeyStepPro
    project_5.KeyStepPro
    project_9.KeyStepPro
    user_empty_project.KeyStepPro
)

# The three flags a Command Line Tools install needs, as validate.sh builds them.
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

readings=$(mktemp) || exit 1
trap 'rm -f "$readings"' EXIT

have_swift=0
command -v swift &> /dev/null && have_swift=1

echo "machine:  $(uname -srm)"
echo "python:   $(uv run python -V 2>&1)"
if ((have_swift)); then
    echo "swift:    $(swift --version 2> /dev/null | head -n 1)"
    echo "          debug configuration, the one the parity scripts build"
else
    echo "swift:    not on PATH -- measuring the Python core only"
fi
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

    ((have_swift)) || continue
    if ! output=$(
        cd swift \
            && KSP_BENCH=1 KSP_BENCH_FILE="$sample" swift test "${swift_flags[@]}" \
                --filter ReadCost 2>&1
    ) || ! grep -m1 '^{"core"' <<< "$output" >> "$readings"; then
        echo "swift test --filter ReadCost failed on $sample:" >&2
        tail -n 20 <<< "$output" >&2
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
