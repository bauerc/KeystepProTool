# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

Converts Standard MIDI files ↔ Arturia KeyStep Pro `.KeyStepPro` project files. MIDI Control
Center has no MIDI export for this device, so `ksp2midi` is the only one that exists — and there
is no reference render to check against: **the hardware's live MIDI output is the sole ground
truth**. Reading and MIDI export work; nothing writes `.KeyStepPro` files yet.

- `analysis/KeyStepPro_Format_Spec.md` — authoritative format reference. **Read it before touching
  format code.** (`..._deprecated.md` is superseded conclusions; do not cite it.)
- `ROADMAP.md` — milestones M1–M9 and current status. `README.md` — CLI usage and options.
- `analysis/Timing_Calibration.md`, `analysis/Hardware_Test_Protocol.md` — the unmeasured
  quantities and how they get measured.

## Commands

`uv` toolchain, Python 3.13 (pinned in `.python-version`).

```sh
uv sync                          # from uv.lock
./scripts/validate.sh            # format, typecheck, tests — also runs on the Stop hook
uv run pytest -m "not hardware"  # as CI runs it
uv run ruff check . && uv run mypy
```

CI installs with `uv sync --locked`, so commit lockfile changes alongside dependency changes.
Tests marked `hardware` need the physical device and are deselected everywhere automated:
**green CI ≠ verified on hardware**.

## Architecture

`src/` layout, strict one-way dependency:

- **`ksp/`** — pure format, model and MIDI logic. No `ksp_cli` import, no printing, no `sys.argv`,
  no deciding where files live. The same logic must work behind a CLI, a frozen binary and an
  M8–M9 Swift port, so the port stays a translation of pure functions.
- **`ksp_cli/`** — args, path resolution, terminal output. No format logic.

`ksp.midi_export` has three layers that must stay separate: `render_pattern` (pattern → tick
data), `arrange` (timeline placement), `build_midi_file` (the only `mido` caller). Tests assert on
`Rendering` data, not parsed MIDI.

Console entry points go in `pyproject.toml` only when their milestone lands, so an installed
command never crashes on invocation. `midi2ksp` is still unclaimed.

## Format traps (details in spec §2, §4)

- Flat JSON, ~153,495 integer entries; all structure lives in key names
  `<itemId>_<paramId>[_i1][_i2][_i3]`.
- **Not strict JSON** — trailing comma, tab indentation, no final newline. `json.loads` rejects
  it; loading and re-emitting must preserve those bytes.
- Key set is **fixed**: template-and-overwrite from `Default.KeyStepPro`, never add or remove
  keys. The factory default lacks the `version` key user projects have — inject it.
- **Two index spaces** — the top source of bugs. `48`/`49` are step-indexed; `50` and `109`–`113`
  are indexed by note ordinal, with `50` giving each note's 0-based step. The device stores an
  event list, not a step grid.
- **Existence ≠ audibility.** A note exists when `50 != 127` (`54` for drums); it *sounds* only if
  its step-active bit is set (`48` melodic, `52` drum — packed lane-major). Never infer a note
  from its velocity, and never infer emptiness from `40` (it latches).
- Track 1 (item `123`) carries a second DRUM parameter set. The mode flag is **`86` bit 6**, not
  `100`. A writer must set `86` to match whichever set it writes.
- A drum note's `117` is a **lane index (0–23)**, not a pitch. The lane→note map is a global
  device setting absent from the file; `ksp.drum_map` holds it as configuration and every consumer
  states which map it assumed.
- **Gate, time shift and swing encodings are unmeasured** (M7, needs hardware). Stay on the grid,
  write a default gate, warn — a guessed encoding produces files that load fine and play wrong.

Keep the unknowns user-visible: each is an `ExportOptions` field with a documented default, never
a buried constant, and anything the export decides for itself is reported as a warning.

## Repository data is not source

`project_files/*.KeyStepPro` and `analysis/*.txt` are excluded from pre-commit deliberately —
never reformat, re-indent, or add a final newline. The exports are M3's byte-identical baseline;
the `.txt` files are transcribed from the hardware display and cannot be regenerated without the
device. `tests/test_format_invariants.py` makes such corruption fail loudly; if it fails, the fix
is almost never in that file.

## Conventions

- Comment concisely. Large docstrings on methods should NOT be used.
- Claude plan files committed to this repository are deleted as part of the implementing task.
