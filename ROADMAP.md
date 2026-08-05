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

**M8–M9 in Swift.** By then the core is a proven set of rules, so porting is mechanical translation
rather than reverse engineering. Swift wins decisively on distribution: a signed `.app` versus
asking other KeyStep Pro owners to manage a Python environment.

**A caveat worth stating up front:** the workflow is inherently batch-shaped — convert a file, drop
it in MCC's Templates folder, restart MCC. That is not interactive, so the CLI may simply be
sufficient and M9 may never be worth building. Decide after M6.

---

## Milestones

### M1 — Reader and dump ✅ **done**

**Artifact:** `ksp-dump project_5.KeyStepPro` prints a readable tree — tracks → patterns → notes.
Inspect any project file without opening MCC.

**Delivered:** `ksp.lenient_json` / `keys` / `constants` / `model` / `reader`, and the `ksp-dump`
command (`--all`, `--track`, `--pattern`, `--json`, `--drum-map`, `-v`).

**Test:** output reproduces `analysis/project_5_description.txt` and `analysis/project_9_tests.txt`.
Expected values live in `tests/fixtures/` as JSON, **transcribed by hand from those documents rather
than generated from the reader** — that is what makes them independent ground truth, and what lets a
future Swift port be checked against identical files. Never regenerate them from the code.

**One discrepancy is asserted rather than resolved.** `project_5_description.txt` gives Time Shift
−1 for both kick hits; the file stores −1 and **+1**. The fixture holds the conflict so it cannot
quietly disappear. Protocol T6.1 settles it.

### M1.5 — Drum map ✅ **done**

**Artifact:** `ksp.drum_map.DrumMap` — the 24-lane ↔ MIDI note mapping with GM percussion names,
and `ksp-dump --drum-map`.

**Why it was needed:** a drum note stores a *lane index* in `117`, not a pitch, so without a map M2
cannot emit a drum note and M6 cannot turn an incoming note 36 back into a lane.

**The map is device-global (`paramId 65`) and is not in the project file** — not recoverable from
one, not writable into one. The tool therefore treats it as *configuration with a documented
default* (chromatic from 36), never as a decoded fact, and always prints which map it used.

**Measured** (protocol D5): the device's own MIDI output runs 36…59 across the 24 lanes, so the
factory map is chromatic from 36 and lane *i* plays `low + i`. Chromatic mode takes a low note of
0–103; custom mode gives all 24 lanes a free note. There is no map in the project file to find,
which is what D6 asked. The documented default was right and stands — see spec §3.2.1.

### M2 — KeyStep Pro → MIDI export ✅ **done**

**Artifact:** `.KeyStepPro` → `.mid`, openable in any DAW. MCC has **no MIDI export at all for the
KeyStep Pro**, so `ksp2midi` is the only one that exists — which also means there is no reference
render to diff against, and the hardware's live output is the sole ground truth for timing.

**Delivered:** `ksp.midi_export` and the `ksp2midi` command (options in `README.md`), in three
layers that must stay separate — `render_pattern` → `arrange` → `build_midi_file`, the only `mido`
caller. Tests assert on `Rendering` data, not parsed MIDI. `tests/test_midi_export.py` checks
`project_5` and `project_9` against the hardware-confirmed descriptions rather than against our own
reader.

**Two options are deliberately unshipped**, both because the number they need has never been
measured and a wrong one produces a file that loads cleanly and plays wrong:

- **`--passes`** (expanding the 16/32/48/64 step-skip cycle) waits on **T5.8** — whether the four
  sequences are *repeats* or *pages*. Until then the export renders one pass, includes every note,
  and warns.
- **`--time-shift approx`** waits on **tier 8**. The centre of `112`/`120` is confirmed but the
  duration of one unit is not, so there is nothing to scale by that we would not be inventing.

**The layout decision.** The device stores no arrangement — 4 tracks × 16 independent loops — so a
linear MIDI file has to invent one. Patterns holding notes are laid end to end in pattern order, and
**pattern N starts at the same tick on every track**, preserving the one relationship the hardware
does give. `--split` avoids the question entirely.

