# KeystepProTool
A tool that aims to take Keystep Pro project files and transform them into midi files and vice versa

The `.KeyStepPro` format is decoded and hardware-validated — see
[`analysis/KeyStepPro_Format_Spec.md`](./analysis/KeyStepPro_Format_Spec.md). The staged build
plan is in [`ROADMAP.md`](./ROADMAP.md).

## Status

Milestones 1, 1.5 and 2 of 9 are done: reading and inspecting project files, the drum map, and
exporting projects as MIDI. Converting *from* MIDI (M5) is next.

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

A gate printed as `?(2)` means that encoding has not been measured on the hardware yet. Only six
gate values are confirmed, and the tool prints the raw number rather than guessing at the rest.
See M7 in the roadmap.

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

| Option | Effect |
|---|---|
| `-o PATH` | Destination (default: the input file with a `.mid` suffix) |
| `--track N` / `--pattern N` | Export only one track or pattern |
| `--steps-per-beat N` | Step size (default 4, i.e. 1/16 steps) |
| `--drum-map SPEC` | Same grammar and config file as `ksp-dump` (default `chromatic:36`) |
| `--include-stale` | Export both note sets of a pattern that holds both |
| `--no-swing` | Place every step on a flat grid |
| `--force` | Overwrite an existing output file |

Anything the export had to decide for itself is printed to stderr as a warning, because three
things it needs are not in the project file:

- **Step size** is stored in a bitfield we have not decoded, so `--steps-per-beat` supplies it.
- **The drum map** is a device-global setting, not project data. The export names the map it
  assumed every time. Unlike `ksp-dump`, `--drum-map none` is refused: a MIDI file has to name a
  note for every lane, so there is no honest way to leave a lane unresolved.
- **Gate lengths** are only measured at six points (M7). Anything else is exported at the length
  a freshly placed note has, and warned about — never interpolated.

Where a pattern holds both a melodic and a drum note set, only the one the track's mode flag
(parameter `86` bit 6) says the device plays is exported — the other is leftovers from before the
track was switched over, and exporting it would put notes in the file that no hardware produces.
`--include-stale` exports both.

Note **time shift is not applied**: how much time one shift unit is worth has never been
measured, so the export leaves the grid alone and says so.

## Development

```sh
uv run pytest          # tests
uv run ruff check .    # lint
uv run mypy            # types
```

Tests marked `hardware` need a physical KeyStep Pro and are skipped in CI
(`uv run pytest -m "not hardware"`).
