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
truth**. Reading and MIDI export work; `ksp.mutate` places a note or overwrites one value in an
existing project (M4); `ksp.midi_import` converts a clip into one melodic pattern (M5). Real
multi-track material, drums and polyphony wait for M6.

- [KeyStep Pro Format Spec](analysis/KeyStepPro_Format_Spec.md) — authoritative format reference. **Read it before touching
  format code.**
- [Implementation Road Map](ROADMAP.md) — milestones M1–M9 and current status. `README.md` — CLI usage and options Cohosted on Github Issues for this repo.
- [Timing Calibration](analysis/Timing_Calibration.md), [Hardware Test Protocol](analysis/Hardware_Test_Protocol.md) — the unmeasured
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

Run `pre-commit install` **only from the main checkout**, never from `.claude/worktrees/*`:
worktrees share `.git/hooks`, and the generated hook hard-codes the installing `.venv`'s absolute
path, so installing from a worktree blocks commits repo-wide once that worktree is deleted.

## Architecture

`src/` layout, strict one-way dependency:

- **`ksp/`** — pure format, model and MIDI logic. No `ksp_cli` import, no printing, no `sys.argv`,
  no deciding where files live. The same logic must work behind a CLI, a frozen binary and an
  M8–M9 Swift port, so the port stays a translation of pure functions.
- **`ksp_cli/`** — args, path resolution, terminal output. No format logic.

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
