#!/usr/bin/env bash
# M12's acceptance gate: the two ports must convert alike in both directions.
#
# The ROADMAP has each port milestone end in a comparison against the Python rather than in a
# feature. M12 hand-converts ~2,500 lines of tick arithmetic, where Python and Swift disagree on
# floor division, on banker's rounding and on sort stability, and where a wrong constant produces a
# file that loads fine and plays wrong. Re-deriving each unit test by hand would catch less of that
# than running both implementations over every fixture and diffing, which is why this exists before
# either port does.
#
# Four things are compared for every case, and any one of them disagreeing fails it: the exit code,
# stdout, stderr and the artifact. Comparing the exit code and the streams is what makes it safe to
# throw the whole corpus at this, including files neither tool is expected to convert -- a shared
# refusal, worded the same way, is agreement.
#
# The export direction compares **parsed events, not bytes**, and the reason is not ours: mido emits
# MIDI running status (`write_track` reuses the status byte) where swift-midi-file's encoder always
# writes it in full -- its Track+Encoding.swift carries a TODO saying so. Consecutive note-ons on
# one channel are ubiquitous, so the two writers differ on the bytes of nearly every file while
# agreeing on every event in it. tools/midi_events.py is the level the comparison moves up to. The
# import direction needs no such concession: it writes .KeyStepPro files through the M11 writer,
# which is already pinned byte-identical, so those get a real cmp.
#
# HOME is redirected for both sides so neither picks up a personal ~/.config drum map: the run has
# to mean the same thing on every machine.
#
# The cases are run in parallel, because there are over a hundred of them and each one costs about
# half a second -- not in process startup, which is 26ms for `uv run` and 11ms for the Swift CLI,
# but in parsing or writing a 3.5 MB project on both sides. Serially that was 44s of a 59s Stop
# hook; across the cores it is ten. Every case was already hermetic, so this changes the schedule
# and nothing else: each gets its own directory, its own pair of log files, and the four
# comparisons it always made. Set KSP_PARITY_JOBS=1 to get the old serial order back when a
# failure is easier to read that way.
set -o pipefail

# Absolute, because this re-invokes itself as the per-case worker and the cd below would otherwise
# strip a relative $0 of its meaning.
self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

swift_cli=swift/.build/debug/ksp-swift-cli
if [[ ! -x $swift_cli ]]; then
    echo "midi_parity: $swift_cli is not built; run 'swift build' from swift/" >&2
    exit 1
fi

