# KeystepProTool — Build Roadmap

A staged plan for building the MIDI ↔ KeyStep Pro converter, from first useful artifact to a
distributable macOS app.

**Prerequisite reading:** [`analysis/KeyStepPro_Format_Spec.md`](./analysis/KeyStepPro_Format_Spec.md).
The format is decoded and hardware-validated, so this is a build plan, not a research plan. What the
finished milestones established lives in the spec; this file carries status and what is left.

---

## Principles

**Every milestone ships something you can use.** Each has a concrete artifact and a test that runs
without having completed any later milestone.

**Prove reading before writing.** Misreading a file wastes time; miswriting one puts bad data on the
hardware. Reading is also self-validating in a way writing is not.

**Get something audible early.** Export to MIDI (M2) landed before import from MIDI (M5): it is the
easier direction, independently useful — MCC cannot do it — and it validates the format in a way you
can *listen to* rather than merely diff.

**Desk work before hardware work.** Most milestones are fully testable against the files in
`project_files/`. Only M7 and final validation still need the device.

---

## Stack

**M1–M7 in Python.** The format layer is where the remaining risk lives, and it is iterative,
exploratory work — the kind where a REPL matters. `mido` handles MIDI file parsing for free, which
has no equivalent in the Swift standard toolchain (CoreMIDI is real-time I/O, not file parsing).

**M8–M13 in Swift.** By then the core is a proven set of rules, so porting is mechanical translation
rather than reverse engineering. Swift wins decisively on distribution: a signed `.app` versus
asking other KeyStep Pro owners to manage a Python environment.

The port itself is M8–M12 and is most of the work — roughly 5,500 lines of Python, likely 7,000–8,000
of Swift. It ships no user-visible artifact, which is why it is broken into five milestones that each
end in a byte-comparison against the Python rather than in a feature. The Python does not retire when
Swift lands; it becomes the reference implementation the port is checked against, which is why both
live in this repo. M13 is the GUI, M15 is the full application and distribution is a repeatable
track rather than a milestone.

**The port has no discovery risk and real translation risk.** Nothing is left to reverse-engineer,
but thousands of lines of hand-converted bit arithmetic will contain bugs that look correct on
inspection — Python and Swift disagree on negative `%` and on integer overflow. The differential
harness in M12 is the answer to that, and it gets built at the start of M12, not the end.

---

## Milestones

M1–M5 are complete and their detail lives in the spec; what follows is the standing constraint each
one left behind, not the story of building it.

### M1 — Reader and dump ✅ **done**

`ksp.lenient_json` / `keys` / `constants` / `model` / `reader`, and `ksp-dump` (`--all`, `--track`,
`--pattern`, `--json`, `--drum-map`, `-v`) print any project as tracks → patterns → notes.

**The constraint:** the expected values in `tests/fixtures/` are **hand-transcribed from
`analysis/project_5_description.txt` and `project_9_tests.txt`**, not generated from the reader.
That is what makes them independent ground truth and what lets the Swift port (M10) be checked
against identical files. **Never regenerate them from the code.**

### M1.5 — Drum map ✅ **done**

`ksp.drum_map.DrumMap` — the 24-lane ↔ MIDI note mapping with GM percussion names, and
`ksp-dump --drum-map`. A drum note stores a *lane index* in `117`, not a pitch, so M2 cannot emit
one and M6 cannot turn an incoming note 36 back into a lane without it.

**The constraint:** the map is device-global (`paramId 65`) and **is not in the project file** —
not recoverable from one, not writable into one. It is treated as *configuration with a documented
default* (chromatic from 36, measured by D5), never as a decoded fact, and the tool always prints
which map it used. See spec §3.2.1.

### M2 — KeyStep Pro → MIDI export ✅ **done**

`ksp.midi_export` and `ksp2midi` (options in `README.md`). MCC has **no MIDI export for the KeyStep
Pro**, so this is the only one that exists — and there is no reference render to diff against.
`--passes` expands the 16/32/48/64 repeat cycle, `--no-time-shift` returns the flat grid, `--split`
sidesteps the layout question.

**The constraints:** the three layers stay separate — `render_pattern` → `arrange` →
`build_midi_file`, the only `mido` caller — and tests assert on `Rendering` data, not parsed MIDI.
The device stores no arrangement, so patterns holding notes are laid end to end and **pattern N
starts at the same tick on every track**, preserving the one relationship the hardware gives.

### M3 — Byte-identical round-trip ✅ **done**

`ksp.lenient_json.dumps` / `dump_path` / `canonical`, and `tests/test_round_trip.py` across all
five samples. `dump_path` writes to a temp file and renames it into place: these are 3.5 MB files
usually destined for MCC's Templates folder, where a half-written one would be found and parsed.

**The constraint:** output is **strict JSON**, so it is MCC's bytes minus the trailing comma (T6.2
showed MCC does not need it), pinned at exactly one byte by
`test_output_differs_from_mcc_by_exactly_the_trailing_comma`. The reader still accepts the comma,
because every file that exists has one.

### M4 — Targeted mutation ✅ **done**

`ksp.mutate` (`place_note`, `set_pitch`, `pitch_key`) plus the repository's first
`@pytest.mark.hardware` tests. **Confirmed on the device** 2026-08-01: the readback differed from
the candidate by zero keys. Melodic only — a drum note's lane is not a comparable write, and M6
owns that.

**The constraint:** placing a melodic note is **8 keys, not one** (recipe in spec §4), and
`ksp.mutate.place_note` is the only thing that should build that set. The desk gate is that
`place_note` reproduces the device's own `T1-note-place` capture byte for byte, so the recipe is
CI-enforced rather than local to one machine.

### M5 — MIDI → KeyStep Pro (MVP) ✅ **done**

`ksp.midi_import` and `midi2ksp` — one track into one pattern, still reachable as `--midi-track`.
Three layers mirroring M2's, inverted: `read_clip` (the only `mido` caller) → `quantise` → `apply`.
**Confirmed on the device** 2026-08-01, by ear rather than readback, so
`test_the_device_kept_the_converted_pattern` still skips.

