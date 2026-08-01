# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Converts between Standard MIDI files and Arturia KeyStep Pro `.KeyStepPro` project files.
MIDI Control Center (MCC) offers no way to get sequencer patterns in or out as MIDI — that gap is
the reason this tool exists.

**MCC has no MIDI export for the KeyStep Pro** — confirmed in the UI. This matches the static
evidence: `KeyStepPro.json` declares `actions: ["store", "recall"]`, and the binary's only
MIDI-file-writing strings sit in the BeatStep Pro `.mbseq` save path. So `ksp2midi` is the only
MIDI writer that exists for this device, and there is **no reference render to check timing
against** — the hardware's live MIDI output is the sole ground truth.

The file format is already decoded and hardware-validated. **Read
`analysis/KeyStepPro_Format_Spec.md` before touching format code** — it is the authoritative
reference, and `analysis/KeyStepPro_File_Format_Analysis_deprecated.md` is retained only as a
record of superseded (wrong) conclusions. `ROADMAP.md` defines the milestones M1–M9; `PLAN.md`
records the research that produced the spec, plus a converter design appendix.

## Commands

Toolchain is `uv` (Python 3.13, pinned in `.python-version`).

```sh
uv sync                              # create/refresh .venv from uv.lock
uv run pytest -m "not hardware"      # full test suite as CI runs it
uv run pytest tests/test_format_invariants.py::test_uses_tab_indentation
uv run pytest -k round_trip          # by name
uv run ruff check . && uv run ruff format --check .
uv run mypy                          # strict; files = src, tests
uv run pre-commit run --all-files    # ruff + whitespace hooks only
```

CI (`.github/workflows/check.yml`) runs lint, format, typecheck and tests in one Linux job and
installs with `uv sync --locked`, so a stale `uv.lock` fails the build. Commit lockfile changes
alongside dependency changes.

Run `pre-commit install` **only from the main checkout**, never from `.claude/worktrees/*`.
Worktrees share the main repo's `.git/hooks`, and the generated hook hard-codes the absolute
path of whichever `.venv` installed it — installing from a worktree bakes that worktree's path
in for everyone, then blocks all commits repo-wide once the worktree is deleted.

Tests marked `hardware` need a physical KeyStep Pro and are deselected everywhere automated.
**A green CI run does not mean a change is verified on the device.**

## Architecture

Two packages under a `src/` layout, with a strict dependency direction:

- **`ksp/`** — pure format, model and MIDI-conversion logic. Must not import `ksp_cli`, print,
  read `sys.argv`, or decide where files live. This purity is deliberate: the same logic has to
  work behind a CLI, a frozen binary, and (M8–M9) a Swift port, so the port stays a translation
  of pure functions rather than a redesign.
- **`ksp_cli/`** — argument parsing, path resolution, terminal output. No format logic.

Console entry points (`ksp-dump`, `ksp2midi`, `midi2ksp`) are added to `pyproject.toml` only when
the milestone implementing them lands, so an installed command never crashes on invocation.
`midi2ksp` is still unclaimed.

### Format facts that shape the code

- A `.KeyStepPro` file is one **flat** JSON object of ~153,495 integer entries. All structure
  lives in the key names: `<itemId>_<paramId>[_i1][_i2][_i3]`.
- It is **not strict JSON** — trailing comma before the closing brace, tab indentation, no final
  newline. `json.loads` rejects it. Loading and re-emitting must preserve those bytes.
- The key set is **fixed**. Converters use **template-and-overwrite**: start from
  `Default.KeyStepPro` (or a user project), mutate values in place, write back. Never synthesise
  or add/remove keys. Note that the factory default lacks the `"version"` key that user-saved
  projects have; it must be injected.
- **Two index spaces** (spec §4) — the single most common source of bugs. Within one
  `(item, pattern, slot)`, params `48`/`49` are indexed by **physical step**, while `50` and
  `109`–`113` are indexed by **ordinal position in a compact note list**, with `50` mapping each
  note to its 0-based step. The device stores an event list, not a step grid.
- `127` means "empty" — but is also a legal pitch and velocity. The only valid existence test is
  `paramId 50 != 127` (`54` for drums). Never infer a note from its velocity.
