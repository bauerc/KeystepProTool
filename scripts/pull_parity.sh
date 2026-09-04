#!/usr/bin/env bash
# Both cores' pull over the shared tapes, byte for byte. The device is the one thing CI has not
# got, so each side reads a captured exchange instead: same tape, same slot, same template, and
# the .KeyStepPro that comes out has to `cmp`. Slot 1's tape has MCC's own export to check
# against as well; slot 2's has none, and there the two cores check each other.
#
# --also-midi's file is compared too, as parsed events -- mido writes running status and
# swift-midi-file does not. The tape driver links KSPKit alone and cannot export, so the Swift side
# of that half is `ksp-swift-cli export` on the project just pulled; that it is the same file
# --also-midi writes is held by PullTests, byte for byte.
set -o pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

if ! command -v swiftc &> /dev/null; then
    echo "pull_parity: no swiftc on PATH" >&2
    exit 1
fi

# The one file both cores' default resolves to; passed explicitly so the comparison names it.
template=src/ksp_cli/templates/Default.KeyStepPro

# Absent when this gate is run before the package is built; the MIDI half is skipped, not failed.
swift_cli=swift/.build/debug/ksp-swift-cli
[[ -x $swift_cli ]] || echo "pull_parity: $swift_cli is not built -- skipping the --also-midi half"

scratch=swift/.build/pull-parity
puller=$scratch/pulltape
mkdir -p "$scratch" || exit 1

# Unoptimised on purpose, and rebuilt on the sources' *contents*, never their timestamps -- a
# checkout or a stash pop restores an older mtime, and an mtime cache would hand this gate a
# binary built from code no longer on disk.
stamp=$scratch/sources.sha
current=$(cat swift/Sources/KSPKit/*.swift tools/pull_tape.swift | shasum | cut -d' ' -f1)
if [[ ! -x $puller || $current != $(cat "$stamp" 2> /dev/null) ]]; then
    if ! swiftc swift/Sources/KSPKit/*.swift tools/pull_tape.swift -o "$puller"; then
        rm -f "$stamp"
        echo "pull_parity: the tape driver did not compile" >&2
        exit 1
    fi
    echo "$current" > "$stamp"
fi

sandbox=$(mktemp -d) || exit 1
trap 'rm -rf "$sandbox"' EXIT

status=0
count=0
# <tape>|<slot>|<MCC export to check both against, or ->
for case in "recall_tape.txt|1|initial_project.KeyStepPro" "recall_project_2_tape.txt|2|-"; do
    IFS='|' read -r tape slot export <<< "$case"
    count=$((count + 1))
    # One basename per slot, a directory per core: the project's own name becomes the exported
    # MIDI's conductor track name, so two names would differ before a note was compared.
    mkdir -p "$sandbox/py" "$sandbox/sw" || exit 1
    py=$sandbox/py/pulled_$slot.KeyStepPro
    sw=$sandbox/sw/pulled_$slot.KeyStepPro

    if ! "$puller" "tests/fixtures/$tape" "$slot" "$template" "$sw"; then
        echo "pull_parity: the Swift core failed on $tape" >&2
        status=1
        continue
    fi

    # --no-identity on both sides: the version is the one thing a tape cannot answer for. HOME is
    # redirected so --also-midi's export never picks up a personal ~/.config drum map, and its
    # warnings are held back rather than printed -- this gate judges files, not streams.
    warnings=$sandbox/warnings_$slot.err
    if ! HOME=$sandbox uv run python - "tests/fixtures/$tape" "$slot" "$template" "$py" \
        2> "$warnings" <<'PYTHON'; then
import pathlib
import sys

sys.path.insert(0, "tests")
from conftest import DeviceModel, FakeDevice, tape_values  # noqa: E402

from ksp_cli import pull  # noqa: E402

tape, slot, template, output = sys.argv[1:5]
device = FakeDevice({int(slot): DeviceModel(tape_values(pathlib.Path(tape)))})
pull.UsbMidiTransport = lambda **_: device
sys.exit(
    pull.main(
        [output, "--slot", slot, "--template", template, "--no-identity", "--quiet", "--also-midi"]
    )
)
PYTHON
        cat "$warnings" >&2
        echo "pull_parity: the Python core failed on $tape" >&2
        status=1
        continue
    fi

    if ! cmp "$py" "$sw"; then
        echo "pull_parity: slot $slot differs between the two cores" >&2
        status=1
    fi

    if [[ -x $swift_cli ]]; then
        if ! HOME=$sandbox "$swift_cli" export "$sw" --quiet 2> "$warnings"; then
            cat "$warnings" >&2
            echo "pull_parity: the Swift core could not export what it pulled from $tape" >&2
            status=1
        elif ! diff -u \
            <(uv run python tools/midi_events.py "${py%.KeyStepPro}.mid") \
            <(uv run python tools/midi_events.py "${sw%.KeyStepPro}.mid"); then
            echo "pull_parity: slot $slot's exported MIDI differs between the two cores" >&2
            status=1
        fi
    fi

    # The half a core-to-core diff cannot see: that what they agree on is what MCC exported.
    if [[ $export != "-" ]] && ! uv run python - "$py" "project_files/$export" <<'PYTHON'; then
import pathlib
import sys

written, mcc = (pathlib.Path(argument).read_bytes() for argument in sys.argv[1:3])
if not mcc.endswith(b",\n}"):
    sys.exit(f"{sys.argv[2]} lost MCC's trailing comma; the fix is never in that file")
if written != mcc[:-3] + b"\n}":
    sys.exit(f"the pull no longer reproduces {sys.argv[2]}'s bytes")
PYTHON
        echo "pull_parity: the pull no longer reproduces $export" >&2
        status=1
    fi
done

((status)) || echo "pull_parity: both cores pull the same bytes over $count tapes"
exit "$status"