**The constraints:** **template-and-overwrite** — start from a project, overwrite values, write
back, never synthesise the key set. Placement is not reimplemented: `apply` calls
`ksp.mutate.place_note`, and a regression therefore fails against what the device itself wrote. A
project's *name* is an undecoded integer parameter, so a converted project still inherits its
template's name in MCC's Project Browser.

### M6 — Full conversion ✅ **done**

**Artifact:** `midi2ksp` converts a whole file — every note-bearing track onto the device's four,
chords, a drum track, note lengths, tempo, fitted swing and time shift, and sequences longer than
64 steps split across pattern slots and chained. Real musical material instead of toy clips.

**Delivered:** `ksp.midi_import` widened from one clip to a song — `read_song` → `plan_song` →
`apply`, the same three layers inverted from M2 — plus the write primitives M4 left for it in
`ksp.mutate`: `place_drum_note`, `set_step_count`, `set_swing`, `set_drum_mode`, `set_tempo` and
`set_chain`. `tests/test_midi_import.py` converts `project_files/m6-test-file.mid` and reads the
result back through M1 with nothing to report.

**What it decided.**

- **Track 1 takes the drum track**, because item 123 is the only one carrying a drum set; the rest
  fill the tracks after it, and a fifth source track is reported and dropped. The mode flag `86`
  bit 6 is written to match whichever set the track holds.
- **A drum map is fitted to the source** when none is given, rather than falling through to the
  factory default. Reading a lane back can assume 36–59 and say so; writing one cannot, because a
  source whose drums sit anywhere else would have every hit dropped as unmapped.
- **A track's length is its content rounded up to the bar**, then cut into 64-step patterns. A loop
  that stops mid-bar drifts against every other track.
- **A chain is written only for a split track.** Every sample project leaves all 16 slots at the
  sentinel and still plays, so a chain is what makes several patterns one sequence — not what makes
  one pattern play. Writing one anyway would rewrite the scene of a project that was only asked to
  take a clip.
- **`place_note` picks its own pool chunk.** `idx2` is a 64-entry chunk of one flat pool, not a
  voice, so the 65th note spills into slot 2 and a chord may straddle the boundary. The only
  ceiling is 192 events per pattern; over it, the tail is dropped and counted. Track 1's slot 4
  stays zero-filled.
- **Placement got a delta form.** `note_updates` / `drum_note_updates` return the keys instead of a
  copy, because copying 153,495 keys per note turns a 300-note conversion into a wait.

**A reader bug fell out of it, and it was silent until now.** The melodic step skip `49` was read
from the note's own pool chunk. Like `48` it is step-indexed, so one entry per step fills chunk 1
exactly and chunks 2–3 are padding — 0 across all 1024 entries of every sample file, and Arturia's
descriptor fixes the middle index of both at `[1]` (spec §4). A pattern's 65th note therefore read
as playing on *no* pass. Nothing before M6 could put a note there, so nothing caught it. The
"16/32/48/64" warning `initial_project` used to raise was this artifact: every `49` entry it
actually uses holds 15. `project_5`'s real step skips are in chunk 1 and decode unchanged.

**The swing fit is a search, not an inverted median.**
[`analysis/Timing_Calibration.md`](./analysis/Timing_Calibration.md) §3.2 specifies snapping to the
nearest step and estimating swing from the aggregate residual. That breaks at the top of the
device's range: at 75 % a delayed step sits exactly half a step late, so nearest-step snapping puts
it on the *next* step and collapses each pair onto one. Scoring all 26 storable percentages against
the notes is exact at 75 %, still cheap, and still fits swing before spending any time shift. A
groove is also only believed with at least three notes on delayed steps — otherwise one late note
would be explained as swing and displace every other. Held to `ksp2midi` → `midi2ksp` round trips
at 50, 58, 66 and 75 %, so the two directions agree end to end rather than by construction.

**Confirmed on the device** 2026-08-06: the converted four-track project loaded, transferred and
played. That is the milestone — every capability M6 added is one no earlier milestone could put in
front of the hardware, so until this ran, "green" only ever meant *well-formed*.

What it establishes, and what it does not. Confirmed by ear, so it covers what the device *does*
with the file: the drum track plays from Track 1's drum set with `86` bit 6 set and the packed `52`
flags right, chords sound as chords rather than as one note per step, tied notes hold, and a
128-step track plays through as one sequence — which is the chain in `121_84` being honoured, the
one thing in this milestone with no desk-testable proxy at all.

Two things it deliberately does not establish:

- **No readback.** `test_the_device_kept_the_converted_pattern` skipped for M5 for the same reason
  and still does; M6's candidate now has the same shape waiting for it in
  `tests/test_hardware_import.py`. Worth ten minutes next time the device is out — M4 showed a
  readback diff is empty when the file is right, which makes it the cheapest regression net there
  is, and it is the only way to catch a value that loads and plays but is not the value we meant.
- **Not what the drum track transmits.** The lanes themselves were confirmed: the source's lowest
  pitch landed on the device's lowest lane and the four ran in order, which is what fitting the map
  from the lowest pitch is for. That holds whatever the device's own map says, because the global
  map decides only what MIDI note a lane **sends out** — not which lane plays. So the outbound
  notes are the part still unconfirmed, and they matter only when the drum track is driving
  something else.

**The fitted map is right for a contiguous source and only approximately right for a sparse one.**
`m6-test-file.mid` uses 31–34, four adjacent pitches, so chromatic-from-31 put them on lanes 0–3
exactly. A General MIDI kit is not adjacent — 36, 38, 42, 46 is kick, snare and two hats — and
fitting chromatically from 36 would place those on lanes 0, 2, 6 and 10. Every hit still sounds and
the ordering still holds, but three lanes of the device's grid are skipped where a drummer would
expect four in a row. Faithful to the intervals, not to the intent. Worth an option that packs
distinct pitches onto consecutive lanes instead; nothing in the format prevents it, and it is the
sort of thing that is obvious once a GM file is converted and invisible until then.

**The GUI decision is settled: build it.** The CLI does everything the format allows, so what is left
is reach — a full Swift port (M8–M12), a drag-and-drop app (M13), the full application (M15), and a
signed `.dmg` from the release track. No embedded Python.

