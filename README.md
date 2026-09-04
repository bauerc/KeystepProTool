# KeystepProTool
A tool that aims to take Keystep Pro project files and transform them into midi files and vice versa

The `.KeyStepPro` format is decoded and hardware-validated — see
[`analysis/KeyStepPro_Format_Spec.md`](./analysis/KeyStepPro_Format_Spec.md). The staged build
plan is in [`ROADMAP.md`](./ROADMAP.md).

## Installation

**The app.** One command rebuilds *Key Step Pro Plus* and installs it to `/Applications`:

```sh
make install
```

Run it afterwards from Launchpad, or with `open -a "Key Step Pro Plus"`. Re-run `make install`
any time to pick up changes — it quits a running copy first and replaces it. Needs Swift 6.2 and
the Command Line Tools; **not** a full Xcode install. No `sudo` on a stock macOS, where
`/Applications` is writable by admin users.

```sh
make app     # build it without installing, into swift/.build/app/
make check   # format, typecheck, test and parity-check both toolchains
make         # list the targets
```

**The command line tools.** Requires Python 3.13 and [uv](https://docs.astral.sh/uv/):

```sh
uv sync
```

That puts `ksp-dump`, `ksp2midi`, `midi2ksp` and `kspplus` on your path. Reading a project off the
device with `ksp-pull` additionally needs the optional USB extra:

```sh
uv sync --extra usb   # and: brew install libusb
```

## Status

Both directions work end to end, and both are **verified on the hardware** — files this tool wrote
loaded in MIDI Control Center, transferred to a KeyStep Pro, and played what they said they would.
Four commands ship: `ksp-dump` reads a project, `ksp2midi` exports one as MIDI, `midi2ksp`
converts a MIDI clip into a playable pattern, and `ksp-pull` reads a project straight off the
device over USB. `kspplus` gathers all four under one name.

`midi2ksp` converts a whole file: every note-bearing track onto the device's four, chords, a drum
track, note lengths, tempo, and sequences too long for one pattern split and chained.

`ksp-pull` is newer than the rest and its acceptance gate is not yet closed: the read path is
verified against a replayed capture and against the device's own panel, but the full-dump diff
against MIDI Control Center's export (H3.2) has not been run on hardware. See
[`ROADMAP.md`](./ROADMAP.md).

There is also a drag-and-drop **macOS app**, *Key Step Pro Plus*, for the common case — see
[The app](#the-app).

## The app

**Key Step Pro Plus.** Drop a `.mid` on the window and it is held there, showing which way it will
go, what the result will be called and where it will land; press **Convert** and a `.KeyStepPro`
lands in MIDI Control Center's Templates folder, where the Project Browser will list it. Drop a `.KeyStepPro` instead and
you get a `.mid` beside it. **Cancel** drops it again without writing anything. One file at a time;
everything else is the CLI's job.

**Simple and Advanced.** A switch in the titlebar picks between the two, and the choice is
remembered. *Simple* is what a fresh install opens on, and it keeps everything that says what is in
the file and what becomes of it: the file, its name, where it will land, the pattern grid over a
`.KeyStepPro` and the source track list over a `.mid`, both tickable, with the destination beside
each source track and the import's own preview and limits beneath. It converts on the defaults plus
whatever you ticked, so an untouched drop is byte for byte what the CLI writes on its own defaults,
and nothing set under Advanced reaches it. It keeps the **Destinations** and the **Appearance** at
the top of the sidebar, and **Dry run** below them — writing nothing is not an advanced thing to
ask for. What Advanced adds is the rest of that sidebar: the groups that reshape a conversion, and
**Show every finding**. It remembers those separately for each direction, showing the group
belonging to whichever way the staged file is going — **Repeat** and **Step Skip** over a
`.KeyStepPro`, the import's own toggles over a `.mid`.

**What is in it.** A dropped `.KeyStepPro` is read while it sits there, and the staged view lists
all four tracks against all sixteen of each one's pattern slots. A slot that holds nothing is dimmed
and just numbered; one that holds something carries how many of its notes are switched on, and
hovering any slot says more. Those counts are *enabled*, not audible: a note on a switched-off step
or past the last step is not counted, and the other reasons one might not sound are the format
spec's. A project that will not read says so there rather than showing an empty list.

**What is in a MIDI file.** A dropped `.mid` is read the same way, and the staged view lists its
source tracks in the file's own order — the number `--midi-tracks` would call each one, its name,
its channels, and how many notes it holds over how many bars. A track holding nothing is still
listed, dimmed and reading *no notes*, so a file whose parts are not where you expected them says
so before you convert rather than after. The track the import will take for drums is marked
**Drums**; a second track on the searched channel is marked **Percussion** instead, because the
device has one drum track and the rest come in melodically. Both badges follow the **Drums** choice
in the sidebar below, so moving the channel moves them and taking nothing as drums leaves no row
badged at all. The track carrying the file's tempo and time
signature but no notes — track 1 of anything this tool exported — is marked **Tempo**, so a
round-tripped file does not read as though a part went missing. Under the list sits what the read
found — a track
carrying several channels becomes a device track per channel, and that is worth knowing first.
Hovering a track says what becomes of it. A file that will not read says so rather than showing an
empty list.

**Ticking what is imported.** The device has four tracks and a MIDI file may hold more, so each
source track carries a checkbox and the first four holding notes start ticked — the same set
`--midi-tracks 1,2,3,4` reads, and that is the option the app hands the conversion, not a mechanism
of its own. Under the list a line says where you stand: "5 of 6 source tracks ticked; the device has
4 tracks." Tick a fifth and it is flagged rather than refused — "That needs 5 device tracks, so 1
would be dropped" — because what competes for those four is a channel, not a track, so a track
carrying two of them asks for two and a track holding nothing asks for none. Untick everything and
Convert says so rather than writing an empty project, and the result names what was left out.

**Saying where a source track goes.** Beside each source track holding notes sits a destination —
device track 1 to 4, **Drums**, **Skip**, or **Automatic**, which is where it starts. Automatic
reads as the assignment the planner actually made, "Automatic — Track 2", taken from the same dry
run the grid below is drawn from, so the default costs nothing and any change is deliberate. Choose
a device track and the grid replans as you watch; choose Drums and it goes to track 1, the only one
carrying a drum set; choose Skip and it is simply unticked. The choices are `--route` and
`--drum-track` as the CLI spells them, not a mechanism of the app's own, and only the tracks you
place by hand are named — a route merges a source track's channels onto its one device track, so
routing the ones you never touched would move them. Send two tracks to one device track, or send
anything but the drums to track 1, and Convert says which two clash rather than letting the run
refuse it.

**Choosing where the drums come from.** The sidebar's **Drums** section carries the other two
answers. **Automatic** searches one channel for a kit and offers a stepper for which — General MIDI
puts one on 10, but a DAW can export one anywhere, and a kit on an ordinary channel would otherwise
import silently as melodic pitches. **None** takes no track as drums at all. A source track sent to
**Drums** in the list is the third answer, and shows in the sidebar as **Source track N** while it
stands; choosing Automatic or None sends that track back to Automatic, so the two can never both be
set. The three are `--drum-channel`, `--no-drums` and `--drum-track` as the CLI spells them.

**Ticking what is exported.** Every slot starts ticked, and the export follows the ticks. Click a
slot to leave that one out, a track name to leave out the whole track, a slot number to leave that
slot out on every track. Any set of cells will do — a slot dropped on one track alone is kept on the
others — and the result names what was left out. Untick everything and Convert says so rather than
writing an empty file.

**Options.** The sidebar carries **Dry run** — report what would be written and write nothing,
which is worth having against a 3.5 MB project, and the one option both faces show — and, under
Advanced, **Show every finding**, which lists each finding rather than one line per kind. A dry run
leaves the file where it is, so switching the toggle off and pressing Convert writes it for real.

Above those, under **MIDI export**, sits **Step Skip**. The device runs a pattern over a cycle of
four sequences — 16, 32, 48 and 64 — and each note carries a mask saying which of them it plays on.
On *Auto* the export renders four passes whenever a pattern holds a note that skips part of that
cycle, so every note lands where its mask says; on *1* it renders a single pass and includes every
note whatever its mask, which flattens the cycle. Either way the result's findings say which
happened. This is the device's own cycle, not copies of the export.

Under it sits **Repeat**, a 1–10 stepper, and that one *is* copies of the export: it lays the whole
thing down again end to end. The line under the grid says what the two come to together — "4
patterns × 2 repeats — 8 patterns end to end" — so the length is legible before Convert is pressed,
and it moves as slots are unticked. Repeat exists only in the `.mid`: the device stores no such
count, so no repeat of it can be written back to a project. At 1 the file is exactly what it was
before the stepper existed. Splitting changes the unit rather than the count: each file holds one
pattern, so the line gives the length per file instead.

Install it with `make install` (see [Installation](#installation)), then:

```sh
open -a "Key Step Pro Plus"
```

The build is unsigned beyond an ad-hoc signature, so it launches on the machine that built it and
nowhere else yet; a Developer ID build is M14.

**Naming.** The name field is the filename, and the filename is what MCC's Project Browser shows,
so it is worth setting. It sits in the staged view, above the destination it changes: type the name
before pressing Convert and the file is written under it, rather than written and then moved.

**It never overwrites.** A name already in use becomes `song 2.KeyStepPro`, and the window says so
while the file is still staged — MCC's Templates folder holds your own projects under freely chosen
names, so a clash is as likely to be something else's as a re-run of this one.

**If MCC is not installed**, `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/` will not
be there and the file goes to `~/Downloads` instead, with a message saying where to move it.

The app calls exactly the same `convert` and `export` that `ksp-swift-cli` calls — on the same
selection its output is byte-identical, and there is no second implementation to drift.


## `kspplus`

Every command is reachable two ways: under its own name, or as a `kspplus` subcommand. They are the
same command — same options, same output — so these two lines do the same thing:

```sh
uv run ksp2midi project_files/project_5.KeyStepPro -o project_5.mid
uv run kspplus ksp2midi project_files/project_5.KeyStepPro -o project_5.mid
```

`kspplus --help` lists the four, and `kspplus <command> --help` gives that command's options
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

Each pattern start carries a **marker** meta event naming the pattern — `pattern 2`, `pattern 3`
— so the seams of a merged export are exact rather than found by eye. A DAW puts them on its
marker ruler: Logic Pro's Marker track, Reaper's project markers, Pro Tools' Memory Locations.
They sit on the conductor track, where a DAW's ruler is global anyway, and pattern N starts at the
same point on every track. `--no-markers` leaves them out.

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
| `--tracks LIST` / `--patterns LIST` | Export only these tracks or patterns — comma-separated numbers and `N-M` ranges (`1,3`, `2-5`, `1,3-5`) |
| `--track LIST` / `--pattern LIST` | The same two options under their singular names |
| `--passes {auto,1,2,3,4}` | How many of the four 16/32/48/64 repeats to render (default `auto`) |
| `--repeat N` | Lay the whole export down N times end to end, 1–10 (default 1) |
| `--flat-velocity VALUE` | Render every note at one velocity instead of its stored value — `fresh` for the measured fresh-note velocity (100), or 1–127 |
| `--ticks-per-beat N` | MIDI resolution (default 480) |
| `--drum-map SPEC` | Same grammar and config file as `ksp-dump` (default `chromatic:36`) |
| `--default-gate STEPS` | Length used where a gate value is outside the measured 0–127 ladder (default 0.5) |
| `--drum-channel N` | MIDI channel for drum lanes (default 10) |
| `--include-stale` | Export both note sets of a pattern that holds both |
| `--include-disabled` | Export disabled notes — step turned off, or past the pattern's last step (the device plays neither) |
| `--no-markers` | Omit the marker that names the start of each pattern |
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

`--repeat` is the other thing entirely: it lays the whole export down again end to end, up to ten
times, and exists only in the `.mid`. The device stores no such count, so no repeat of it can be
written back to a project — which is why it is capped separately from `--passes` and named apart
from it.

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

Turn one or more MIDI files into KeyStep Pro patterns:

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
| `-o PATH` | Destination (default: the first input file with a `.KeyStepPro` suffix) |
| `--track N` | First KeyStep Pro track 1–4 to fill (default 1) |
| `--pattern N` | First pattern 1–16 to write to (default 1). Every target must be empty |
| `--template PATH` | Project to write into (default: MCC's factory default) |
| `--midi-track N` | Convert only track N of the source, into the one `--track`/`--pattern` names. One source file only |
| `--midi-tracks LIST` | Convert only these tracks of the source, as a song — comma-separated numbers and `N-M` ranges (`1,2,5`, `1-3`). Not usable with `--midi-track` |
| `--route SPEC` | Send named source tracks to named device tracks: `source:device` pairs, comma-separated (`3:1,1:2`). Tracks no pair names fill whatever is left, and a pair may only name a track `--midi-tracks` reads. Not usable with `--midi-track` |
| `--drum-track N` | Write source track N as drums, onto KeyStep Pro track 1 |
| `--no-drums` | Take no source track as drums; a channel-10 part comes in as ordinary notes. Not usable with `--drum-track` |
| `--drum-channel N` | MIDI channel drum detection listens to, 1–16 (default 10). `--drum-track` names a track outright and wins over it |
| `--drum-map SPEC` | `chromatic:N` or `custom:a,b,c,…` (default: fitted to the source) |
| `--flat-velocity VALUE` | Write every note and trigger at one velocity instead of the source's — `fresh` for the measured fresh-note velocity (100), or 1–127 |
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
  and dropped, and so is a fifth the selection itself named — the report says which of the two it
  was. `--midi-tracks` chooses which source tracks are read at all, leaving the rest of the file
  alone; `--midi-track` is the different, older thing, converting one track into the single pattern
  the target names. `--route` replaces that rule for the tracks it names — `--route 3:1,1:2` puts source
  track 3 on device track 1 and source track 1 on device track 2, and whatever is left still fills
  the tracks no pair claimed. The two are read together: `--midi-tracks` says which source tracks
  are read and `--route` says where the read ones go, so a pair naming a track the selection leaves
  out is refused. The source side counts from 1 over **every** track of the file,
  including ones carrying only tempo or a name; the device side is one of the KeyStep Pro's four.
  Only device track 1 carries a drum set, so a `--drum-track` may only be routed there and nothing
  else may be routed onto it; contradictions are refused rather than resolved. When a route is given the summary names each track's source, so what was
  applied is visible:

  ```
  wrote my_song.KeyStepPro
    track 1 [drum, source 4]: 64 note(s), pattern 1 (64 steps)
    track 2 [source 3]: 160 note(s), pattern 1 (48 steps)
  ```
- **Several files merge in argument order.** `midi2ksp bass.mid drums.mid` fills the device from
  both, `bass.mid`'s tracks first. Source tracks are numbered on continuously through the files —
  the first file's tracks, then the second's — so `--midi-tracks`, `--route` and `--drum-track`
  address any track of any file with no new spelling. `--midi-track` is the exception: it converts
  one track into one pattern, and takes one file only. The output is named after the first file
  unless `-o` says otherwise, and the summary names each track's file:

  ```
  wrote bass.KeyStepPro
    track 1 [source 1, bass.mid]: 32 note(s), pattern 1 (64 steps)
    track 2 [source 2, drums.mid]: 64 note(s), pattern 1 (32 steps)
  ```

  **The first file sets the timing.** Its tempo, resolution and time signature are the project's,
  since the device stores one of each; a later file that disagrees has its notes rescaled onto them
  and is reported, rather than silently overriding or being silently overridden. A file that cannot
  be read fails the whole run, naming it — nothing is written from a partial set.
- **A source track holding several channels becomes one device track each.** A type 0 file — one
  track, everything on it — tells its instruments apart by channel and nothing else, so merging
  them would put a whole arrangement on one track with the percussion in it as melodic pitches.
  Its channel 10 part becomes the drum track and the rest melodic, and the app says so before you
  convert rather than after. `--drum-track N` still means the whole of source track N, channels
  and all.
- **Drums are looked for on channel 10, and many files do not use it.** Logic and others export
  a kit on an ordinary channel, where nothing marks it as percussion and the whole set would
  come in as melodic pitches. `--drum-channel N` moves the search, and where a kit is found the
  drum-map warning names the channel it came from. `--drum-track` names a track outright,
  searches nothing, and wins; `--no-drums` stops the search the other way, and takes nothing.
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

A drum track is found on MIDI channel 10, which is what General MIDI reserves. Only the first one
is: track 1 is the only one carrying a drum set, so a second channel 10 part is imported
melodically. Plenty of files put drums on an ordinary channel instead, and for those
`--drum-track N` names it explicitly. Where a file's percussion is not wanted as triggers at all,
`--no-drums` takes nothing, so a channel 10 part comes in as ordinary notes on a sequencer track.

**Name the output file what you want the project called.** MCC's Project Browser lists the
*filename*, so `midi2ksp song.mid -o "Y Control.KeyStepPro"` appears as `Y Control`. The project
also carries an internal name, stored as an integer parameter whose encoding is undecoded and
therefore inherited from the template — but that is not what the browser shows, and it is not
worth working around.

## `ksp-pull`

Read a project off the device itself, with no MIDI Control Center in the way:

```sh
sudo uv run ksp-pull my_project.KeyStepPro --slot 3
```

MCC is otherwise the only way to get a `.KeyStepPro` file, and it wants a Recall To and an export
for every project. This asks the hardware directly and writes the same file, in about ten seconds.
What comes back feeds straight into the rest of the tool, so `ksp-pull` then `ksp2midi` turns what
is on the device into a MIDI file.

It reports what it did and how long it took:

```
read slot 3 in 9.6 s, 1007 requests
wrote my_project.KeyStepPro
  64 note(s), 120 BPM
  11.2 s total, 9.6 s of it at the device
```

The request count is the walk's own, so it can be compared against the figure in
[spec 7.8](./analysis/format/SysEx_Direct_Transfer_Path.md). The gap between the two times is the
3.5 MB template parse and the write, neither of which is the device's fault.

`--also-midi` writes the `.mid` as well, from the same read:

```sh
sudo uv run ksp-pull my_project.KeyStepPro --slot 3 --also-midi
```

It goes beside the project, `my_project.mid`, and it is byte for byte the file
`ksp2midi my_project.KeyStepPro` would have written — same defaults, same drum map, same warnings.
It saves the second command; it does not export differently, so reach for `ksp2midi` whenever you
want anything but the defaults. Both destinations are checked before the device is touched and
`--force` covers both; naming the project itself `.mid` is refused, because the two files would be
one and the export would land on the project. A project whose patterns hold no notes still writes
the `.KeyStepPro` and then fails: a MIDI file with nothing in it would look like success.

This is the one command that needs the USB extra from [Installation](#installation); the raw-USB
dependency is optional because most people converting files have no reason to install libusb. The
Swift CLI reaches the same wire through CoreMIDI instead, so it wants neither the extra nor `sudo`:

```sh
swift/.build/debug/ksp-swift-cli pull my_project.KeyStepPro --slot 3
```

Same options, same summary, same bytes: `scripts/pull_parity.sh` holds both cores to one
`.KeyStepPro` over the captured exchange. Two options are Python's alone — `--mcc-plan`, because
the Swift core carries one walk and no flag to choose another
([ADR 0003](docs/adr/0003-the-swift-core-reads-the-fast-plan-only.md)), and `--also-midi`, whose
exported `.mid` is the documented exception to the byte-for-byte contract either way.

Three things about the read:

- **It needs root on macOS.** The system binds its own USB-MIDI driver to the interface that
  answers SysEx reads and will not release it to an unprivileged process, so the command is run
  under `sudo`. Close MIDI Control Center first; it holds the same device.
- **`--slot` needs no help from the panel.** Slots are numbered as the device numbers them, 1–16.
  The read selects the slot itself.
- **A slot is read as it was saved.** Panel edits you have not saved are not in the file. A slot
  that was never saved is refused rather than written out as a plausible empty project.

| option | what it does |
| --- | --- |
| `--slot N` | which of the sixteen projects to read (default 1) |
| `--also-midi` | also write the `.mid` beside the project, as `ksp2midi` with no options would |
| `--force` | overwrite an existing output file |
| `--quiet`, `-v` | suppress the summary; list every diagnostic |
| `--timeout MS` | how long to wait for each reply (default 1000) |
| `--mcc-plan` | walk MCC's own 8,951-request stream instead of the coalesced one. Same file, about four times slower |
| `--no-identity` | skip the identity request and write the firmware version this tool already knows |
| `--template P` | take the file's full key set from `P` instead of the shipped factory default |

The default walk asks for up to 64 values per request and skips what the note pool's existence
array has already answered — the same addresses MCC reads, in about a ninth of the frames. The
device's reply period does not change with the payload size, which is why that is the whole of the
speedup.

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
