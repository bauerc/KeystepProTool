#!/usr/bin/env bash
# M10's acceptance gate: ksp-swift-cli must reproduce ksp-dump exactly.
#
# The ROADMAP has each port milestone (M8-M12) end in a byte-comparison against the Python rather
# than in a feature, because the risk in the port is not discovery -- nothing is left to
# reverse-engineer -- but thousands of lines of hand-converted arithmetic that look correct on
# inspection. A diff against the reference implementation is the only thing that catches those.
#
# Both output modes, because they exercise different halves: --json pins the decoded model and the
# key order, the tree pins the number formatting and the diagnostic wording.
#
# HOME is redirected for both sides so neither picks up a personal ~/.config drum map: the run has
# to mean the same thing on every machine.
#
# The twelve comparisons run in parallel, for the reason midi_parity.sh explains at more length:
# each one reads a 3.5 MB project through both ports, so the cost is the reading and not the
# process, and they were already independent of one another. KSP_PARITY_JOBS=1 restores the serial
# order.
set -o pipefail

# Absolute, because this re-invokes itself as the per-comparison worker.
self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

swift_cli=swift/.build/debug/ksp-swift-cli
if [[ ! -x $swift_cli ]]; then
    echo "port_parity: $swift_cli is not built; run 'swift build' from swift/" >&2
    exit 1
fi

# One comparison, invoked as `$self --one <sandbox> <index>|<project>|<mode>`. Its two streams are
# captured so the driver can replay them in index order rather than as they finish.
if [[ ${1-} == "--one" ]]; then
    sandbox=$2
    IFS='|' read -r index project mode <<< "$3"
    {
        # shellcheck disable=SC2086 # an empty $mode must expand to no argument at all
        if ! diff -u \
            <(HOME=$sandbox uv run ksp-dump "$project" $mode) \
            <(HOME=$sandbox "$swift_cli" dump "$project" $mode); then
            echo "port_parity: $(basename "$project") differs (${mode:-tree})" >&2
            exit 1
        fi
    } > "$sandbox/cmp-$index.out" 2> "$sandbox/cmp-$index.err"
    exit 0
fi

sandbox=$(mktemp -d) || exit 1
trap 'rm -rf "$sandbox"' EXIT

status=0
count=0
comparisons=0
list=$sandbox/comparisons
for project in project_files/*.KeyStepPro; do
    count=$((count + 1))
    for mode in --json ""; do
        printf '%s|%s|%s\0' "$comparisons" "$project" "$mode" >> "$list"
        comparisons=$((comparisons + 1))
    done
done

if ((comparisons)); then
    # getconf rather than nproc: macOS ships no nproc, and this has to run on both.
    jobs=${KSP_PARITY_JOBS:-$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 4)}
    xargs -0 -P "$jobs" -I{} "$self" --one "$sandbox" {} < "$list" || status=1
    for ((i = 0; i < comparisons; i++)); do
        [[ -s $sandbox/cmp-$i.out ]] && cat "$sandbox/cmp-$i.out"
        [[ -s $sandbox/cmp-$i.err ]] && cat "$sandbox/cmp-$i.err" >&2
    done
fi

((status)) || echo "port_parity: both ports agree on $count projects, tree and --json"
exit "$status"
