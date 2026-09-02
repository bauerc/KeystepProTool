#!/usr/bin/env bash
# Compares both cores' conversions in each direction: exit code, stdout, stderr and the artifact.
# HOME is redirected so neither side picks up a personal ~/.config drum map.
set -o pipefail

# Absolute: this re-invokes itself as the per-case worker, and the cd below would strip a relative
# $0 of its meaning.
self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

swift_cli=swift/.build/debug/ksp-swift-cli
if [[ ! -x $swift_cli ]]; then
    echo "midi_parity: $swift_cli is not built; run 'swift build' from swift/" >&2
    exit 1
fi

# The per-case worker, reached only from the xargs below. Its streams go to per-case files that the
# driver replays in index order, so a failure reads the same whichever order the cases finished in.
if [[ ${1-} == "--case" ]]; then
    sandbox=$2
    IFS='|' read -r index direction label args <<< "$3"

    dir=$sandbox/case-$index
    mkdir -p "$dir/py" "$dir/sw" || exit 1

    # Filters out the two things that legitimately differ: the output directory and the leading
    # program name. Everything after the prefix is still compared exactly.
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
                # Parsed events, not bytes: mido writes running status and swift-midi-file does not.
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

    # The 3.5 MB artifacts go as soon as the case is judged; the logs live outside $dir so the
    # driver can still replay them.
    rm -rf "$dir"
    exit "$failed"
fi

sandbox=$(mktemp -d) || exit 1
trap 'rm -rf "$sandbox"' EXIT

cases=0
list=$sandbox/cases

# add <direction> <label> <args...> -- <args...> is what both CLIs get apart from -o, which the
# worker supplies. A stray '|' would silently truncate a record into a different case that passes.
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

# Probing with `<name> --help` does not work: ArgumentParser answers --help before it validates the
# subcommand, so every name looks present. The root help's SUBCOMMANDS list is the answer.
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
        add export "$(basename "$project") --tracks 1,3" "$project" --tracks 1,3
        add export "$(basename "$project") --patterns 1-4" "$project" --patterns 1-4
        add export "$(basename "$project") --no-markers" "$project" --no-markers
        add export "$(basename "$project") --repeat 2" "$project" --repeat 2
        add export "$(basename "$project") --flat-velocity fresh" "$project" --flat-velocity fresh
        add split "$(basename "$project") --split" "$project" --split
        add split "$(basename "$project") --split --repeat 2" "$project" --split --repeat 2
    done
    # The refusals, once rather than per project: their wording does not depend on the file.
    add export "--tracks refused alike" project_files/project_9.KeyStepPro --tracks bad
    add export "--tracks past Int, in a range" project_files/project_9.KeyStepPro \
        --tracks 3-99999999999999999999
    add export "--tracks bad and --drum-map bad" project_files/project_9.KeyStepPro \
        --tracks bad --drum-map garbage
    add export "--repeat past its limit" project_files/project_9.KeyStepPro --repeat 11
    # The past-Int case must reach the range message, not "not a velocity": it pins the saturation.
    add export "--flat-velocity refused alike"  project_files/project_9.KeyStepPro \
        --flat-velocity 0
    add export "--flat-velocity not a velocity" project_files/project_9.KeyStepPro \
        --flat-velocity loud
    add export "--flat-velocity past Int"       project_files/project_9.KeyStepPro \
        --flat-velocity 99999999999999999999
else
    echo "midi_parity: ksp-swift-cli has no 'export' yet -- skipping the ksp2midi direction"
fi

