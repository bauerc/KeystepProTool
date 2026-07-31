# M2 — KeyStep Pro → MIDI export

## Context

GitHub issue #4 / ROADMAP M2. MIDI Control Center can export MIDI for some things but has no path
for getting *sequencer patterns* out as `.mid` files — that gap is why this repo exists, and M2 is
the half of it that is testable without hardware. M1 already decodes projects into a clean model
(`ksp.reader.load` → `Project → Track → Pattern → Note`), so M2 is a rendering problem, not a
format problem.

The outcome: `ksp2midi project_files/project_5.KeyStepPro` writes `.mid` files whose notes, timing
and velocities match `analysis/project_5_description.txt` when opened in a DAW. This is the first
milestone where a decoding mistake becomes *audible*.

The governing constraint is the same one that shapes the rest of the repo: **do not invent
encodings.** Gate above the six measured points, time shift units and swing behaviour are all
unmeasured, so export stays on the grid and warns rather than emitting confident-looking wrong
timing (spec §6, ROADMAP M7).

## Decisions (confirmed with the user)

| Question | Decision |
|---|---|
| What one `.mid` holds | **One file per non-empty (track, pattern)** by default; `--chain` concatenates each track's patterns into a single multi-track file |
| Step skip (16/32/48/64) | **Single pass, masks ignored** by default; `--passes auto` (or `4`) expands the full 4-loop cycle applying each note's mask |
| Time shift / swing | **Grid-quantised**, warn on stderr when a project carries either. `--time-shift approx` opts into the documented guess |
| Drum lanes | lane *N* → MIDI note `36 + N` on **channel 10** (lane 0 = GM kick), via `--drum-base` / `--drum-channel` |

Additional choices that need no input, but should be stated in code comments:

- **Gate is in steps.** `project_5`'s tied note ("set on beat 9, Tie to beat 12") stores gate 4 and
  spans 4 steps, so `duration = gate × step_ticks`. An unmeasured raw gate falls back to the
  default 0.5 and warns — never interpolated (`ksp.constants.decode_gate` already returns `None`).
- **A step is a 1/16 note**, 480 PPQ → 120 ticks/step. The step-size bitfield (`99`/`116`) is not
  decoded (it reads 20 in the hardware-confirmed files, 16 elsewhere), so this is fixed with a
  `--step` override rather than read from the file.
- **Channels**: melodic notes on the track number (1–4); drum notes on `--drum-channel`. The
  per-track MIDI channel is a device-global, not in the project file — verified: no `12x_123*` key
  exists in any sample project.
- Patterns in `both` mode (`initial_project` track 1 pattern 1) export **both** note sets, because
  parameter `100` still cannot say which is live (spec §5 caveat). The reader's existing warning is
  carried through.

## Implementation

### `src/ksp/midi_export.py` (new, pure — no printing, no paths, no argv)

Two layers, so the M8/M9 Swift port translates arithmetic rather than a MIDI library:

1. **Render** — `render_pattern(pattern, *, track_number, options) -> Rendering` turning `Note`s
   into a `tuple[RenderedNote, ...]` of plain data: `tick`, `duration_ticks`, `pitch`, `velocity`,
   `channel`, plus `Rendering.length_ticks` and `Rendering.warnings`. All the interesting logic
   lives here and is what tests assert against.
   - `tick = (step - 1) * options.step_ticks` (+ pass offset when expanding).
   - `duration_ticks = max(1, round(gate × step_ticks))`, gate falling back to
     `options.default_gate` when `note.gate is None`.
   - `NoteKind.DRUM` → `pitch = drum_base + note.pitch`, `channel = drum_channel`.
   - Pass expansion (`--passes`): repeat the pattern `n` times, keeping a note in pass *i* only if
     `SKIP_SEQUENCES[i] in note.skip`. `auto` = 4 when any note's skip is not all four, else 1.
   - Pattern length comes from `seq_step_count` / `drum_step_count` per kind (max when both are
     populated); a note past the step count is kept and warned about, not dropped.
2. **Build** — `build_midi_file(renderings, *, tempo_bpm, ppq, names) -> mido.MidiFile` (type 1):
   track 0 carries `set_tempo` + `time_signature` + project name; one track per rendering with a
   `track_name` and an `end_of_track` at `length_ticks` so trailing silence survives.

Plus `ExportOptions` (frozen dataclass: `step_ticks`, `ppq`, `passes`, `time_shift`, `default_gate`,
`drum_base`, `drum_channel`) and `export_project(project, *, tracks, patterns, options)` returning
per-(track, pattern) renderings — the selection logic, shared by both CLI modes.

Reuses `ksp.constants.SKIP_SEQUENCES` / `decode_gate` and `ksp.model` as-is. **No model changes**,
so the M1 fixtures and `to_dict` shape stay untouched.