### M3 — Byte-identical round-trip ✅ **done**

**Artifact:** load a project, re-emit it, assert the bytes match. Locks down write fidelity — tab
indentation, MCC's string-sorted key order, the `version` key — before any real mutation exists to
confuse the picture.

**Delivered:** `ksp.lenient_json.dumps` / `dump_path` / `canonical`, and `tests/test_round_trip.py`,
which holds **all five** samples rather than only the factory default. `dump_path` writes to a temp
file alongside the destination and renames it into place — these are 3.5 MB files whose destination
is often MCC's Templates folder, where a half-written one would be found and parsed.

Output is **strict JSON**: T6.2 showed MCC does not need the trailing comma, so the round-trip
target is MCC's bytes minus that one byte, with
`test_output_differs_from_mcc_by_exactly_the_trailing_comma` pinning the deviation at one byte. The
reader still accepts the comma, because every file that exists has one.

### M4 — Targeted mutation ✅ **done**

**Artifact:** write a note into a real project from software, load it in MCC, push to the device.

**Delivered:** `ksp.mutate` (`place_note`, `set_pitch`, `pitch_key`), `tests/test_mutate.py`, and
`tests/test_hardware_mutation.py` — the repository's first `@pytest.mark.hardware` tests. No console
entry point: candidates come from a marker-gated test for the person at the device.

The desk gate is what made a hardware session worth booking: `place_note` applied to
`baseline.KeyStepPro` reproduces the device's own `T1-note-place` capture **byte for byte**. That
file is committed for exactly this reason, so the recipe is CI-enforced rather than local to one
machine.

**Confirmed on the device** 2026-08-01: the readback differs from the candidate by **zero keys**,
and a pitch we changed landed on the note we meant. Melodic only — a drum note's lane is not a
comparable write, because the drum step-active array is indexed *by lane*. M6 owns that.

**Placing a melodic note is 8 keys, not one** — recipe in spec §4. `ksp.mutate.place_note` is the
only thing that should be building that set.

### M5 — MIDI → KeyStep Pro (MVP) ✅ **done**

**Artifact:** `midi2ksp in.mid -o out.KeyStepPro` — one track, one pattern, monophonic, default
gate. **This is the core deliverable.** Everything after it is breadth, not capability.

**Approach:** template-and-overwrite. Start from a project, overwrite values, write back. Never
synthesise the key set.

**Delivered:** `ksp.midi_import` and the `midi2ksp` command, plus MCC's factory default bundled into
the wheel so an installed command has something to convert into. Three layers mirroring M2's,
inverted — `read_clip` (the only `mido` caller) → `quantise` → `apply`.

**Placement is not reimplemented.** `apply` calls `ksp.mutate.place_note`, and `test_midi_import.py`
asserts that converting a one-note clip reproduces M4's hardware-measured 8-key diff exactly — so a
regression fails against what the device itself wrote, not against our own idea of what a note is.

**Confirmed on the device** 2026-08-01: the converted clip loaded, transferred and played as
written. That closes the loop the tool was built for. Confirmed by ear rather than by a readback, so
`test_the_device_kept_the_converted_pattern` still skips; worth capturing next time the device is
out, as a regression net rather than an open question.

**Scope discipline:** monophonic and single-pattern on purpose. Sub-issues #30 (drums) and #31
(unified drum + melodic) stay open for M6. Two limits are user-visible rather than hidden — note
lengths are not carried (scope, not an unknown: the gate ladder is measured), and a project's *name*
is an integer parameter we have not decoded, so a converted project inherits its template's name in
MCC's Project Browser.

### M6 — Full conversion

**Artifact:** multi-track (1–4), polyphony, drum track, tempo/swing/step count, and patterns longer
than 64 steps split across pattern slots. Real musical material instead of toy clips.

**Test:** convert a real multi-track MIDI file and verify on the device.

