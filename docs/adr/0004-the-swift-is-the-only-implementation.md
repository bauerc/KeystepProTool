# The Swift is the only implementation

The converter existed twice: the Python in `src/`, and its Swift port in `swift/`. We deleted the
Python and kept the Swift alone. The Python is archived as it last stood, at the `python-final` tag
in this repository and in its own read-only repository,
[`bauerc/KeystepProTool-python`](https://github.com/bauerc/KeystepProTool-python).

This reverses ROADMAP.md §Stack: *"The Python does not retire when Swift lands; it becomes the
reference implementation the port is checked against."* The port reached parity at M12 and the app
shipped at M13. After that, every change that reached CLI output cost two implementations and a
parity re-run. And the four gates that held the two together ran only on a dev machine with `uv`
beside Swift, never in CI.

## Consequences

**Nothing replaces the reference.** The four parity gates are deleted with the Python, and no
frozen copy of the Python's answers takes their place. What pins the Swift now is its own suite:
the hand-transcribed `fixtures/*.expected.json`, the hardware tapes, and the byte-level checks on
`project_files/` in `FormatInvariantsTests`. A change to a diagnostic's wording or a JSON key's
position is a Swift change and nothing more, reviewed as one.

**The generators now emit Swift.** `tools/gen_bulk_plan.swift` writes `BulkPlan.swift` straight
from Arturia's descriptor, so there is no transcription left to drift. `scripts/gen_bulk_fixtures.sh`
writes the two bulk fixtures from the Swift plan. They used to pin the Swift against a second core;
now they pin it against its last reviewed state, so rewriting one is a reviewed decision. The app
icon is drawn by `tools/make_app_icon.swift`, and bundling needs no Python.

**ADR 0003 stands in part.** Its proof that the fast plan asks for the 117,783 addresses MCC asked
for "is made once, in Python". That proof stands as it was made at `python-final`, and 0003 now
says so.

**What is lost.** `KSPMIDI` builds on Apple platforms only, so a Linux or Windows KeyStep Pro owner
has no converter here. Their route is the archive, which is unmaintained. The seven `hardware`
tests (M4–M6) and the capture-evidence assertions live only in the archive until #314 ports them.

## Considered options

**Keep the Python as the reference**, rejected: it doubles the cost of every change to CLI output
in order to check a port that reached parity two milestones ago.

**Freeze the Python's output into reference files first (#312's original scope)**, rejected: a
snapshot of a program nobody runs any more is a second contract that nobody can regenerate. Every
intended change to the output would mean hand-editing the snapshot. And the Swift suite already
asserts the facts that matter, from data transcribed off the device.
