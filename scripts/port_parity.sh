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
set -o pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

swift_cli=swift/.build/debug/ksp-swift-cli
if [[ ! -x $swift_cli ]]; then
    echo "port_parity: $swift_cli is not built; run 'swift build' from swift/" >&2
    exit 1
fi

sandbox=$(mktemp -d) || exit 1
trap 'rm -rf "$sandbox"' EXIT

status=0
for project in project_files/*.KeyStepPro; do
    for mode in --json ""; do
        # shellcheck disable=SC2086 # an empty $mode must expand to no argument at all
        if ! diff -u \
            <(HOME=$sandbox uv run ksp-dump "$project" $mode) \
            <(HOME=$sandbox "$swift_cli" dump "$project" $mode); then
            echo "port_parity: $(basename "$project") differs (${mode:-tree})" >&2
            status=1
        fi
    done
done

((status)) || echo "port_parity: both ports agree on $(ls project_files/*.KeyStepPro | wc -l | tr -d ' ') projects, tree and --json"
exit "$status"
