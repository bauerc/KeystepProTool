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
patterns (M5, M6). `swift/` is the port's skeleton, building and testing alongside the Python (M8).
What is left is the port itself, a GUI and packaging (M9–M14).

- [KeyStep Pro Format Spec](analysis/KeyStepPro_Format_Spec.md) — authoritative format reference. **Read it before touching
  format code.**
- [Implementation Road Map](ROADMAP.md) — milestones M1–M14 and current status. `README.md` — CLI usage and options Cohosted on Github Issues for this repo.
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

Swift 6.2, Command Line Tools only — no Xcode until M13. From `swift/`:

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

`swift/` mirrors that split across four targets: `KSPKit` (the format core, `ksp/` minus MIDI),
`KSPMIDI` (the `swift-midi-file` layer, `midi_export`/`midi_import`), `KSPSwiftCLI` (the
`ksp-swift-cli` product, `ksp_cli/`), and their tests. **Nothing may add a dependency to `KSPKit`.**
`swift-midi-file` is Apple-only, so `Package.swift` gates `KSPMIDI` and everything above it off on
Linux; keeping `KSPKit` dependency-free is what puts M9–M11's tests on GitHub's 1× runner instead
of the 10× macOS one. swift-format owns every byte of `swift/` — pre-commit excludes the tree.

`ksp.midi_export` has three layers that must stay separate: `render_pattern` (pattern → tick
data), `arrange` (timeline placement), `build_midi_file` (the only `mido` caller). Tests assert on
`Rendering` data, not parsed MIDI. `ksp.midi_import` mirrors it inverted — `read_clip` (the only
`mido` caller) → `quantise` (plain arithmetic) → `apply` (raw dict) — and its tests assert on
`Placement` data the same way.

Console entry points go in `pyproject.toml` only when their milestone lands, so an installed
command never crashes on invocation. All three are claimed; a new one waits for its milestone.

`midi2ksp` ships MCC's factory default in `src/ksp_cli/templates/`, so the installed command has
something to overwrite. It is a byte-identical copy of `project_files/Default.KeyStepPro` and a
test holds it there; pre-commit excludes the directory because the file is 3.5 MB.

## Repository data is not source

`project_files/*.KeyStepPro` and `analysis/*.txt` are excluded from pre-commit deliberately —
never reformat, re-indent, or add a final newline. The exports are M3's byte-identical baseline;
the `.txt` files are transcribed from the hardware display and cannot be regenerated without the
device. `tests/test_format_invariants.py` makes such corruption fail loudly; if it fails, the fix
is never in that file.
