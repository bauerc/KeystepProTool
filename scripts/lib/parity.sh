# Sourced by the four parity gates. Nothing here compares anything; it exists so that all four
# tell a comparison that broke apart from one that found a difference.

# Named after whichever gate sourced this, so a message reads as that gate's own.
parity_gate=$(basename "${BASH_SOURCE[1]}" .sh)

# What a gate exits with when the comparison never ran. `validate.sh` reads it to say so rather
# than to blame the port, and it is 2 because that is what `diff` and `cmp` already mean by it.
PARITY_BROKEN=2

# `diff` and `cmp` both answer 0 same, 1 different, 2 or more trouble -- an input that would not
# open, a pipe that died. `if ! diff ...` folds trouble in with difference, which is how a broken
# harness arrives wearing "the two ports disagree" and sends the next reader after a Swift bug that
# was never there.
#
#   compare <subject> <command...>   -> 0 same, 1 differs, 2 the comparison never happened
#
# Only the trouble path is spoken for here, and it names its subject because a gate that breaks
# tends to break on every case at once: an unlabelled line repeated four hundred times says less
# than one. What *differs* stays the caller's to word -- that sentence is the caller's whole point.
compare() {
    local subject=$1
    shift
    "$@"
    local code=$?
    ((code < 2)) && return "$code"
    echo "$parity_gate: $subject: the comparison itself failed (exit $code)," \
        "so nothing was compared" >&2
    return "$PARITY_BROKEN"
}

# The line a gate ends on when nothing was compared. Said once, by the driver, because the worker
# that broke may be one of many and its own complaint is upstream of this.
parity_broke() {
    echo "$parity_gate: HARNESS FAILURE -- the comparison broke before it could compare, so" \
        "neither agreement nor disagreement was established. This is not a port defect and no" \
        "source change will fix it. Re-run with KSP_PARITY_JOBS=1." >&2
}