### M7 — Timing calibration

**Artifact:** the measured constants for the encodings that place a note in time — gate length, time
shift, swing — as data, plus the randomness reading the timing work rests on.

Gate is **done** (issue #9): the encoding is an index, `stored = detent − 1`, 128 rungs,
0.0625–64 steps, drum ladder identical. `ksp.constants.GATE_TABLE` holds it and
`tests/test_gate_ladder.py` ties it to `analysis/gate_ladder.txt`. It came out clean only once a
*consecutive* run of detents was captured rather than scattered samples — the lesson the rest of the
tier inherits.

Tier 7 is **done** (2026-08-05) and tier 8 (2026-08-04) with it, which **closes this milestone** —
every timing encoding is now measured:

- **Time shift range and linearity** (`112` / `120`) — **#42**, protocol T7.1–T7.3. ✅ The range is
  displayed −49…+50, stored **0–99**, and `stored = 49 + displayed` holds at every one of the twelve
  points captured — no compression at the extremes, and drum `120` is identical to `112`. The
  go/no-go came back green: shift spans nearly the whole gap to the next step, so it is a usable
  quantization target for M5 rather than something to round away.
- **Swing semantics** (`74`, `97` / `114`) — **#43**, protocol T7.4–T7.7. ✅ An **absolute**
  percentage, 50–75 %, where 50 is both default and minimum, stored **per pattern** with the +25
  offset, displacing the even steps only. `reader._swing` was right and **MCC's own field label is
  wrong.** The **per-pattern value takes precedence over the global `74`**: a track at 75 % plays at
  75 % whether the global sits at 50 % or 75 %, so the two neither add nor swap. `ksp2midi` applies
  the per-pattern value and reports a non-default global, which is what the hardware does.
- **Randomness** (`113`) — **#44**, protocol T7.8. ✅ A **play probability**, not timing jitter:
  100 always sounds, 50 about half the time, the minimum never, and onsets never wander. The fresh
  default of 100 therefore means "always plays", which is what makes tier 8 measurable at all.
- **What one time-shift unit is worth in time** — **#45**, protocol tier 8. ✅ **1/400 of a beat**
  — 1.2 ticks at 480 PPQN, so the full +50 is 60 ticks, a 1/32 note. A **fixed count**: the same
  +50 displaced a note by 60 ticks at both a 1/4 and a 1/16 step (R1 against R3), and held its tick
  count across a fourfold tempo change (R2). Swing came out of the same recordings — the standard
  formula, matched to the tick at 63 % and 75 % — and swing and shift are **additive** (R5).
  `constants.TIME_SHIFT_UNITS_PER_BEAT` holds it and `ksp2midi` applies it.

  The trap worth remembering: at the 1/16 grid every sample project uses, the maximum shift is
  exactly half a step, so a step-relative reading fits the whole corpus and is wrong at every other
  step size. Only recording a second step size showed it.

See [`analysis/Timing_Calibration.md`](./analysis/Timing_Calibration.md) for the model and the
arithmetic. **Do not guess any of it** — a wrong timing constant produces files that load fine and
play wrong, with nothing to signal the error.

## Direct device read over USB SysEx

**Not part of the milestone ladder.** It is an additional input path, not a step toward the existing
milestones: it makes the hardware a second producer of the same flat dict `ksp.reader.read_project`
already consumes, so nothing downstream changes. The milestones stand whether or not this ever lands.

Today `ksp2midi` can only read a project MCC has already exported. This reads one off the device
directly. The protocol is decoded in
[§7 of the format spec](./analysis/format/SysEx_Direct_Transfer_Path.md); the design lives in
`docs/superpowers/specs/2026-08-05-usb-sysex-project-read-design.md`, whose Phase numbering this
section keeps.

### Phase 0 — the hardware-free half ✅ **done**

**Artifact:** `ksp.sysex` (frame codec), `ksp.bulk_plan` (the generated read plan) and
`ksp.bulk_read` (walks the plan against an injected transport and assembles the dict). No `pyusb`
anywhere in `ksp/`, so the Swift port swaps in CoreMIDI and reuses all three unchanged.

**Test, and it passes:** replaying a captured MCC Recall To exchange
(`tests/fixtures/recall_tape.txt`, 8,951 request/reply pairs) reconstructs **all 153,497 keys of
`initial_project.KeyStepPro`** — byte-identical to MCC's export minus the trailing comma this
writer deliberately omits, and its `ksp2midi` output is byte-identical too. Walking the
vendor-declared plan also reproduces MCC's 8,951 requests byte-for-byte and in order.

**Green here is not verified on hardware.** Phase 0 proves the codec and the plan against a
recording. The device's live output remains the sole ground truth.

### Phase 1 — the real transport ✅ **done, verified on hardware 2026-08-06**

**Artifact:** `ksp_cli/usb_transport.py` (libusb, interface 2, USB-MIDI packet framing) and
`tools/usb_probe.py`, one subcommand per probe. `ksp.sysex` gained the identity request and the
`0x05` prologue frame, so the firmware version no longer has to be assumed.

**Tested without a device:** framing round-trips all 8,951 captured request and reply frames, and
de-framing by code index number keeps the padding zeros out — the bug the investigation script has,
visible as `f7 00 f0` in its log. `parse_identity` decodes the captured reply to `2.5.20`.

**All six probes ran on 2026-08-06 and all six confirm** — ledger and raw output in
[the hardware protocol](./analysis/Hardware_Test_Protocol.md). The identity reply came back
byte-identical to the capture's, `120_37` read `3`, and the `0xFF` sentinel arrived raw on patterns
1–13, so the `247` in every project file is confirmed as MCC's corruption of it. On macOS the
probes need `sudo`: the system binds its own USB-MIDI driver to interface 2 and will not release
it to an unprivileged process.

Three probes changed what later phases should do:

- **H1.4 — there is no handshake for re-reading what is already loaded.** A read succeeds with
  neither the identity request nor the `0x05` frame when the target is the project already on the
  panel. Selecting a different project still needs `05 <slot>`, and `bulk_read` sends it. The
  identity request is still needed for the version string, but not to open the conversation.
- **H1.3 — `count=64` is honoured and free.** The per-request period does not move with payload
  size (3.994 ms at 16, 3.998 ms at 64), so a full dump drops from 38.3 s to 9.6 s. **Taken, and
  without touching MCC's stream:** `ksp.bulk_fast` derives a second walk from the same `PLAN`
  rather than rewriting the generated one, so `bulk_plan` and the pin `test_bulk_plan.py` holds it
  to are unchanged. Coalescing each contiguous run into one request and gating the melodic pool
  takes 8,951 requests to about 2,500 — past the 4× this probe measured
  ([spec 7.8](./analysis/format/SysEx_Direct_Transfer_Path.md)). H3.2 has since run, and the
  coalesced walk is `read_raw`'s **default**.
- **H1.6 — the ceiling is 100, and overruns are silent.** `count` clamps to 100 whatever the start
  index, and the reply echoes the count it honoured rather than the one asked for. Reading past a
  parameter's extent is not an error: the device pads to the full count with the item's own unset
  value, which no reply distinguishes from real data. So the untested case in H1.3's note is now
  tested, and the risk moved — an overrunning request is safe to send, and a raised count must clip
  by the plan's declared extent rather than trusting reply length
  ([spec 7.7](./analysis/format/SysEx_Direct_Transfer_Path.md)).

`ksp_cli/pull.py` **has landed** — `ksp-pull` is a declared console entry point on the `kspplus`
group, so `sudo ksp-pull OUT.KeyStepPro [--slot N]` reads the coalesced walk by default
(`--mcc-plan` for MCC's own 8,951-request stream). It is the full-dump CLI Phase 3's H3.1 gates.
`tests/test_pull_cli.py::test_the_dump_is_byte_identical_to_mcc_s_export` runs it against
`FakeDevice` fed by `tests/fixtures/recall_tape.txt` and pins the 2,474-request replay figure and
byte-for-byte agreement with `initial_project.KeyStepPro`, minus MCC's trailing comma.

**Phase 3 ran on hardware 2026-09-04 (firmware 2.5.20, slot 1) and both gates passed over
CoreMIDI.** H3.1 read 153,497 keys in 2,474 requests and 11.4 s, twice, byte-identically; H3.2 put
that read against MCC's own export of the same slot and found **3 differing keys of 153,497**, all
three the `MCC_CONSTANTS` this reader writes from a table rather than off the wire. The same slot
read with the pre-[#255](https://github.com/bauerc/KeystepProTool/issues/255) walk differed on 114.
Those three are overrun padding rather than parameters — `120_55` and `120_56` hold 4 and 3 entries
against the 1–5 MCC reads ([spec 3.4](./analysis/format/Parameters_Scenes_Tracks_And_Project.md)) —
so a `cmp` can never land on the file's last line and the key diff is the form this check takes.
One item stays open: the raw-USB half of H3.1 (`sudo ksp-pull`, and the `cmp` of the two cores on
the wire, held so far only over the tapes) — see
[the hardware protocol's Phase 3](./analysis/Hardware_Test_Protocol.md#phase-3--acceptance).

- **Phase 2 ran on hardware 2026-08-14 (firmware 2.5.20) and all four probes passed** — H2.1–H2.4
  ([hardware test protocol](./analysis/Hardware_Test_Protocol.md)). `tools/usb_probe.py phase2`
  walked 115 requests in 440 ms and reproduced the scratch project's note pool, step-active bits
  and MIDI export exactly, including the one deliberately long gate. **Phase 4's H4.1 rode along in
  the same run and settled project selection**: it is the `05 <slot>` prologue that selects the
  project, confirmed across all sixteen slots
  ([spec 7.4](./analysis/format/SysEx_Direct_Transfer_Path.md)). A project chooser is therefore
  possible: `ksp.sysex.prologue(slot)` builds that frame and `ksp.bulk_read.read_raw(..., slot=)`
  sends it before reading, so naming a slot is sufficient and no caller has to remember the
  prologue itself.

No console entry point is declared until the milestone lands, per CLAUDE.md.

### Open items

- **The write direction is decoded but unimplemented.** A write is the read protocol with the
  reply opcodes sent as requests, over the same 8,951 addresses in the same order — so
  `ksp.bulk_plan` is already the write plan ([spec 7.5](./analysis/format/SysEx_Direct_Transfer_Path.md)).
  Phase 0 remains read-only and nothing in `ksp/` encodes a write. Two things block one: `06 <slot>`
  looks like a commit and is untested, and a value read as `0xFF` **cannot be sent back** — MCC's
  attempt stalled the device (spec 7.6).
- **`0xFF` is the device's unset sentinel**, and `247` is MCC's corruption of it in transit. A
  *file* writer must keep emitting `247`; a *device* writer must not. See
  [per-pattern scalars](./analysis/format/Parameters_Pattern_Scalars.md).

### M8 — Swift package skeleton and CI wiring ✅ **done**

**Artifact:** a `swift/` package that builds, tests and lints alongside the Python, with
[`swift-midi-file`](https://github.com/orchetect/swift-midi-file) 1.0.2 resolved and spiked. Ruff,
pre-commit and `check.yml` are path-scoped so the two toolchains ignore each other; mypy already was.

**Four targets, not three, because `swift-midi-file` is Apple-only** — its compatibility table
lists Linux as WIP, unlike `swift-midi-core` and `swift-timecode` underneath it. So `KSPKit` (the
format core, M9–M11) takes no third-party dependencies and `KSPMIDI` (M12) holds the one import,
splitting where M12 already drew the line. `Package.swift` gates `KSPMIDI`, `KSPSwiftCLI` and
`KSPMIDITests` off on Linux, which puts the bulk of the port on the 1× runner; only M13 and the
release track need
macOS. The cost is that those three targets are checked by `./scripts/validate.sh` alone —
`swift.yml` cannot see them, and **M12 must add a `macos-latest` job** when they gain real code.

**Swift Testing works without Xcode, but not out of the box.** The Command Line Tools do ship it,
as `Testing.framework` under `$(xcode-select -p)/Library/Developer/Frameworks` — the earlier "not
found" was a search of the wrong directory. What they do not do is put it on the compiler's search
path or the runtime's, and the `_Testing_Foundation` cross-import overlay has no `.swiftinterface`
there at all, so any test importing both `Testing` and `Foundation` fails to build. Three flags
bridge it (`-F`, `-Xfrontend -disable-cross-import-overlays`, `-Xlinker -rpath`), and
`scripts/validate.sh` adds them only when the developer directory is a CLT install. XCTest is not
in the CLT in any form, so it was never the fallback the issue assumed.

**Test:** `swift test` and `swift format lint --strict` pass; `./scripts/validate.sh` runs both
toolchains. Note there is no `swift format --lint` flag — `lint` is a subcommand, and without
`--strict` it exits 0 on a violation.

### M9 — Swift port: constants, keys, lenient JSON, diagnostics ✅ **done**

**Artifact:** the leaf layers — everything `reader.py` stands on. `constants.py`, `keys.py`,
`lenient_json.py` (read side only) and `diagnostics.py`, in that dependency order.

**Where the bugs actually were.** Not overflow: every field in this format is 7 bits, so the bit
manipulation never comes near `Int`'s edge and no `&<<` is needed. The two that bit are both
rounding. Python's `//` and `%` floor while Swift's truncate toward zero, which reaches
`note_name` (`pitch // 12 - 2` under middle C) and `root_note_name`; both go through floored
helpers. And Python's `round` breaks a tie to even where Swift's `rounded()` breaks it away from
zero, so `time_shift_ticks` rounds `.toNearestOrEven` — no standard PPQ produces a tie, but a
pinned test means the port cannot drift onto one.

**`JSONSerialization` hands `1` and `true` back as the same `NSNumber`**, and telling them apart
again means CoreFoundation, which is exactly what `KSPKit` must not carry if it is to stay
Linux-clean. The reader uses `JSONDecoder` over a dynamic-keyed container instead, and a value
outside the format's int-or-string shape keeps the name Python gives it so both ports refuse a
malformed file with the same words. `ValueError` and `TypeError` come across as one `KSPError`
with two cases, for the same reason.

**Test:** the corresponding Python unit tests, ported, asserting the same values — 77 of them,
covering all 128 gate rungs against `analysis/gate_ladder.txt`, tier 5's pattern-bits sweep, the
parameter 52 packing, and every sample project through the loader. The 46-entry summary table was
diffed against Python's and is byte-identical, template, subject and site.

### M10 — Swift port: drum map, model and reader ✅ **done**

**Artifact:** `ksp-swift-cli dump` reads a real `.KeyStepPro` and reproduces the Python's output —
both the tree and `--json`.

**Delivered:** the second half of the read path in Swift.

- `swift/Sources/KSPKit/DrumMap.swift` — port of `src/ksp/drum_map.py`, plus a `DrumMapConfig` for
  the config file so path resolution stays in the CLI.
- `swift/Sources/KSPKit/Model.swift` — port of `src/ksp/model.py`; every type a value type.
- `swift/Sources/KSPKit/Reader.swift` — port of `src/ksp/reader.py`.
- `swift/Sources/KSPKit/JSONNode.swift` — an ordered JSON writer, new, with no Python twin.
  `JSONEncoder` cannot reproduce `json.dumps(indent=2)`: it gives no control over key order and
  renders an integral `Double` as `120` where Python writes `120.0`. So the model's `toJSON()`
  methods build a `JSONNode` carrying each Python `to_dict`'s insertion order, and
  `Diagnostic`/`Site`/`Report` gained the same instead of the `Encodable` conformance M9 left them
  with, which had ordered its keys differently from the Python.
- `swift/Sources/KSPSwiftCLI/` — the `dump` subcommand with `--all`, `--track`, `--pattern`,
  `--json`, `--drum-map` and `-v`, on swift-argument-parser. Exit codes are remapped to this
  project's 0/1/2 in the `@main` entry point, because ArgumentParser's own default for a usage
  error is 64.

**Test, and this is the milestone's whole point:** `swift/Tests/KSPKitTests/GroundTruthTests.swift`
and `EmptyProjectsTests.swift` read `tests/fixtures/project_5.expected.json`,
`project_9.expected.json` and `empty_projects.expected.json` — the same files the Python's
`test_ground_truth.py` and `test_empty_projects.py` read, not translations of them. That is what M1
wrote those fixtures in JSON for. They stay hand-transcribed from the hardware display and must
never be regenerated from either implementation.

`scripts/port_parity.sh`, new, diffs `ksp-swift-cli dump` against `uv run ksp-dump` over all six
files in `project_files/`, in both output modes; all twelve comparisons are identical.
`scripts/validate.sh` gained it as step 7 of 7. CI cannot run it — `KSPSwiftCLI` is gated off Linux
— so it is a dev-machine gate. The Swift suite is now 191 tests in 15 suites; the Python suite is
unchanged at 723 passed, 2 skipped.

**The standing constraint:** the two ports' `dump` output is a byte-for-byte contract, held by
`scripts/port_parity.sh`. Anything that changes what either CLI prints — a diagnostic's wording, a
key's position in the JSON, a number's formatting — has to change both sides in the same commit.
The Python remains the reference implementation.

### M11 — Swift port: byte-identical writer ✅ **done**

**Artifact:** the Swift equivalent of M3. `KSPKit` reads any sample and writes back MCC's bytes —
tab indentation, no final newline, and `device`, `version`, then the numeric keys **sorted as
strings**, so `126_99_16` precedes `126_99_2`.

**Delivered:** the write half of the dialect, in `swift/Sources/KSPKit/LenientJSON.swift` beside
the read half, as one module is on the Python side.

- `LenientJSON.serialise(_:)` — `dumps`. Never sorts: it emits the order it is handed.
- `LenientJSON.write(_:to:)` — `dump_path`. Atomic, then the mode widened to 0644 as the umask
  allows, because these files are usually destined for MCC's Templates folder.
- `LenientJSON.canonical(_:)` — MCC's key order, and the only thing here that orders anything.
- `JSONNode.quoted(_:)` became internal instead of private. It already reproduced Python's
  `encode_basestring_ascii` exactly for the dump's `--json`, and Python reaches for that same
  function from both `json.dumps` and `lenient_json.dumps`, so the port shares one escaper too.

**`canonical` returns ordered pairs, not a mapping — the one deliberate divergence.** `RawProject`
is a Swift `Dictionary`, so there is no "the mapping's own iteration order" for `serialise` to
preserve and relying on one would make the output differ between runs. The split the Python insists
on survives intact and arguably sharpens: `serialise` genuinely never sorts, and ordering is
entirely `canonical`'s job. It costs nothing, because **every sample MCC wrote is already in
canonical order** — checked on all six — so the round trip still lands on its bytes exactly.

**Two Python tests have no faithful Swift twin, and the reason is the same in both cases: Foundation
has no strict JSON parser.** `JSONSerialization` and `JSONDecoder` both accept MCC's trailing comma,
measured on this toolchain, so `test_is_not_strict_json` cannot be stated at all and
`test_dumps_is_strict_json` loses its strictness half — what survives is that the output parses back
to what went in. The Python holds that premise for both ports; on this side it is carried by byte
identity with MCC's file instead. `test_round_trip_md5_matches` is also dropped: it restates byte
equality for issue #5, and CryptoKit's MD5 is Apple-only, which would push a `KSPKit` test off the
1× Linux runner for nothing.

**Test:** `RoundTripTests.swift` and `FormatInvariantsTests.swift`, ports of
`tests/test_round_trip.py` and `tests/test_format_invariants.py`, over all six samples — including
the twin of `test_output_differs_from_mcc_by_exactly_the_trailing_comma`, which is what pins the
deviation at one byte. The Swift suite is now 212 tests in 17 suites, up from M10's 191 in 15; the
Python suite is unchanged at 723 passed, 2 skipped.

Parity with the Python needed no new CLI surface: both writers are pinned against the same third
thing, MCC's bytes minus that comma, so equality is transitive. `scripts/writer_parity.sh`, new,
says it directly instead — all six samples through both writers, `cmp`-identical, with the Python's
own output checked against MCC's export on the way past, since a port-to-port diff cannot see the
case where both broke the same way. `validate.sh` runs it as step 8 of 8, beside `port_parity.sh`
and, like it, a dev-machine gate. There is no CLI to drive and none was added: `KSPKit` has no
dependencies, so three lines of scratch compile straight into a binary alongside it.

**That script caches its binary on a hash of the sources, never on their timestamps**, and the
reason is worth keeping. The first version compared mtimes and was immediately caught out: reverting
an edit restored the file's *original* mtime, older than the binary built from the mutated source,
so the gate silently re-ran code that was no longer on disk and failed a tree that was correct. A
checkout, a stash pop and a branch switch all do the same thing. A stale green here would be worse
than no gate at all.

**Two things worth knowing for M12.** Swift's `sorted()` agrees with Python's on these keys, checked
across all 153,495 numeric keys of `project_5` rather than assumed — they are ASCII, where Swift's
canonical ordering and Python's code-point ordering coincide, so no custom comparator is needed (and
a hand-written one would be *slower*, since our code is unoptimised in a test build and the stdlib
is not). And `#expect(a == b)` on 3.5 MB of `Data` renders both sides into the failure message,
which turns a one-byte drift into minutes of output; `firstDifference` in `TestSupport.swift`
reports the offset and the line either side of it instead, and every bulk comparison goes through
it.

### M12 — Swift port: MIDI export, import and the differential harness ✅ **done**

**Artifact:** parity with the Python CLI. `ksp-swift-cli export` and `ksp-swift-cli convert`
convert in both directions, and `scripts/midi_parity.sh` reports **zero diffs across 60
conversions** — six sample projects in seven export modes, three committed clips in six import
modes — agreeing on exit code, stdout, stderr and the artifact every time.

**The harness was built first, and that was the whole point.** It landed in its own PR with
nothing to compare yet, so both conversion PRs were gated from their first commit. It compares four
things per case rather than one, which is what makes it safe to throw the whole corpus at it: a
shared *refusal*, worded the same way, is agreement rather than a skip. Verified before it had
anything to gate by standing a shim that dispatches to the Python in for the Swift binary — 66
conversions agreed, and a shim perturbed to drop time shift was caught on every affected case by
the artifact comparison **and** by stderr independently.

**The export direction compares parsed events, not bytes, and the reason is not ours.** mido's
`write_track` emits MIDI running status; `swift-midi-file`'s `Track+Encoding.swift` carries a
`TODO` saying it does not. `tools/midi_events.py` is the level the comparison moves up to. The
import direction needed no such concession: it writes `.KeyStepPro` files through M11's writer, so
it gets a real `cmp` and passes it.

The size of the divergence is worth knowing, because it is not uniform. `project_5` comes out
**byte-identical at 391 bytes** — its notes alternate on and off, and a note-on and a note-off carry
different status bytes, so running status never engages. `initial_project` is where it shows: 4,981
bytes from mido against 5,297 from Swift, a 316-byte difference that is **entirely** running status,
with identical event streams. So a byte comparison would have passed on the simplest sample and
failed on the realistic one — which is exactly the shape of gate worth not having.

**Where the bugs were, and both were found by reading rather than by a failing test** — which is
the kind this milestone was most exposed to, since they look correct on inspection:

- **`swift-midi-file` truncates BPM to microseconds where mido rounds.** Its `tempo(bpm:)` computes
  `(60 / bpm) * 1_000_000` and then `UInt32(_:)`; mido's `bpm2tempo` is `int(round(60 * 1e6 / bpm))`.
  The device stores BPM to two decimal places, so a tempo landing just under a whole microsecond
  would be written one lower on one side. `bpmToMicroseconds` does it mido's way and the library's
  convenience constructor is deliberately unused.
- **`URL.path` resolves a relative path against the working directory** where `pathlib` prints what
  it was given, so every summary line named an absolute file. `relativePath` is the twin. The
  harness caught this one on its first run.

**`Mutate.swift` is in `KSPKit`, not `KSPMIDI`.** `mutate.py` imports no `mido`, so it is `ksp/`
minus MIDI by CLAUDE.md's split — which puts the 576-line module carrying the 8-key note recipe on
CI's free Linux runner rather than the 10× macOS one.

**The template moved rather than being copied.** SwiftPM resources must live under their own
target's directory, and SwiftPM copies a symlink *as a symlink* — measured, with both `.copy` and
`.process`, which lands a dangling link in the bundle. So the real bytes are now
`swift/Sources/KSPRun/Resources/Default.KeyStepPro` (`KSPSwiftCLI/` until M13.1 moved the command
bodies down a target) and `src/ksp_cli/templates/` holds the
symlink: Python and hatchling both follow one transparently, and the built wheel still carries the
full 3.5 MB. The repository keeps the two real copies it already had — that one and the untouchable
sample in `project_files/` — rather than gaining a third. `TemplateTests` pins all three against
each other.

**`swift.yml` gained the `macos-latest` job M8 said this milestone would need**, because
`Package.swift` gates `KSPMIDI` and `KSPSwiftCLI` off Linux and nothing else can see them.

**Two Python assertions have no faithful Swift twin.** `midi.length` in *seconds* is asserted twice;
`swift-midi-file` exposes no duration property, and reimplementing mido's tempo walk inside a test
would be testing the reimplementation. Both are ported as tick-length assertions on the
`Arrangement`, which is what determines the seconds and is the layer this milestone is meant to
assert on. The timecode refusal is also stated differently: the Python builds it with a *negative*
`ticks_per_beat`, because mido reads the division field signed, and `swift-midi-file` types the two
apart so a timecode file decodes as `SMPTEMIDI1File` and never reaches the check.

**Test:** the Swift suite is 358 tests in 36 suites, up from M11's 212 in 17; the Python suite is
unchanged at 784 passed, 2 skipped. `validate.sh` now runs nine steps, the ninth being
`midi_parity.sh`.

**Green here is still not verified on hardware.** Every gate is a comparison against the Python.
The final listen — a Swift-converted project loaded and played on the device — is what closes the
port, and it is the one step no script can do.

### M13 — Native GUI ✅ **done**

**Artifact:** *Key Step Pro Plus*, the drag-and-drop macOS app (SwiftPM product `ksp-app`). Drop a
`.mid` and a `.KeyStepPro` lands in
`/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/` (mode `0777`, no elevation needed,
confirmed 2026-08-07); drop a `.KeyStepPro` and a `.mid` lands beside it.

**v1 is drag-and-drop only** — one window, one file, no options. The larger app in
`project_requirements/project_requirements.md` (preview, per-track routing, loop counts) needs its
own specs. Sandbox off, since a sandbox cannot write into another app's directory and Developer ID
distribution permits it.

**Split in two: M13.1 the seam, M13.2 the app.** SwiftPM forbids a non-test target from depending
on an executable one, so the command bodies inside `KSPSwiftCLI` were reachable only from the CLI
and no app could call them. M13.1 moved them down into a `KSPRun` library, taking the bundled
template with them, and proved it changed nothing by re-running the three parity scripts.

**Full Xcode was not required, and the estimate that it would be was wrong.** Measured on a
Command Line Tools 6.2.3 machine: the CLT SDK ships `SwiftUI.framework`, `AppKit.framework` and
`UniformTypeIdentifiers.framework`, and `codesign`, `notarytool`, `stapler` and `iconutil` are all
on `xcrun`'s path — which likely unblocks the release track on the same terms. Only `xcodebuild`,
`actool` and
`ibtool` are absent, and a hand-assembled bundle needs none of them. So the GUI is an ordinary
SwiftPM `executableTarget` inside `swift/`, tested by the same `validate.sh` as everything else,
and `scripts/bundle_app.sh` assembles and ad-hoc signs the `.app`. No `.xcodeproj`, no 15 GB
install.

**What holds it honest:** the app calls `ConvertRunner`/`ExportRunner` directly and owns no format
logic — only where a file goes and what it is called. Checked by converting the same source both
ways: the app's output and `ksp-swift-cli convert`'s were byte-identical. The placement rules
(Templates vs the `~/Downloads` fallback, name sanitising, the never-overwrite `song 2` ladder)
are `KSPAppTests`, which is also what makes `swift test` compile the GUI on every run.

**The rename control is a feature, not a workaround.** MCC's Project Browser lists the *filename* —
the Templates folder holds freely named files. The claim in `README.md` that a converted project
"may show the template's name" confused that with the undecoded integer parameter *inside* the
file, and was corrected here.

**Start Apple Developer Program enrolment now**, not when the release track starts — it can take days.

**Test:** drag a `.mid` onto the app, restart MCC, pattern is there.

### M14 — retired

Distribution was M14. It has been taken off the ladder — see **Release track** below — and the
number is not reused. The application's own remaining work is M15.

### M15 — The full application

**Artifact:** *Key Step Pro Plus* as `project_requirements/project_requirements.md` describes it,
rather than the deliberate one-window v1 M13 shipped. Preview, per-track routing, loop counts,
metadata control and multi-file import.

**Spec of record is the epic, issue #115**, which holds the requirement-coverage table and the
frontier. Forty issues, each a vertical slice sized to a PR a human can read in one sitting.

**Requirement D1's evidence is [`analysis/Read_Cost.md`](analysis/Read_Cost.md)** — what a read
costs in each core, where the cost goes, and the bytes held per byte of file, reproducible through
`./scripts/bench_read.sh`. Its §8 is the defect that measurement found and #238 fixed: one drop
parsed the project once per reader, and `Reader.load` now caches.

**Most of it is wiring, not format work.** `ExportRunner.Options` and `ConvertRunner.Options`
already carry `split`, `track`, `pattern`, `passes`, `includeStale`, `includeDisabled`,
`applySwing`, `applyTimeShift`, `dryRun`, `midiTrack`, `drumTrack`, `drumMapSpec` and
`stepsPerBeat` — the app has simply never set them. Those issues are labelled `app` and touch no
parity script. The rest are labelled `core-parity` and land in both cores in one commit.

**The preview exemption is what keeps this affordable.** A summary type that adds no CLI text needs
no Python mirror and runs no parity gate, so both summaries live in `KSPRun` composed from existing
`KSPKit`/`KSPMIDI` reads. A preview issue that quietly adds a CLI flag doubles its own cost.

**Test:** convert the same file through the app on defaults and through `ksp-swift-cli` on defaults,
and get the same bytes — the check that the options surface did not change what conversion means.

### M16 — The app's visual language

**Artifact:** the app wearing the KeyStep Pro's own documented visual system, and a bundle icon
where there was none. Look only — no conversion behaviour, no CLI change, no new option.

**Spec of record is [ADR 0002](docs/adr/0002-the-app-wears-the-devices-visual-language.md) and
[the visual language](docs/design/visual-language.md).** Six issues, #221–#226, all labelled `app`.

**Why it is not an M15 child.** M15 is the application's remaining *function* — routing, loop
counts, multi-file import. This changes nothing about what the app does, so it does not belong on
that epic's requirement-coverage table.

**The spine is the four track colours.** Manual 2.5.2 §1.4 — *"Green for Track 1, Orange for Track
2, Yellow for Track 3 and Red for Track 4"* — painted on the panel and lit on the step buttons, and
the pattern map is four rows. Light mode is the standard unit, dark is the Chroma; both are real
products and neither palette is derived from the other.

**Three rules bind any later edit**, and are the ones an unwary change breaks: hue never carries
text contrast (Track 3 is `#FACC00`); status never relies on hue (Track 2 is orange and Track 4 is
red); the numerals are the device's, so **`C3` is MIDI 60 and is not a bug**.

**The parity contract is untouched by design.** The preview grids emit no CLI text and were already
exempt. `Report` and its `render()` are not — both CLIs print them, and `ConversionTests` asserts
on `resultLine`, `previewLine` and finding fragments. This milestone changes how findings look,
never what they say. **The CLI's own output stays uncoloured, permanently.**

**Test:** launch the app in both appearances and walk idle → drop → staged → converting → done for
each direction. There is no UI test in this repo, so each issue is reviewed as a screenshot. The
deliberately hard cases are Track 3's yellow on the light ground, a finding row beside a Track 2
row, the icon at 16pt, and `reduce-motion` during a conversion.

---

## Release track — off the ladder

Signing and distribution are **not** a milestone. They gate nothing: signing is a post-build step,
every milestone before it builds and runs unsigned for free, and paying for a Developer ID later
requires no rebuild — `codesign --force` replaces whatever signature is there, including none. And
they are not done once: every release re-signs, re-notarises and re-staples. A milestone that
completes and stays complete is the wrong shape for that.

So it is a repeatable track, tracked in issue #10, split into four self-contained pieces:

| | |
|---|---|
| **R1** | Developer ID identity and hardened runtime |
| **R2** | notarise and staple |
| **R3** | assemble the `.dmg` |
| **R4** | versioned release automation |

R1 needs $99/yr Apple Developer Program membership. There is no free notarisation, and macOS 15+
removed the right-click → Open bypass, so unsigned means the recipient must dig through System
Settings and authenticate as an admin — which fails the test. The Command Line Tools suffice:
`codesign`, `notarytool`, `stapler` and `iconutil` are all on `xcrun`'s path, measured during M13.

**Test:** hand a downloaded `.dmg` to someone else with a KeyStep Pro and have them convert a file
without touching a terminal or reading setup instructions.

---

## Dependency summary

| Milestone | Status | Needs hardware? | Depends on |
|---|---|---|---|
| M1 Reader | ✅ done | No | — |
| M1.5 Drum map | ✅ done | No — D5/D6 confirmed the default | M1 |
| M2 MIDI export | ✅ done | No | M1, M1.5 |
| M3 Round-trip | ✅ done | No | M1 |
| M4 Mutation | ✅ done | **Yes** (done) | M3 |
| M5 MVP convert | ✅ done | **Yes** (done) | M3 |
| M6 Full convert | ✅ done | No (desk-testable) | M5, M1.5 |
| M7 Timing calibration | ✅ done | **Yes** (done) | M3 |
| M8 Swift skeleton | ✅ done | No | M6 |
| M9 Swift leaf layers | ✅ done | No | M8 |
| M10 Swift reader | ✅ done | No | M9 |
| M11 Swift writer | ✅ done | No | M10 |
| M12 Swift MIDI both ways | ✅ done | For final listen | M11 |
| M13 GUI | ✅ done | For final check | M12 |
| M15 Full application | | For final check | M13 |
| R Distribution | | For final check | M13 — but gates nothing, and repeats every release |

---

## Still open in the code, not in the format

Both are understood; neither has reached the code.

- **`constants.SLOTS_BY_ITEM[123]` is 4 and should be 3.** `idx2` is a 64-entry pool chunk, not a
  poly voice, and no `bulkOperation` descriptor addresses a note parameter at index-2 value 4 — item
  123's arrays are dimensioned `16 × 4 × 64` only because `52` needs 240 entries, and every
  parameter in the item inherits that shape. Since the count is then uniform, consider collapsing
  the dict to a scalar. `reader.slot_is_initialised` and its zero-fill heuristic go with it: slot 4
  is zero-filled because nothing addresses it, not because the firmware forgot to initialise it.
- **`P_DRUM_POLY_STEP_COUNT` (`51`) is read by nothing.** It is per-lane drum step count, indexed by
  lane 1–24, confirmed real by capture D4 — which is how the KeyStep Pro does polyrhythm on the drum
  track. Until something reads it, every lane renders at the pattern-level `115`. The flag that
  governs it is now decoded on both halves (`99` / `116` bit 2, spec §3.3), so what is missing is
  the rendering, not the reading.
- **Playback direction is decoded and not applied.** Rand and Walk have no MIDI equivalent, so
  `ksp2midi` renders those patterns forward and warns. Rendering a plausible random order would be
  inventing a performance the device did not give us.

Every *tier* of [`analysis/Hardware_Test_Protocol.md`](./analysis/Hardware_Test_Protocol.md) is
closed, including H2.1–H2.4 and H4.1, which confirmed on hardware 2026-08-14 that the `05 <slot>`
prologue selects the project. Its procedures are removed; what is left there is the method, for
whatever question comes next.
