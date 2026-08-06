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

**The one description-vs-file discrepancy is closed.** The device was re-read on 2026-08-05
(protocol T6.1): `project_5`'s two kicks display Time Shift −1 and **+1**, so the description
carried a transcription slip and now reads what the file stores — see spec §5.

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

**`--passes` shipped once T5.8 measured what it needed**: the four 16/32/48/64 sequences are
*repeats* of the pattern, not pages of a long one, so a masked note sounds on the loops its mask
names. The export expands the cycle by default and `--passes 1` flattens it. Step size and triplet
came out of the same tier, so `--steps-per-beat` is gone from `ksp2midi` — the file says.

**Time shift now ships applied.** Tier 8 measured the unit — a fixed 1/400 of a beat — so the
export displaces each note by its own `112`/`120` value instead of flattening it and warning.
`--no-time-shift` returns the flat grid. The long-deferred `--time-shift approx` never shipped and
never will: there is nothing to approximate now that the real number exists.

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
- Anything over 64 steps must be split and chained, never silently truncated. The chain format is
  measured (spec §3.3.1): `121_84_<scene>_<track>_<slot>`, 0-based pattern numbers in order, the
  rest left at the sentinel. The reader decodes chains; nothing writes one yet.
- Each pattern's step size, triplet and direction live in `99` / `116` (spec §3.3), so a writer
  that changes the grid must move bits 3–4 with it — `ksp.mutate.set_step_size` is the only thing
  that should. A pattern imported at one grid and left declaring another plays at the wrong speed
  with nothing to signal it.
- `idx2` is a **64-entry pool chunk, not a polyphony voice**, so chords sit in one chunk as
  consecutive ordinals sharing a step and there is no 3- or 4-note ceiling. The real limit is **192
  events per pattern**, which the firmware enforces with an on-screen error. The open question is
  what a writer should do when source material exceeds it — split across patterns, or drop and warn.
  Track 1's slot 4 stays zero-filled even when a 4th chord voice is added; never write there.

**Sub-issue — fit timing on import.** `ksp2midi` applies swing and time shift; `midi2ksp` still
quantizes hard to the grid and reports what it moved. Now that the shift unit is measured the
inverse is buildable, and [`analysis/Timing_Calibration.md`](./analysis/Timing_Calibration.md) §3.2
specifies it: snap to the nearest step, estimate the pattern's swing once from the aggregate
residual (median over odd steps minus median over even), then give each note's leftover to
`112`/`120` as `clamp(round(residual / unit), -49, +50)`, and **report every residual that could
not be represented**. Fit swing before shift — one pattern-level value expresses a systematic
groove for free, and spending per-note shift budget on it wastes a scarce field.

Two things this must respect. The shift range is a **fixed 60 ticks at 480 PPQN either way, not
half a step**, so at a 1/4 grid it covers only an eighth of a step and most residuals will not fit;
at 1/32 it covers a whole one. And swing only moves even-numbered steps, so an odd step's residual
belongs entirely to shift.

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

**Not part of the M1–M9 ladder.** It is an additional input path, not a step toward the existing
milestones: it makes the hardware a second producer of the same flat dict `ksp.reader.read_project`
already consumes, so nothing downstream changes. M1–M9 stand whether or not this ever lands.

Today `ksp2midi` can only read a project MCC has already exported. This reads one off the device
directly. The protocol is decoded in
[§7 of the format spec](./analysis/format/SysEx_Direct_Transfer_Path.md); the design lives in
`docs/superpowers/specs/2026-08-05-usb-sysex-project-read-design.md`, whose Phase numbering this
section keeps.

### Phase 0 — the hardware-free half ✅ **done**

**Artifact:** `ksp.sysex` (frame codec), `ksp.bulk_plan` (the generated read plan) and
`ksp.bulk_read` (walks the plan against an injected transport and assembles the dict). No `pyusb`
anywhere in `ksp/`, so the M8–M9 Swift port swaps in CoreMIDI and reuses all three unchanged.

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

**All five probes ran on 2026-08-06 and all five confirm** — ledger and raw output in
[the hardware protocol](./analysis/Hardware_Test_Protocol.md). The identity reply came back
byte-identical to the capture's, `120_37` read `3`, and the `0xFF` sentinel arrived raw on patterns
1–13, so the `247` in every project file is confirmed as MCC's corruption of it. On macOS the
probes need `sudo`: the system binds its own USB-MIDI driver to interface 2 and will not release
it to an unprivileged process.

Two probes changed what later phases should do:

- **H1.4 — there is no handshake.** A read succeeds with neither the identity request nor the
  `0x05` frame, so `bulk_read` sends no prologue. The identity request is still needed for the
  version string, but not to open the conversation.
- **H1.3 — `count=64` is honoured and free.** The per-request period does not move with payload
  size (3.994 ms at 16, 3.998 ms at 64), so a full dump drops from 38.3 s to 9.6 s. **Not taken
  yet:** it rewrites the request stream `test_bulk_plan.py` pins to MCC's, and counts that overrun
  a parameter's extent are untested. It belongs to Phase 3, behind H3.2's byte-diff.

`ksp_cli/pull.py` is **not** part of this phase. The full-dump CLI is what Phase 3's H3.1 gates,
and writing it before there is a live read to point it at leaves it unexercised.

- **Phases 2–4** — live read against the device, then the questions only hardware settles.

No console entry point is declared until the milestone lands, per CLAUDE.md.

### Open items

- **Project selection is decoded but unconfirmed.** Byte 7 of every frame is the project slot
  ([spec 7.4](./analysis/format/SysEx_Direct_Transfer_Path.md)) — four captures track it against
  the project, and nothing else in an import stream names the destination. But `ksp.sysex` still
  sends the constant `1`, every probe so far sent `1`, and **no test has shown the device honours
  it**. So `read_raw` returns whichever project is loaded until H4.1 says otherwise, its docstring
  must keep saying so, and threading a slot parameter through `sysex`/`bulk_plan`/`bulk_read` is
  work that should follow the probe rather than precede it.
- **The write direction is decoded but unimplemented.** A write is the read protocol with the
  reply opcodes sent as requests, over the same 8,951 addresses in the same order — so
  `ksp.bulk_plan` is already the write plan ([spec 7.5](./analysis/format/SysEx_Direct_Transfer_Path.md)).
  Phase 0 remains read-only and nothing in `ksp/` encodes a write. Two things block one: `06 <slot>`
  looks like a commit and is untested, and a value read as `0xFF` **cannot be sent back** — MCC's
  attempt stalled the device (spec 7.6).
- **`0xFF` is the device's unset sentinel**, and `247` is MCC's corruption of it in transit. A
  *file* writer must keep emitting `247`; a *device* writer must not. See
  [per-pattern scalars](./analysis/format/Parameters_Pattern_Scalars.md).

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
  track. Until something reads it, every lane renders at the pattern-level `115`. The flag that
  governs it is now decoded on both halves (`99` / `116` bit 2, spec §3.3), so what is missing is
  the rendering, not the reading.
- **Playback direction is decoded and not applied.** Rand and Walk have no MIDI equivalent, so
  `ksp2midi` renders those patterns forward and warns. Rendering a plausible random order would be
  inventing a performance the device did not give us.

**Hardware captures still worth doing: none.** Every tier of
[`analysis/Hardware_Test_Protocol.md`](./analysis/Hardware_Test_Protocol.md) is closed and its
procedures removed; what is left there is the method, for whatever question comes next.
