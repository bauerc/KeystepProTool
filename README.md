# KeystepProTool
A tool that aims to take Keystep Pro project files and transform them into midi files and vice versa

The `.KeyStepPro` format is decoded and hardware-validated — see
[`analysis/KeyStepPro_Format_Spec.md`](./analysis/KeyStepPro_Format_Spec.md). The staged build
plan is in [`ROADMAP.md`](./ROADMAP.md).

## Status

Milestones 1, 1.5, 2 and 3 of 9 are done: reading and inspecting project files, the drum map,
exporting projects as MIDI, and writing a project file back out byte-for-byte — bar the trailing
comma, which the hardware confirmed MIDI Control Center does not need, so output is strict JSON.
Converting *from* MIDI (M5) is next.

## Install

Requires Python 3.13 and [uv](https://docs.astral.sh/uv/).

```sh
uv sync
```

## `ksp-dump`

Print what is actually in a project file, without opening MIDI Control Center:

```sh
uv run ksp-dump project_files/project_5.KeyStepPro
```

```
project_5.KeyStepPro
  device KeyStepPro   version 2.5.20
  tempo 120 BPM   swing 50%   scene 1

  Track 1 (item 123)  [drum mode]
    Pattern 1  [drum]
      drum map: chromatic from 36 (assumed - not in file)
      drum: 16 steps, swing 50%
        slot 1
          note  1  step  1  lane 0 -> C1 (36) Bass Drum 1  vel 127  gate    1  shift -1  rand  80  seq 16,32
          note  2  step  5  lane 0 -> C1 (36) Bass Drum 1  vel  50  gate    2  shift +1  rand  90  seq 48,64
  Track 3 (item 125)
    Pattern 1  [seq]
      seq: 16 steps, swing 50%
        slot 1
          note  1  step  1  C2 (48)    vel  60  gate    2  shift +1  rand  10  seq always
          ...
```

| Option | Effect |
|---|---|
| `--all` | Include patterns that hold no notes (all 16 always exist on disk) |
| `--track N` | Show only track 1–4 |
| `--pattern N` | Show only pattern 1–16 |
| `--json` | Emit the decoded model as JSON instead of a tree |
| `--drum-map SPEC` | `chromatic:N`, `custom:a,b,c,...` or `none` (default `chromatic:36`) |
| `-v`, `--verbose` | List every diagnostic inline, instead of one summary line per kind |

`seq` on a note line is the note's step skip — which of the four 16/32/48/64 sequences it plays
in.

A drum note stores a **lane number**, not a pitch. Which MIDI note a lane transmits is set by the
device's Drum Map, which lives in global device settings and is **not stored in the project
file** — so the tool cannot read it and says `(assumed - not in file)` next to whichever map it
used. The default is Arturia's: chromatic from MIDI note 36. Override it per run with
`--drum-map`, permanently in `~/.config/keysteppro/drum_map.json`:

```json
{"mode": "custom", "notes": [36, 38, 42, 46, 41, 45, 48, 51, 49, 39, 37, 43,
                             44, 47, 50, 52, 53, 54, 55, 56, 57, 58, 59, 60]}
```

or turn resolution off entirely with `--drum-map none` to see bare lane numbers.

Gates print as a length in steps, from 0.0625 up to 64. All 128 encoder positions are measured
(spec §6.1), so a gate printed as `?(200)` means the file holds a value outside 0–127 — the tool
prints the raw number rather than rounding it to the nearest real one.

## `ksp2midi`

Turn a project into a Standard MIDI file. MIDI Control Center can push patterns *to* the device
but has no way of getting them off as a `.mid`, so this direction is useful on its own:

```sh
uv run ksp2midi project_files/project_5.KeyStepPro -o project_5.mid
```

```
wrote project_5.mid
  12 note(s) from pattern(s) 1
  tracks: Track 1 (drum), Track 3
```

Patterns that hold notes are laid end to end in pattern order, and pattern N starts at the same
point on every track — so tracks keep the relationship the hardware gives them. Each KeyStep Pro
track becomes its own MIDI track; Track 1's drum set becomes a second one on channel 10.

The device loops each track independently, so tracks of different total lengths drift apart on the
hardware while this layout keeps re-aligning them. When that happens the export says so.

`--split` skips the layout question altogether and writes one file per (track, pattern), each
starting at its own tick 0:

```sh
uv run ksp2midi project_files/project_9.KeyStepPro --split -o out/
```

```
wrote out/project_9_track1_pattern2.mid
  1 note(s) from pattern(s) 2
  tracks: Track 1 (drum)
wrote out/project_9_track1_pattern3.mid
  ...
```

| Option | Effect |
|---|---|
| `-o PATH` | Destination (default: the input file with a `.mid` suffix); with `--split`, a directory |
| `--split` | One file per non-empty (track, pattern), named `<stem>_track{N}_pattern{P}.mid` |
| `--track N` / `--pattern N` | Export only one track or pattern |
| `--steps-per-beat N` | Step size (default 4, i.e. 1/16 steps) |
| `--ticks-per-beat N` | MIDI resolution (default 480) |
| `--drum-map SPEC` | Same grammar and config file as `ksp-dump` (default `chromatic:36`) |
| `--default-gate STEPS` | Length used where a gate value is outside the measured 0–127 ladder (default 0.5) |
| `--drum-channel N` | MIDI channel for drum lanes (default 10) |
| `--include-stale` | Export both note sets of a pattern that holds both |
| `--include-disabled` | Export disabled notes — step turned off, or past the pattern's last step (the device plays neither) |
| `--no-swing` | Place every step on a flat grid |
| `--dry-run` | Report what would be written, and write nothing |
| `--force` | Overwrite an existing output file |
| `--quiet` | Suppress the stdout summary. Warnings still go to stderr |
| `-v`, `--verbose` | List every warning, instead of one summary line per kind |

Anything the export had to decide for itself is printed to stderr as a warning, because two
things it needs are not in the project file:

- **Step size** is stored in a bitfield we have not decoded, so `--steps-per-beat` supplies it.
- **The drum map** is a device-global setting, not project data. The export names the map it
  assumed every time. Unlike `ksp-dump`, `--drum-map none` is refused: a MIDI file has to name a
  note for every lane, so there is no honest way to leave a lane unresolved.

**Gate lengths** used to be a third. The full 128-rung ladder is now measured, so every gate a
real file can hold converts directly into a note duration. `--default-gate` remains for a value
outside 0–127, which is warned about rather than interpolated.

Where a pattern holds both a melodic and a drum note set, only the one the track's mode flag
(parameter `86` bit 6) says the device plays is exported — the other is leftovers from before the
track was switched over, and exporting it would put notes in the file that no hardware produces.
`--include-stale` exports both.

Note **time shift is not applied**: how much time one shift unit is worth has never been
measured, so the export leaves the grid alone and says so.

### Reading the warnings

A real project raises the same finding in a dozen patterns, so warnings are grouped by kind and
counted:

```
$ ksp2midi initial_project.KeyStepPro --dry-run
ksp2midi: warning: 10 patterns hold pooled notes with no step-active flag (116 notes); they do not sound on the device
ksp2midi: warning: drum lanes resolved through the chromatic from 36 (assumed - not in file) map on channel 10; ...
ksp2midi: 27 warnings collapsed into 9 kinds; --verbose for detail
```

`--verbose` lists every instance with the track and pattern it came from. The collapsed view
never hides a *kind* of problem — only repeats of one — so it is safe to read first and reach for
`--verbose` when a line is worth chasing. `--quiet` suppresses the stdout summary and nothing
else; caveats always reach stderr.

**Step skip is not expanded either.** A note can be set to play on only some of the four
16/32/48/64 sequences; the export renders a single pass and includes every note whatever its mask,
warning when it does. Expanding the cycle needs to know whether those four sequences are *repeats*
of a short pattern or *pages* of a 64-step one, and the project files contradict the obvious
reading — see protocol test T5.8.

## Development

```sh
uv run pytest          # tests
uv run ruff check .    # lint
uv run mypy            # types
```

Tests marked `hardware` need a physical KeyStep Pro and are skipped in CI
(`uv run pytest -m "not hardware"`).

Tests marked `slow` are the whole-file round-trip sweeps. CI runs them;
`scripts/validate.sh` does not, so **a green `validate.sh` is not full
round-trip coverage** — run `uv run pytest -m "not hardware"` before pushing.
Each sweep keeps one always-on instance, so a byte-level regression still fails
locally.