# ---------------------------------------------------------------------------- the per-case worker
#
# Invoked as `$self --case <sandbox> <index>|<direction>|<label>|<args>`, one process per case, and
# reached only from the xargs below. It writes nothing to its own stdout or stderr: both are
# redirected into per-case files that the driver replays in index order once every case is done, so
# a failure reads the same whichever order the cases happened to finish in. That ordering is
# load-bearing -- validate.sh surfaces a blocked Stop by tailing 60 lines of this.
if [[ ${1-} == "--case" ]]; then
    sandbox=$2
    IFS='|' read -r index direction label args <<< "$3"

    dir=$sandbox/case-$index
    mkdir -p "$dir/py" "$dir/sw" || exit 1

    # Both sides write to the same file name under a different directory, and the directory is
    # filtered back out of their output. Otherwise every summary line would differ on the path
    # alone. The leading program name is normalised for the same reason, and only the leading one:
    # the two tools genuinely have different names -- `ksp2midi` against `ksp-swift-cli export` --
    # and that is not a defect to fix. Everything after the prefix is still compared exactly, which
    # is where all the meaning is.
    scrub() {
        sed -E -e "s|$dir/py/|<out>/|g" -e "s|$dir/sw/|<out>/|g" \
            -e "s|$sandbox|<sandbox>|g" \
            -e "s|^(ksp2midi\|midi2ksp\|ksp-swift-cli (export\|convert)): |<prog>: |" "$1"
    }

    case $direction in
        export) name=out.mid python=ksp2midi swift=export ;;
        # --split takes a directory, so -o is the case directory itself and nothing is appended.
        split) name="" python=ksp2midi swift=export ;;
        import) name=out.KeyStepPro python=midi2ksp swift=convert ;;
    esac

    failed=0
    # Everything from here on is captured. Keeping the two streams apart rather than merging them
    # preserves which of the two a line came from, which is all that was ever distinguishable:
    # diff writes to stdout and the summaries to stderr, and they were separately buffered before.
    {
        # shellcheck disable=SC2086 # $args is a flag list that must word-split into arguments
        HOME=$sandbox uv run "$python" $args -o "$dir/py/$name" > "$dir/py.out" 2> "$dir/py.err"
        py_code=$?
        # shellcheck disable=SC2086 # as above
        HOME=$sandbox "$swift_cli" "$swift" $args -o "$dir/sw/$name" > "$dir/sw.out" 2> "$dir/sw.err"
        sw_code=$?

        if [[ $py_code != "$sw_code" ]]; then
            echo "midi_parity: $label: exit code $py_code (python) vs $sw_code (swift)" >&2
            failed=1
        fi
        for stream in out err; do
            if ! diff -u <(scrub "$dir/py.$stream") <(scrub "$dir/sw.$stream"); then
                echo "midi_parity: $label: std$stream differs" >&2
                failed=1
            fi
        done

        # A shared refusal has no artifact to compare, and that is a pass, not a skip.
        if ((py_code == 0 && sw_code == 0)); then
            case $direction in
                export)
                    if ! diff -u \
                        <(uv run python tools/midi_events.py "$dir/py/$name") \
                        <(uv run python tools/midi_events.py "$dir/sw/$name"); then
                        echo "midi_parity: $label: the MIDI events differ" >&2
                        failed=1
                    fi
                    ;;
                split)
                    if ! diff -u <(ls "$dir/py") <(ls "$dir/sw"); then
                        echo "midi_parity: $label: the split file names differ" >&2
                        failed=1
                    fi
                    for piece in "$dir/py"/*.mid; do
                        [[ -e $piece ]] || continue
                        piece=$(basename "$piece")
                        if ! diff -u \
                            <(uv run python tools/midi_events.py "$dir/py/$piece") \
                            <(uv run python tools/midi_events.py "$dir/sw/$piece" 2> /dev/null); then
                            echo "midi_parity: $label: $piece differs" >&2
                            failed=1
                        fi
                    done
                    ;;
                import)
                    if ! cmp "$dir/py/$name" "$dir/sw/$name"; then
                        echo "midi_parity: $label: the written project differs" >&2
                        failed=1
                    fi
                    ;;
            esac
        fi
    } > "$sandbox/case-$index.out" 2> "$sandbox/case-$index.err"

    # The 3.5 MB artifacts go as soon as the case is judged: at ten cases in flight the sandbox
    # would otherwise grow to the size of the whole corpus several times over. The logs live
    # outside the directory, so the driver can still replay them.
    rm -rf "$dir"
    exit "$failed"
fi

# ----------------------------------------------------------------------------------- the driver
sandbox=$(mktemp -d) || exit 1
trap 'rm -rf "$sandbox"' EXIT

cases=0
list=$sandbox/cases

# Queue one case.
#   add <direction> <label> <args...>
# where <direction> is the artifact comparison to use and <args...> is what both CLIs are given
# apart from -o, which the worker supplies. The record is NUL-terminated because a label carries
# spaces; the fields within it are '|'-separated, which nothing in the corpus or the flag lists
# contains -- asserted rather than assumed, since a stray one would silently truncate a case into a
# different one and still report a pass.
add() {
    local direction=$1 label=$2
    shift 2
    if [[ $label == *"|"* || $* == *"|"* ]]; then
        echo "midi_parity: '|' in a case record would corrupt it: $label" >&2
        exit 1
    fi
    printf '%s|%s|%s|%s\0' "$cases" "$direction" "$label" "$*" >> "$list"
    cases=$((cases + 1))
}

# The Swift subcommands arrive with M12's later PRs; the harness lands first so they are gated from
# their first commit. Until then each direction reports itself absent rather than failing, which is
# the difference between a gate that is not armed yet and one that is broken.
#
# Probing with `<name> --help` does not work: ArgumentParser answers --help before it validates the
# subcommand, so every name looks present. The root help's own SUBCOMMANDS list is the answer.
has() { "$swift_cli" --help 2> /dev/null | grep -qE "^  $1( |$)"; }

if has export; then
    for project in project_files/*.KeyStepPro; do
        add export "$(basename "$project")" "$project"
        add export "$(basename "$project") --passes 1" "$project" --passes 1
        add export "$(basename "$project") --no-swing" "$project" --no-swing
        add export "$(basename "$project") --no-time-shift" "$project" --no-time-shift
        add export "$(basename "$project") --include-stale --include-disabled" \
            "$project" --include-stale --include-disabled
        add export "$(basename "$project") --drum-channel 16" "$project" --drum-channel 16
        add split "$(basename "$project") --split" "$project" --split
    done
else
    echo "midi_parity: ksp-swift-cli has no 'export' yet -- skipping the ksp2midi direction"
fi

if has convert; then
    for clip in project_files/*.mid analysis/captures/*.mid; do
        # analysis/captures/ is gitignored, so a worktree has none of it and the glob arrives
        # unexpanded. Skipping it is right rather than a gap: the captures are hardware recordings
        # that cannot be regenerated, and a machine that has them tests more than one that does not.
        [[ -e $clip ]] || continue
        add import "$(basename "$clip")" "$clip"
        add import "$(basename "$clip") --no-swing-fit" "$clip" --no-swing-fit
        add import "$(basename "$clip") --no-time-shift" "$clip" --no-time-shift
        add import "$(basename "$clip") --steps-per-beat 8" "$clip" --steps-per-beat 8
        add import "$(basename "$clip") --drum-track 1" "$clip" --drum-track 1
        add import "$(basename "$clip") --midi-track 1" "$clip" --midi-track 1
    done
else
    echo "midi_parity: ksp-swift-cli has no 'convert' yet -- skipping the midi2ksp direction"
fi

status=0
if ((cases)); then
    # getconf rather than nproc: macOS ships no nproc, and this has to run on both.
    jobs=${KSP_PARITY_JOBS:-$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 4)}
    # xargs reports 123 when any worker exited non-zero, and there is nothing else it can be here,
    # so every failure collapses to the one status this gate has.
    xargs -0 -P "$jobs" -I{} "$self" --case "$sandbox" {} < "$list" || status=1

    # Replayed in index order, so the output reads as though the cases had run one after another.
    for ((i = 0; i < cases; i++)); do
        [[ -s $sandbox/case-$i.out ]] && cat "$sandbox/case-$i.out"
        [[ -s $sandbox/case-$i.err ]] && cat "$sandbox/case-$i.err" >&2
    done
fi

((status)) || echo "midi_parity: both ports agree on $cases conversion(s)"
exit "$status"