if has convert; then
    for clip in project_files/*.mid analysis/captures/*.mid; do
        # analysis/captures/ is gitignored, so in a worktree the glob arrives unexpanded.
        [[ -e $clip ]] || continue
        add import "$(basename "$clip")" "$clip"
        add import "$(basename "$clip") --no-swing-fit" "$clip" --no-swing-fit
        add import "$(basename "$clip") --no-time-shift" "$clip" --no-time-shift
        add import "$(basename "$clip") --steps-per-beat 8" "$clip" --steps-per-beat 8
        add import "$(basename "$clip") --drum-track 1" "$clip" --drum-track 1
        add import "$(basename "$clip") --drum-channel 1" "$clip" --drum-channel 1
        add import "$(basename "$clip") --drum-channel 3" "$clip" --drum-channel 3
        add import "$(basename "$clip") --drum-channel 1 --drum-track 1" "$clip" \
            --drum-channel 1 --drum-track 1
        add import "$(basename "$clip") --no-drums" "$clip" --no-drums
        add import "$(basename "$clip") --no-drums --drum-track 1" "$clip" --no-drums --drum-track 1
        # No committed fixture puts a track on channel 10, so the search is moved to one that fires.
        add import "$(basename "$clip") --drum-channel 3 --no-drums" "$clip" \
            --drum-channel 3 --no-drums
        add import "$(basename "$clip") --midi-track 1" "$clip" --midi-track 1
        add import "$(basename "$clip") --route 1:2" "$clip" --route 1:2
        add import "$(basename "$clip") --route 3:1,4:2" "$clip" --route 3:1,4:2
        add import "$(basename "$clip") --route bad" "$clip" --route bad
        add import "$(basename "$clip") --route 1:9" "$clip" --route 1:9
        add import "$(basename "$clip") --route 1:2,3:2" "$clip" --route 1:2,3:2
        add import "$(basename "$clip") --route=-1:2" "$clip" --route=-1:2
        # Int.min: Swift parses it and would trap on abs(). This holds the magnitude bound in place.
        add import "$(basename "$clip") --route=Int.min" "$clip" --route=-9223372036854775808:1
        add import "$(basename "$clip") --midi-track 1 --route 1:2" "$clip" --midi-track 1 --route 1:2
        add import "$(basename "$clip") --midi-tracks 1,2" "$clip" --midi-tracks 1,2
        add import "$(basename "$clip") --midi-tracks 1-2" "$clip" --midi-tracks 1-2
        add import "$(basename "$clip") --midi-tracks bad" "$clip" --midi-tracks bad
        add import "$(basename "$clip") --midi-tracks 0" "$clip" --midi-tracks 0
        add import "$(basename "$clip") --midi-tracks 99" "$clip" --midi-tracks 99
        add import "$(basename "$clip") --midi-track 1 --midi-tracks 1" "$clip" --midi-track 1 --midi-tracks 1
        add import "$(basename "$clip") --midi-tracks 1 --drum-track 2" "$clip" --midi-tracks 1 --drum-track 2
        add import "$(basename "$clip") --midi-tracks 1,2 --route 2:1" "$clip" --midi-tracks 1,2 --route 2:1
        add import "$(basename "$clip") --midi-tracks 1,2 --route 3:1" "$clip" --midi-tracks 1,2 --route 3:1
        add import "$(basename "$clip") --flat-velocity fresh" "$clip" --flat-velocity fresh
        add import "$(basename "$clip") --flat-velocity 64" "$clip" --flat-velocity 64
        add import "$(basename "$clip") --flat-velocity 0" "$clip" --flat-velocity 0
        add import "$(basename "$clip") --flat-velocity loud" "$clip" --flat-velocity loud
        # Must reach the range message, not "not a velocity": it pins the saturation.
        add import "$(basename "$clip") --flat-velocity past Int" "$clip" \
            --flat-velocity 99999999999999999999
    done
    # Several sources, once rather than per clip: what they pin is the merge, not the material.
    # Both orderings, because argument order decides which device track a file fills.
    simple=project_files/test_file_simple.mid
    chords=project_files/test_file.mid
    add import "simple + chords"            "$simple" "$chords"
    add import "chords + simple"            "$chords" "$simple"
    add import "two files --midi-tracks 2"  "$simple" "$chords" --midi-tracks 2
    add import "two files --midi-tracks 99" "$simple" "$chords" --midi-tracks 99
    add import "two files --route"          "$simple" "$chords" --route 2:1,1:2
    add import "two files --midi-track"     "$simple" "$chords" --midi-track 1
else
    echo "midi_parity: ksp-swift-cli has no 'convert' yet -- skipping the midi2ksp direction"
fi

status=0
if ((cases)); then
    # getconf rather than nproc: macOS ships no nproc, and this has to run on both.
    jobs=${KSP_PARITY_JOBS:-$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 4)}
    xargs -0 -P "$jobs" -I{} "$self" --case "$sandbox" {} < "$list" || status=1

    # Replayed in index order, so the output reads as though the cases had run one after another.
    for ((i = 0; i < cases; i++)); do
        [[ -s $sandbox/case-$i.out ]] && cat "$sandbox/case-$i.out"
        [[ -s $sandbox/case-$i.err ]] && cat "$sandbox/case-$i.err" >&2
    done
fi

((status)) || echo "midi_parity: both ports agree on $cases conversion(s)"
exit "$status"