### `src/ksp_cli/export.py` (new — argparse, path resolution, stderr)

`ksp2midi PATH [-o OUT] [--track N] [--pattern N] [--chain] [--passes {1,auto,4}]
[--time-shift {off,approx}] [--drum-base N] [--drum-channel N] [--step {4,8,16,32}] [--ppq N]
[--default-gate G] [--dry-run]`

- Default: writes `<stem>_track{N}_pattern{P}.mid` for every non-empty (track, pattern) into `-o`
  (a directory; default `.`). Created if missing. Prints each file written.
- `--chain`: one `.mid`, one MIDI track per KSP track, that track's non-empty patterns
  back-to-back. `-o` is then a file path (default `<stem>.mid`). Warn when track totals differ,
  since the tracks then drift apart.
- When the selection is exactly one pattern, `-o something.mid` is accepted as a file path.
- Warnings (time shift, swing ≠ 50, unmeasured gate, both-mode patterns, notes past step count) go
  to **stderr**; the file list to stdout. Mirrors `ksp_cli/dump.py`'s error handling: `OSError` and
  `ValueError` → message + exit 1.
- Follows the structure of `src/ksp_cli/dump.py` (`_build_parser`, `main(argv=None) -> int`).

### `pyproject.toml`

Add `ksp2midi = "ksp_cli.export:main"` to `[project.scripts]` and drop the "lands at M2" line from
the comment above it. `mido` is already a declared dependency; no lockfile change expected — if
`uv sync` does touch `uv.lock`, commit it (CI runs `--locked`).

## Tests

- **`tests/test_midi_export.py`** — the substance, asserted against `Rendering` data rather than
  parsed MIDI bytes:
  - `project_5` track 3 pattern 1: 10 notes at ticks 0,120,240,… with pitches 48/48/48/48/49… and
    velocities 60,70,90,100 straight from `analysis/project_5_description.txt`; the tenth note at
    step 13 (tick 1440) — the case that proves the two index spaces survived rendering.
  - Gate → duration: the gate-2 note is 240 ticks, gate 0.5 is 60, the tied gate-4 note is 480.
  - `project_5` track 1 pattern 1: kicks at ticks 0 and 480, pitch 36, channel 10, velocities
    127 and 50.
  - `--passes auto` on `project_5` track 3: 4 × 16 steps, notes 5–6 present only in passes 1 and 3,
    notes 7–8 only in 2 and 4, the second D only in 3 and 4 — a direct read of the description.
  - Default single pass ignores masks and warns that it did.
  - Time shift is not applied and a warning names it; swing ≠ 50 likewise.
  - An unmeasured gate (`initial_project` has a raw `2`) uses the fallback and warns.
  - `build_midi_file` output re-parses under `mido` with matching note counts and end-of-track.
- **`tests/test_export_cli.py`** — `tmp_path` output: default writes exactly the expected filenames
  for `project_5` (`track1_pattern1`, `track3_pattern1`), `--track`/`--pattern` narrow it, `--chain`
  writes one file, a missing input exits 1, `--dry-run` writes nothing. Same style as
  `tests/test_dump_cli.py`.
- **`tests/test_package.py`** — extend the existing entry-point check to `ksp2midi` if it enumerates
  scripts.

Fixture policy: expected values are transcribed from the description text, not generated from the
exporter, consistent with `tests/fixtures/README.md`. Small enough to live inline in the test rather
than as a new JSON fixture.

## Docs

- `README.md` — a `ksp2midi` section next to `ksp-dump` (options table, sample output) and a status
  line bump to "M1–M2 done".
- `ROADMAP.md` — mark M2 ✅ with a short "Delivered" note matching M1's format, including what the
  export deliberately does *not* do (time shift, swing, unmeasured gates) and the dependency
  summary row.
- No spec changes expected; if rendering turns up a new format fact, it goes in
  `analysis/KeyStepPro_Format_Spec.md`, not in code comments alone.

## Verification

```sh
uv run pytest -m "not hardware"
uv run ruff check . && uv run ruff format --check .
uv run mypy
uv run ksp2midi project_files/project_5.KeyStepPro -o /tmp/ksp-m2      # both files written
uv run ksp2midi project_files/project_5.KeyStepPro --track 3 --passes auto -o /tmp/ksp-m2
uv run python -c "import mido; m=mido.MidiFile('/tmp/ksp-m2/project_5_track3_pattern1.mid'); print(m)"
```

`tests/test_format_invariants.py` must stay green — it guards the sample files against
reformatting, and export must not touch them.

The milestone's real test is yours and needs no hardware: open
`project_5_track3_pattern1.mid` in a DAW and confirm C2 ×4, C#2 ×4, then D, against
`analysis/project_5_description.txt`. Everything above only proves the numbers; the DAW proves the
music.

Work happens on a branch off `main` with a draft PR referencing issue #4.
