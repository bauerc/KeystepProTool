#!/usr/bin/env bash
# Both cores' pull over the shared tapes, byte for byte. The device is the one thing CI has not
# got, so each side reads a captured exchange instead: same tape, same slot, same template, and
# the .KeyStepPro that comes out has to `cmp`. Slot 1's tape has MCC's own export to check
# against as well; slot 2's has none, and there the two cores check each other.
set -o pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

if ! command -v swiftc &> /dev/null; then
    echo "pull_parity: no swiftc on PATH" >&2
    exit 1
fi

# The one file both cores' default resolves to; passed explicitly so the comparison names it.
template=src/ksp_cli/templates/Default.KeyStepPro

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
    py=$sandbox/py_$slot.KeyStepPro
    sw=$sandbox/sw_$slot.KeyStepPro

    if ! "$puller" "tests/fixtures/$tape" "$slot" "$template" "$sw"; then
        echo "pull_parity: the Swift core failed on $tape" >&2
        status=1
        continue
    fi

    # --no-identity on both sides: the version is the one thing a tape cannot answer for.
    if ! uv run python - "tests/fixtures/$tape" "$slot" "$template" "$py" <<'PYTHON'; then
import pathlib
import sys

sys.path.insert(0, "tests")
from conftest import DeviceModel, FakeDevice, tape_values  # noqa: E402

from ksp_cli import pull  # noqa: E402

tape, slot, template, output = sys.argv[1:5]
device = FakeDevice({int(slot): DeviceModel(tape_values(pathlib.Path(tape)))})
pull.UsbMidiTransport = lambda **_: device
sys.exit(
    pull.main([output, "--slot", slot, "--template", template, "--no-identity", "--quiet"])
)
PYTHON
        echo "pull_parity: the Python core failed on $tape" >&2
        status=1
        continue
    fi

    if ! cmp "$py" "$sw"; then
        echo "pull_parity: slot $slot differs between the two cores" >&2
        status=1
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
