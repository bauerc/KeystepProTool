# KeystepProTool
A tool that aims to take Keystep Pro project files and transform them into midi files and vice versa

The `.KeyStepPro` format is decoded and hardware-validated — see
[`analysis/KeyStepPro_Format_Spec.md`](./analysis/KeyStepPro_Format_Spec.md). The staged build
plan is in [`ROADMAP.md`](./ROADMAP.md).

## Status

Both directions work end to end, and both are **verified on the hardware** — files this tool wrote
loaded in MIDI Control Center, transferred to a KeyStep Pro, and played what they said they would.
Three commands ship: `ksp-dump` reads a project, `ksp2midi` exports one as MIDI, and `midi2ksp`
converts a MIDI clip into a playable pattern. `kspplus` gathers all three under one name.

`midi2ksp` converts a whole file: every note-bearing track onto the device's four, chords, a drum
track, note lengths, tempo, and sequences too long for one pattern split and chained.

## Install

Requires Python 3.13 and [uv](https://docs.astral.sh/uv/).

```sh
uv sync
```

## `kspplus`

Every command is reachable two ways: under its own name, or as a `kspplus` subcommand. They are the
same command — same options, same output — so these two lines do the same thing:

```sh
uv run ksp2midi project_files/project_5.KeyStepPro -o project_5.mid
uv run kspplus ksp2midi project_files/project_5.KeyStepPro -o project_5.mid
```

`kspplus --help` lists the three, and `kspplus <command> --help` gives that command's options
grouped by what they affect — selection, timing, drum mapping, output. The rest of this README uses
the standalone form for brevity; prefix any of it with `kspplus` and it still works.

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
| `--no-time-shift` | Ignore each note's time shift and place every step on a flat grid |
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

Each note's **time shift is applied**. Tier 8 measured one unit as a fixed 1/400 of a beat --
1.2 ticks at 480 PPQN, and the same count whatever the step size -- so the displacement the
device plays is the displacement the file gets. `--no-time-shift` returns the flat grid, which
is what to reach for when reading a pattern's written positions rather than its groove.

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

Turn a MIDI file into KeyStep Pro patterns:

```sh
uv run midi2ksp my_song.mid --drum-track 3 -o my_song.KeyStepPro
```

```
midi2ksp: warning: no drum map was given, so one was fitted to the source: chromatic from 31 (assumed - not in file). The real map is a device setting the project file does not carry
midi2ksp: warning: track 4 (seq): track 4 runs 128 steps, past the device's 64; it was split across patterns 1-2 and chained
midi2ksp: warning: the project tempo was set to the source's 120 BPM
wrote my_song.KeyStepPro
  track 1 [drum]: 64 note(s), pattern 1 (64 steps)
  track 2: 160 note(s), pattern 1 (48 steps)
  track 3: 3 note(s), pattern 1 (32 steps)
  track 4: 64 note(s), patterns 1-2 (64, 64 steps)
```

Drop the result in `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/`, restart MCC, and
it appears in the Project Browser ready to send to the device.

| Option | Effect |
|---|---|
| `-o PATH` | Destination (default: the input file with a `.KeyStepPro` suffix) |
| `--track N` | First KeyStep Pro track 1–4 to fill (default 1) |
| `--pattern N` | First pattern 1–16 to write to (default 1). Every target must be empty |
| `--template PATH` | Project to write into (default: MCC's factory default) |
| `--midi-track N` | Convert only track N of the source, into the one `--track`/`--pattern` names |
| `--drum-track N` | Write source track N as drums, onto KeyStep Pro track 1 |
| `--drum-map SPEC` | `chromatic:N` or `custom:a,b,c,…` (default: fitted to the source) |
| `--steps-per-beat N` | Step size to quantise to (default 4, i.e. 1/16 steps). Written into the pattern |
| `--no-tempo` | Keep the template's tempo instead of the source's |
| `--no-swing-fit` | Leave patterns straight instead of fitting the source's groove |
| `--no-time-shift` | Quantise hard, instead of carrying each note's leftover |
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

- **The song is anchored, once.** A pattern is a loop with nowhere to keep a lead-in, so the file's
  first note lands on step 1 whatever tick it sits at — DAWs routinely export a clip with its
  session ticks intact. The whole file moves together, so a part that enters at bar 3 still enters
  at bar 3, in a later pattern of its track if that is where bar 3 falls.
- **Tracks map in file order.** The drum track takes KeyStep Pro track 1, because item 123 is the
  only one carrying a drum parameter set; the rest fill the tracks after it. A fifth is reported
  and dropped.
- **A source track holding several channels becomes one device track each.** A type 0 file — one
  track, everything on it — tells its instruments apart by channel and nothing else, so merging
  them would put a whole arrangement on one track with the percussion in it as melodic pitches.
  `--drum-track N` still means the whole of source track N, channels and all.
- **A track's length is its own content rounded up to the bar**, then cut into 64-step patterns —
  the device's maximum. A split track's patterns are **chained** in the current scene, which is
  what makes them play as one sequence. Tracks are not padded to a common length: the device loops
  each track's chain on its own, so a one-bar part under an eight-bar one repeats against it,
  which is what the sequencer is for. Nothing is truncated until the 16 pattern slots run out, and
  then it is reported.
- **Chords are kept whole.** Notes sharing a step are consecutive entries in the pattern's pool.
  Two firmware ceilings apply: 192 events per pattern, past which the tail is dropped with a
  count, and 16 notes on any one step, which is refused outright — the conversion stops and names
  the step, since silently thinning a chord changes what you wrote.
- **Note lengths become gates**, snapped to the nearest rung of the measured 128-rung ladder. The
  ladder is coarse above 3 steps, so a length it cannot express exactly is reported.
- **Tempo is carried** from the source, held to the 30–240 BPM the device runs at. A file that
  changes tempo partway keeps only the first, as the device stores one per project. The three
  chunks the tempo is stored in reach about 20,971 BPM, so the file would take anything — the
  bound is the hardware's, and being held to it is reported.
- **Groove is fitted to swing first, then to time shift.** Swing is one value for a whole pattern
  and time shift is a scarce 60 ticks per note, so a systematic groove goes to the former and only
  the leftover to the latter. Anything neither can express is reported, never silently absorbed.

Pitch and velocity pass through unchanged; both are 7-bit on each side.

**Drums need a map, and the map is not in the file.** A drum note stores a *lane*, and which MIDI
note a lane plays is a global device setting (see `ksp-dump` above). Reading one back can fall
through to Arturia's default and say so; writing one cannot, because a source whose drums sit
anywhere but 36–59 would have every hit dropped. So an unconfigured import **fits** a chromatic map
to the source's own pitches and reports which one it used. `--drum-map` overrides it, and a map in
`~/.config/keysteppro/drum_map.json` is used ahead of fitting.

A drum track is found on MIDI channel 10, which is what General MIDI reserves. Plenty of files put
drums on an ordinary channel instead, and for those `--drum-track N` names it explicitly.

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

`swift/` holds the Swift port of the core (M8–M12), built with Swift 6.2 and the
Command Line Tools. `./scripts/validate.sh` runs both toolchains and skips the
Swift half where `swift` is not on `PATH`; run it rather than `swift test`,
which needs extra flags to find Swift Testing on a machine without Xcode.

**New to the Mac toolchain?** [`swift/README.md`](./swift/README.md) explains
it from a Python/Java starting point — toolchain, SwiftPM, dependencies and
the layout of this package.
