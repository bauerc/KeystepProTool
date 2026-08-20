# CLAUDE.md

Guidance for Claude Code working in this repository.

## Conventions

- Comment concisely. Large docstrings on methods should NOT be used.
- Claude plan files committed to this repository are deleted as part of the implementing task.
- Use subagents
- DO NOT reply to PR comments

## What this is

Converts Standard MIDI files ↔ Arturia KeyStep Pro `.KeyStepPro` project files. MIDI Control
Center has no MIDI export for this device, so `ksp2midi` is the only one that exists — and there
is no reference render to check against: **the hardware's live MIDI output is the sole ground
truth**. Reading and MIDI export work; `ksp.mutate` writes notes and pattern scalars into an
existing project (M4, M6); `ksp.midi_import` converts a whole MIDI file — multi-track, chords,
drums, gates, tempo, fitted swing and time shift, and long sequences split across chained
patterns (M5, M6). `ksp-pull` reads a project straight off the hardware over USB SysEx and writes
the `.KeyStepPro` MCC would have exported, so a project no longer has to come through MCC at all;
its acceptance gate (H3.2's byte-diff on hardware) is still open. `swift/` builds and tests
alongside the Python and is now a complete port of both directions — constants, keys, the JSON
reader and writer, diagnostics, the drum map, the
model, the reader, `mutate`, `midi_export`, `midi_import` and `ksp-swift-cli dump` / `export` /
`convert` (M8–M12), plus the drag-and-drop app *Key Step Pro Plus* — SwiftPM product `ksp-app`,
target `KSPApp` (M13). What is left is the full application (M15) and distribution.

M13's app is a deliberate v1 — one window, one file, no options. **M15 is the app
`project_requirements/project_requirements.md` describes**, and its spec of record is the epic,
GitHub issue #115: forty issues carrying the requirement-coverage table and the frontier. Two
labels say what a given one costs — `app` touches no parity script, `core-parity` lands in both
cores in one commit. A summary type that adds no CLI text needs no Python mirror and runs no parity
gate; that exemption is what keeps the preview work affordable, so do not let a preview issue add a
CLI flag. Distribution is no longer a milestone: it gates nothing and repeats every release, so it
is the release track in issue #10.

- [KeyStep Pro Format Spec](analysis/KeyStepPro_Format_Spec.md) — authoritative format reference. **Read it before touching
  format code.**
- [Implementation Road Map](ROADMAP.md) — milestones M1–M15, the release track and current status. `README.md` — CLI usage and options Cohosted on Github Issues for this repo.
- [Timing Calibration](analysis/Timing_Calibration.md), [Hardware Test Protocol](analysis/Hardware_Test_Protocol.md) — how the timing
  encodings were measured, and the one question left for the device.

## Commands

`uv` toolchain, Python 3.13 (pinned in `.python-version`).

```sh
uv sync                          # from uv.lock
./scripts/validate.sh            # format, typecheck, tests — both toolchains, also on the Stop hook
uv run pytest -m "not hardware"  # as CI runs it
uv run ruff check . && uv run mypy
```

Swift 6.2, Command Line Tools only — no Xcode at all, the GUI included: the CLT SDK ships
`SwiftUI`, `AppKit` and `UniformTypeIdentifiers`, and an `.app` is a directory with an `Info.plist`
that `scripts/bundle_app.sh` assembles. [`swift/README.md`](swift/README.md)
covers the toolchain, SwiftPM and dependency management from a Python starting point. From `swift/`:

```sh
swift format --in-place --recursive --parallel Sources Tests Package.swift
swift format lint --strict --recursive --parallel Sources Tests Package.swift
```

**Run the Swift tests through `./scripts/validate.sh`, not `swift test` directly.** The CLT ship
Swift Testing but leave it off the compiler and runtime search paths, and its `_Testing_Foundation`
overlay has no `.swiftinterface` there, so a bare `swift test` fails on any test importing
`Foundation`. `validate.sh` adds the three flags that bridge it, and only on a CLT install.

CI installs with `uv sync --locked`, so commit lockfile changes alongside dependency changes.
Tests marked `hardware` need the physical device and are deselected everywhere automated:
**green CI ≠ verified on hardware**.

Run `pre-commit install` **only from the main checkout**, never from `.claude/worktrees/*`:
worktrees share `.git/hooks`, and the generated hook hard-codes the installing `.venv`'s absolute
path, so installing from a worktree blocks commits repo-wide once that worktree is deleted.

## Architecture

`src/` layout, strict one-way dependency:

- **`ksp/`** — pure format, model and MIDI logic. No `ksp_cli` import, no printing, no `sys.argv`,
  no deciding where files live. The same logic must work behind a CLI, a frozen binary and an
  Swift port (M8–M12), so the port stays a translation of pure functions.
- **`ksp_cli/`** — args, path resolution, terminal output. No format logic.

`swift/` mirrors that split across six targets: `KSPKit` (the format core, `ksp/` minus MIDI),
`KSPMIDI` (the `swift-midi-file` layer, `midi_export`/`midi_import`), `KSPRun` (the command bodies
— `ConvertRunner`, `ExportRunner`, `DumpRunner` — plus `SummaryRunner` and the bundled template),
`KSPSwiftCLI` (the `ksp-swift-cli` product: argument parsing, `@main`, nothing else),
`KSPApp` (the `ksp-app` product:
the SwiftUI drag-and-drop window), and their tests. **A command body goes in `KSPRun`, never in
`KSPSwiftCLI` or `KSPApp`**: SwiftPM forbids a non-test target from depending on an executable one,
so anything in `KSPSwiftCLI` is reachable only from the CLI, and the app has to run the very same
`convert` for the parity scripts to keep meaning anything. All three command runners return one
`RunResult`: the rendered `stdout`/`stderr`/`code` the CLI prints through its single `emit(_:)`,
plus the same run structurally as `diagnostics` and `destinations`, which is what the app reads
instead of re-parsing the text. **`SummaryRunner` is the exception, and deliberately so**: it
returns a `ProjectSummary` and renders no text at all, which is what keeps a preview off the parity
contract — no CLI output to compare means no Python mirror. Giving it a subcommand would forfeit
that and pay full parity, so a preview issue must not add a flag (#115). Its counts say *enabled*,
never *audible*: they answer the two reasons a note is switched off, not the spec's six reasons one
might not play.

**`KSPApp` owns no format logic** — only where a file goes, what it is called and which options the
window offers. `Destination.swift`, `Folders.swift`, `Conversion.swift`, `Settings.swift`,
`PatternGrid.swift` and `GridSelection.swift` carry
no SwiftUI so their rules are unit-tested; SwiftUI stays in `DropView.swift` and `KSPApp.swift`, and every mutable
value lives on the one `@MainActor` `AppModel`, in `AppModel.swift` (Observation and AppKit, no
SwiftUI). **A new option is a property on `Settings` and a line in its two mappings onto
`ConvertRunner.Options`/`ExportRunner.Options`** (`Settings.selecting(_:)` is how the grid's ticks
reach the export's two sets, so nothing sets them by hand) — an option left out of those mappings
keeps the runner's own default, which is what makes the app on defaults convert what the CLI on
defaults converts. Conversions run in a `Task.detached`, which is what the `Sendable` `Options`/`RunResult`
are for, and so does the staged view's read of a dropped project: `DropView`'s `.task` asks
`AppModel.summarise()`, which asks `Conversion.summarise` for a `SummaryState`. **A preview reads
through `SummaryRunner` and renders in `DropView`** — the runner returns no `RunResult` and so no
CLI text, which is the whole reason a preview costs no Python mirror and no parity run.
The preview itself is a track × pattern grid, and **what it decides lives in `PatternGrid.swift`,
not in `DropView`**: what a cell prints, which chained cells are joined, and — in `AppLayout` — every
dimension the window and the grid are both built from. That one enum is why the pattern axis fits:
the staged pane scrolls vertically only, so a grid too wide for it is *silently clipped*, and a test
holds the grid under a budget subtracted from the window. Change the sidebar and the test says so.
The grid's cells are also ticks, and **the whole tick rule lives in `GridSelection.swift`**: it
rides the set-based `--tracks` / `--patterns` selection both cores already have, so it costs no
Python mirror and no parity run. `select` keeps the *cross product* of those two sets, so the only
expressible selection is a **rectangle** — whole tracks against whole pattern slots. Cells still
tick freely; one that is not a rectangle disables Convert through `blockReason`, the single place
the window reads for why the button is off. Everything ticked projects to `[]`, `[]`, which is how
both CLIs spell "all" — that is what keeps the app on defaults byte-identical to the CLI on
defaults, and a new projection rule must keep it so.
`scripts/bundle_app.sh` wraps the built binary in a `.app`; it is deliberately **not** in
`validate.sh`, which compiles the target through `KSPAppTests` instead.
**Nothing may add a dependency to `KSPKit`.**
`swift-midi-file` is Apple-only, so `Package.swift` gates `KSPMIDI` and everything above it off on
Linux; keeping `KSPKit` dependency-free is what puts M9–M11's tests on GitHub's 1× runner instead
of the 10× macOS one. swift-format owns every byte of `swift/` — pre-commit excludes the tree.

**The two CLIs' output is a byte-for-byte contract**, held by three scripts `validate.sh` runs as
its last three steps. `scripts/port_parity.sh` diffs `ksp-swift-cli dump` against `ksp-dump` over
every sample project in both output modes; `scripts/writer_parity.sh` does the same for the write
path; `scripts/midi_parity.sh` runs both conversion directions over every project and clip in the
repository, comparing exit code, stdout, stderr and the artifact. A diagnostic's wording, a key's
position in the JSON and a number's formatting are therefore all load-bearing on both sides: change
one, change the other in the same commit. The Python is the reference implementation. This is also
why the Swift model serialises through `JSONNode` rather than `Encodable` — `JSONEncoder` controls
neither key order nor the `120` vs `120.0` rendering of a whole-numbered `Double`.

All three run their cases across the cores, and each one reports failures in case order rather than
completion order so a blocked Stop reads the same every time. `KSP_PARITY_JOBS=1` puts them back to
one at a time, which is the first thing to try when a failure is confusing. They are also gated
together: `validate.sh` fingerprints what they read — both implementations, the corpus and the
comparison tools — and skips all three when it matches `swift/.build/parity/gates.sha`, which is
written only after all three have passed. Content hashes, never mtimes, and a red run leaves no
stamp; delete the file to force a run.

**The one thing that is deliberately not byte-identical is the exported `.mid`.** mido writes MIDI
running status and `swift-midi-file` does not, so `midi_parity.sh` compares the two files as parsed
event streams through `tools/midi_events.py`. The `.KeyStepPro` direction still gets a real `cmp`.

`ksp.midi_export` has three layers that must stay separate: `render_pattern` (pattern → tick
data), `arrange` (timeline placement), `build_midi_file` (the only `mido` caller). Tests assert on
`Rendering` data, not parsed MIDI. `ksp.midi_import` mirrors it inverted — `read_clip` (the only
`mido` caller) → `quantise` (plain arithmetic) → `apply` (raw dict) — and its tests assert on
`Placement` data the same way.

Console entry points go in `pyproject.toml` only when their milestone lands, so an installed
command never crashes on invocation. All five are claimed; a new one waits for its milestone.

The CLI is Typer. Each command is a function in its own module with a `register(app)` that mounts
it, so `ksp2midi ...` and `kspplus ksp2midi ...` are one command reached two ways — add a command
by writing `register`, never by declaring its options twice. Commands signal failure with
`typer.Exit(code)`; `ksp_cli.runner.run` turns that back into the `main(argv) -> int` the entry
points and the tests call. The exit codes are load-bearing: **0 success, 1 file or format failure,
2 usage failure**.

Both `midi2ksp` and `ksp-swift-cli convert` ship MCC's factory default, so the installed command
has something to overwrite. The bytes live once, at
`swift/Sources/KSPRun/Resources/Default.KeyStepPro`, because a SwiftPM resource must sit under
its own target and SwiftPM copies a symlink as a symlink; `src/ksp_cli/templates/Default.KeyStepPro`
is the symlink to it, which Python and hatchling both follow. See the comment in
`swift/Package.swift`. It is byte-identical to `project_files/Default.KeyStepPro` and a test holds
it there; pre-commit excludes both directories because the file is 3.5 MB.

## Repository data is not source

`project_files/*.KeyStepPro` and `analysis/*.txt` are excluded from pre-commit deliberately —
never reformat, re-indent, or add a final newline. The exports are M3's byte-identical baseline;
the `.txt` files are transcribed from the hardware display and cannot be regenerated without the
device. `tests/test_format_invariants.py` makes such corruption fail loudly; if it fails, the fix
is never in that file.

## Agent skills

### Issue tracker

Issues live as GitHub issues on `bauerc/KeystepProTool`, driven through the `gh` CLI. See
`docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

**The device's vocabulary is canonical** — Arturia's wording beats MCC's, which beats the code's
([ADR 0001](docs/adr/0001-device-vocabulary-is-canonical.md)). So the docs say *trigger* and *drum
track* where the code still says *note* and *lane*, deliberately: the glossary binds prose, UI text,
diagnostics and new code, while existing identifiers are recorded as alternatives and renamed only
when their file is already open. A rename reaching a diagnostic or CLI option is a two-core commit
plus a parity re-fingerprint, so **there is no standalone rename PR** (#163, #164).
