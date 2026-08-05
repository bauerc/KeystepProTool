# KeystepProTool
A tool that aims to take Keystep Pro project files and transform them into midi files and vice versa

The `.KeyStepPro` format is decoded and hardware-validated — see
[`analysis/KeyStepPro_Format_Spec.md`](./analysis/KeyStepPro_Format_Spec.md). The staged build
plan is in [`ROADMAP.md`](./ROADMAP.md).

## Status

Both directions work end to end, and both are **verified on the hardware** — files this tool wrote
loaded in MIDI Control Center, transferred to a KeyStep Pro, and played what they said they would.
Three commands ship: `ksp-dump` reads a project, `ksp2midi` exports one as MIDI, and `midi2ksp`
converts a MIDI clip into a playable pattern.

`midi2ksp` is deliberately an MVP: one track, one pattern, monophonic, default note lengths. Real
multi-track material, drums and polyphony are milestone 6 — see [`ROADMAP.md`](./ROADMAP.md).

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
| `--passes {auto,1,2,3,4}` | How many of the four 16/32/48/64 repeats to render (default `auto`) |
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

Anything the export had to decide for itself is printed to stderr as a warning. One thing it
needs is not in the project file at all:

- **The drum map** is a device-global setting, not project data. The export names the map it
  assumed every time. Unlike `ksp-dump`, `--drum-map none` is refused: a MIDI file has to name a
  note for every lane, so there is no honest way to leave a lane unresolved.

**Gate lengths and step size** used to be two more. The full 128-rung gate ladder is measured, so
every gate a real file can hold converts directly into a note duration; `--default-gate` remains
for a value outside 0–127, which is warned about rather than interpolated. Step size and triplet
are measured too, and read per pattern out of the file, so there is nothing to supply.

**Each pattern is a four-repeat cycle.** Every note carries a mask saying which of the repeats it
plays in, and the device runs them as repeats of the pattern rather than as pages of a long one.
`--passes auto` expands a pattern to four repeats when any of its notes sits one out, and renders
one when none do — so a project nobody has masked comes out exactly as it did before the flag
existed. `--passes 1` flattens the cycle deliberately, and says that it did.

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

## `midi2ksp`

Turn a MIDI clip into a KeyStep Pro pattern:

```sh
uv run midi2ksp my_riff.mid -o my_riff.KeyStepPro
```

```
midi2ksp: warning: note lengths are not carried; every note is written at gate 0.5 steps, what a freshly placed note has on the device
midi2ksp: warning: the source plays at 120 BPM; tempo is not carried, so the project keeps the one its template holds
wrote my_riff.KeyStepPro
  16 note(s) onto track 1, pattern 1 (16 steps)
```

Drop the result in `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/`, restart MCC, and
it appears in the Project Browser ready to send to the device.

| Option | Effect |
|---|---|
| `-o PATH` | Destination (default: the input file with a `.KeyStepPro` suffix) |
| `--track N` | KeyStep Pro track 1–4 to write to (default 1) |
| `--pattern N` | Pattern 1–16 to write to (default 1). It must be empty |
| `--template PATH` | Project to write into (default: MCC's factory default) |
| `--midi-track N` | Read only track N of the source file (default: all of them) |
| `--steps-per-beat N` | Step size to quantise to (default 4, i.e. 1/16 steps). Written into the pattern |
| `--dry-run` | Report what would be written, and write nothing |
| `--force` | Overwrite an existing output file |
| `--quiet` | Suppress the stdout summary. Warnings still go to stderr |
| `-v`, `--verbose` | List every warning, instead of one summary line per kind |

**A project file is never built from scratch.** Its key set is fixed at 153,495 numeric keys, so
`midi2ksp` loads a template and overwrites values in it. The default is MCC's own factory project,
shipped with this tool. Point `--template` at one of your own projects instead and everything else
in it is kept, which is how a clip goes into a spare pattern of something you are already working
on. The target pattern has to be empty — appending to a pattern that already holds notes would
interleave two takes.

### What the conversion decides, and says

- **The clip is anchored.** A pattern is a loop with nowhere to keep a lead-in, so the first note
  lands on step 1 whatever tick the clip starts at. DAWs routinely export a clip with its session
  ticks intact.
- **Notes are quantised** to the step grid, nearest step wins.
- **One note per step.** Where several sound together the highest is kept and the rest are
  dropped, with a count. Chords are M6.
- **Notes past the pattern's last step are dropped**, not written. The device disables them rather
  than playing them, so writing them would put notes in the file that no hardware makes a sound
  for. The pattern's length comes from the template, so `--template` is also how you convert a
  clip longer than 16 steps.
- **Note lengths are not carried.** Every note gets the gate a freshly placed note has on the
  device, half a step. The gate ladder is fully measured, so carrying real durations is possible —
  it is scope, not an unknown, and it belongs to M6.
- **Tempo is not carried.** The project keeps its template's.

Pitch and velocity pass through unchanged; both are 7-bit on each side.

**The project's name comes from the template**, because a project name is stored as an integer
parameter whose encoding we have not decoded. In MCC's Project Browser a converted project may
therefore show the template's name rather than your filename.

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
