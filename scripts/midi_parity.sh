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
set -o pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

swift_cli=swift/.build/debug/ksp-swift-cli
if [[ ! -x $swift_cli ]]; then
    echo "midi_parity: $swift_cli is not built; run 'swift build' from swift/" >&2
    exit 1
fi

sandbox=$(mktemp -d) || exit 1
trap 'rm -rf "$sandbox"' EXIT

status=0
cases=0

# Both sides write to the same file name under a different directory, and the directory is filtered
# back out of their output. Otherwise every summary line would differ on the path alone.
# The leading program name is normalised for the same reason, and only the leading one: the two
# tools genuinely have different names -- `ksp2midi` against `ksp-swift-cli export` -- and that is
# not a defect to fix. Everything after the prefix is still compared exactly, which is where all the
# meaning is.
scrub() {
    sed -E -e "s|$sandbox/case/py/|<out>/|g" -e "s|$sandbox/case/sw/|<out>/|g" \
        -e "s|$sandbox|<sandbox>|g" \
        -e "s|^(ksp2midi\|midi2ksp\|ksp-swift-cli (export\|convert)): |<prog>: |" "$1"
}

# Run one case through both ports and compare everything observable about it.
#   compare <direction> <label> <args...>
# where <direction> is the artifact comparison to use and <args...> is what both CLIs are given
# apart from -o, which this supplies.
compare() {
    local direction=$1 label=$2
    shift 2
    cases=$((cases + 1))

    local dir=$sandbox/case
    rm -rf "$dir"
    mkdir -p "$dir/py" "$dir/sw" || return 1

    local name python swift py_code sw_code
    case $direction in
        export) name=out.mid python=ksp2midi swift=export ;;
        # --split takes a directory, so -o is the case directory itself and nothing is appended.
        split) name="" python=ksp2midi swift=export ;;
        import) name=out.KeyStepPro python=midi2ksp swift=convert ;;
    esac

    HOME=$sandbox uv run "$python" "$@" -o "$dir/py/$name" > "$dir/py.out" 2> "$dir/py.err"
    py_code=$?
    HOME=$sandbox "$swift_cli" "$swift" "$@" -o "$dir/sw/$name" > "$dir/sw.out" 2> "$dir/sw.err"
    sw_code=$?

    local failed=0
    if [[ $py_code != "$sw_code" ]]; then
        echo "midi_parity: $label: exit code $py_code (python) vs $sw_code (swift)" >&2
        failed=1
    fi
    local stream
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
                local piece
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

    ((failed)) && status=1
    return 0
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
        compare export "$(basename "$project")" "$project"
        compare export "$(basename "$project") --passes 1" "$project" --passes 1
        compare export "$(basename "$project") --no-swing" "$project" --no-swing
        compare export "$(basename "$project") --no-time-shift" "$project" --no-time-shift
        compare export "$(basename "$project") --include-stale --include-disabled" \
            "$project" --include-stale --include-disabled
        compare export "$(basename "$project") --drum-channel 16" "$project" --drum-channel 16
        compare split "$(basename "$project") --split" "$project" --split
    done
else
    echo "midi_parity: ksp-swift-cli has no 'export' yet -- skipping the ksp2midi direction"
fi

if has convert; then
    for clip in project_files/*.mid analysis/captures/*.mid; do
        compare import "$(basename "$clip")" "$clip"
        compare import "$(basename "$clip") --no-swing-fit" "$clip" --no-swing-fit
        compare import "$(basename "$clip") --no-time-shift" "$clip" --no-time-shift
        compare import "$(basename "$clip") --steps-per-beat 8" "$clip" --steps-per-beat 8
        compare import "$(basename "$clip") --drum-track 1" "$clip" --drum-track 1
        compare import "$(basename "$clip") --midi-track 1" "$clip" --midi-track 1
    done
else
    echo "midi_parity: ksp-swift-cli has no 'convert' yet -- skipping the midi2ksp direction"
fi

((status)) || echo "midi_parity: both ports agree on $cases conversion(s)"
exit "$status"