**Watch for:**

- Track 1 in DRUM mode uses a completely different parameter set (spec §3.2), and the mode flag —
  **`86` bit 6**, not `100` — must match whichever set you write.
- Both step-active arrays must be written consistently with the note list, because **the device
  plays the flags, not the pool**. A pooled note whose flag is clear is silent.
- Anything over 64 steps must be split and chained, never silently truncated.
- `idx2` is a **64-entry pool chunk, not a polyphony voice**, so chords sit in one chunk as
  consecutive ordinals sharing a step and there is no 3- or 4-note ceiling. The real limit is **192
  events per pattern**, which the firmware enforces with an on-screen error. The open question is
  what a writer should do when source material exceeds it — split across patterns, or drop and warn.
  Track 1's slot 4 stays zero-filled even when a 4th chord voice is added; never write there.

### M7 — Timing calibration

**Artifact:** the measured constants for the encodings that place a note in time — gate length, time
shift, swing — as data, plus the randomness reading the timing work rests on.

Gate is **done** (issue #9): the encoding is an index, `stored = detent − 1`, 128 rungs,
0.0625–64 steps, drum ladder identical. `ksp.constants.GATE_TABLE` holds it and
`tests/test_gate_ladder.py` ties it to `analysis/gate_ladder.txt`. It came out clean only once a
*consecutive* run of detents was captured rather than scattered samples — the lesson the rest of the
tier inherits.

The remainder resolves in one session, except tier 8, which needs a rig that can record MIDI:

- **Time shift range and linearity** (`112` / `120`) — **#42**, protocol T7.1–T7.3. The centre of 49
  is confirmed but nothing establishes the range; `project_5`'s ±4 may not be the limit. T7.1 is a
  **go/no-go that jumps the queue**: if the range really is ±4, most of this and of tier 8 is not
  worth running. T7.3 also settles the `project_5` drum conflict.
- **Swing semantics** (`74`, `97` / `114`) — **#43**, protocol T7.4–T7.7. **Never exercised in any
  sample file**, so it cannot be decoded at the desk at all. Also settles whether `reader._swing` is
  right to read the per-pattern value as absolute rather than a signed offset.
- **Randomness** (`113`) — **#44**, protocol T7.8. Probability, or timing jitter? A fresh note
  defaults to 100; if that means jitter, every timing measurement is measuring noise. **Gates tier 8
  entirely.**
- **What one time-shift unit is worth in time** — **#45**, protocol tier 8. Needs a recording of the
  device's MIDI output rather than an export, because the quantity is not in the file.

See [`analysis/Timing_Calibration.md`](./analysis/Timing_Calibration.md) for the model and the
arithmetic. **Do not guess any of it** — a wrong timing constant produces files that load fine and
play wrong, with nothing to signal the error.

### M8 — Distribution

**Artifact:** a signed, notarised thing another KeyStep Pro owner can actually run. Until this
exists the tool only works for people willing to set up a Python environment.

**Test:** hand it to someone else with a KeyStep Pro and have them convert a file without touching a
terminal or reading setup instructions.

### M9 — Native GUI

**Artifact:** drag-and-drop macOS app that writes straight into MCC's Templates directory.

**Why last:** it removes the terminal from the workflow but adds no capability. Revisit whether it
is worth building after M6 — see the caveat under **Stack**.

**Test:** drag a `.mid` onto the app, restart MCC, pattern is there.

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
| M6 Full convert | | No (desk-testable) | M5, M1.5 |
| M7 Timing calibration | | **Yes** | M3 |
| M8 Distribution | | For final check | M6 |
| M9 GUI | | For final check | M8 |

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
  track. Until something reads it, every lane renders at the pattern-level `115`.

**Hardware captures worth doing in one session:** M7's tiers 7–8, and T6.1 (the `project_5` drum
time-shift re-check). Ranked in
[`analysis/Hardware_Test_Protocol.md`](./analysis/Hardware_Test_Protocol.md).