- `127` marks an empty **entry**, not the end of the list, and **the two parameter sets are
  scanned differently**. The melodic list is compacted; the drum array is a pool with holes, so
  the drum scan skips sentinels and the melodic one stops at the first. Spec §4 rule 1 ("packed
  contiguously") is a rule for *writers*. Applying it on read discarded 43 live notes in
  `initial_project` and then blamed the file for losing them.
- Audibility has **three** gates: pooled (`50`/`54`), flagged (`48`/`52`), **and** within the
  pattern's declared length (`98`/`115`). Notes past the last step are retained, not stale —
  shortening a pattern hides them and lengthening it brings them back, confirmed on hardware.
- Track 1 (item `123`) carries a whole second parameter set for DRUM mode. The mode flag is
  **`86` bit 6** (per-track), not the `100` bitfield the spec originally named — `100` reads 26
  everywhere. A writer must set `86` to match whichever set it writes.
- A drum note's `117` is a **lane index (0–23)**, not a pitch. The lane→note drum map is a
  *global device setting* and is not in the project file at all: it cannot be read from one or
  written into one. `ksp.drum_map` holds it as configuration with a documented default
  (chromatic from 36) and every consumer must state which map it assumed.
- **The three timing encodings are unmeasured** (M7, needs hardware): gate length (`110`/`118`) is
  non-linear with six known points; time shift (`112`/`120`) has a confirmed centre of 49 but an
  unknown range and unknown unit; swing (`74`, `97`/`114`) has **never been set in any sample file**,
  so it cannot be decoded at the desk at all. Until they are measured, stay on the grid, write a
  default gate, and warn — do not guess an encoding, because a wrong one produces files that load
  fine and play wrong. See `analysis/Timing_Calibration.md`.

## Repository data is not source

`project_files/*.KeyStepPro` and `analysis/*.txt` are excluded from pre-commit for a reason and
must never be reformatted, re-indented, or given a final newline:

- The `.KeyStepPro` exports are the baseline for M3's byte-identical round-trip; normalising them
  silently destroys the thing that milestone proves.
- The `analysis/*.txt` files are values transcribed from the hardware display and cannot be
  regenerated without the device.

`tests/test_format_invariants.py` exists to make any such corruption fail loudly rather than
surface later as a mysterious round-trip failure. If it starts failing, the fix is almost never
in that file.

## Current state

M1 (reader + `ksp-dump`), M1.5 (`ksp.drum_map` and the real drum-mode flag), M2 (`ksp2midi`) and
M2.2 (the rest of the export options) are merged. The codebase reads a project into `ksp.model`
and renders it as MIDI; nothing writes `.KeyStepPro` files yet. M3 (byte-identical round-trip) is
next, and it is the prerequisite for every writing milestone after it.

`ksp.midi_export` runs in three layers and they must stay separate: `render_pattern` turns one
pattern into plain tick data, `arrange` places renderings on a timeline, and `build_midi_file` is
the only part that touches `mido`. That boundary is what keeps the M8–M9 Swift port a translation
of arithmetic, and it is why tests assert against `Rendering` data rather than parsed MIDI.

`ksp.midi_export` is also where the format's unknowns become user-visible. Three quantities it needs
are not in the project file — step size, the drum map, and most gate encodings — and each is an
`ExportOptions` field with a documented default, never a buried constant. Time shift is decoded
but deliberately **not applied**, because the duration of one shift unit has not been measured.
Anything the export decides for itself is reported as a warning; when adding to it, keep that
property rather than quietly picking a value.

Warnings are `ksp.diagnostics` records, not strings: a stable `Code`, the `Site` they came from,
and how many notes or steps they cover. `ksp/` raises them and `ksp_cli/` prints them — the
purity boundary applies here too. Reporting groups by `Code` and sums the counts, so one line can
say "41 notes across 3 patterns" and `--verbose` can expand it again. **Adding one is a `Code`
member, a `SUMMARIES` entry and the call site** — no branch and no class per warning. Keep the
collapsed wording in the table rather than reconstructing it at the call site, or grouping stops
being able to say anything useful about the count.

## Code Commentation

Code should be concisely commented. Large doc strings for methods should NOT be used

## Project Cleanup

Claude Plan files committed to this repository should be deleted as part of the implementation task.
