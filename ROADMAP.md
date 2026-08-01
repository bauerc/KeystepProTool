# KeystepProTool — Build Roadmap

A staged plan for building the MIDI ↔ KeyStep Pro converter, from first useful artifact to a
distributable macOS app.

**Prerequisite reading:** [`analysis/KeyStepPro_Format_Spec.md`](./analysis/KeyStepPro_Format_Spec.md).
The format is already decoded and hardware-validated, so this is a build plan, not a research plan.

---

## Principles

**Every milestone ships something you can use.** No milestone is purely internal scaffolding.
Each one has a concrete artifact and a test that can be run without having completed any later
milestone.

**Prove reading before writing.** Misreading a file wastes your time; miswriting one can put bad
data on the hardware. Reading is also self-validating in a way writing is not — we have
hardware-confirmed ground truth to check against.

**Get something audible early.** Export to MIDI (M2) lands before import from MIDI (M5). It is
the easier direction, it is independently useful — MCC cannot do it — and it validates our
understanding of the format in a way you can *listen to* rather than merely diff.

**Desk work before hardware work.** Most milestones are fully testable against the files already
in `project_files/`. Only M4, M7 and final validation need the device present, and M4's session is
done.

---

## Stack

**M1–M7 in Python.** The format layer is where all the remaining risk lives, and it is
iterative, exploratory work — the kind where a REPL matters. `mido` handles MIDI file parsing
for free, which has no equivalent in the Swift standard toolchain (CoreMIDI is real-time I/O,
not file parsing).

**M8–M9 in Swift.** By that point the core is a proven set of rules, so porting is a mechanical
translation rather than a reverse-engineering exercise. Swift wins decisively on distribution:
a signed `.app` versus asking other KeyStep Pro owners to manage a Python environment.

**A caveat worth stating up front:** the workflow is inherently batch-shaped — convert a file,
drop it in MCC's Templates folder, restart MCC. That is not interactive, so the M5 CLI may
simply be sufficient and M9 may never be worth building. Decide after M6, not now.

---

## Milestones

### M1 — Reader and dump ✅ **done**
**Artifact:** `ksp-dump project_5.KeyStepPro` prints a readable tree: tracks → patterns → notes.

**Why it stands alone:** inspect any project file without opening MCC. Useful immediately for
understanding your own projects.

**Test:** output reproduces `analysis/project_5_description.txt` and
`analysis/project_9_tests.txt`. Expected values live in `tests/fixtures/` as JSON, transcribed
by hand from those documents rather than generated from the reader, so a future Swift port can
be checked against the identical files.

**Delivered:** `ksp.lenient_json` / `keys` / `constants` / `model` / `reader`, and the
`ksp-dump` command (`--all`, `--track`, `--pattern`, `--json`).

**What it turned up.** Four things the spec did not have, now folded into it:

- **Tempo is decoded** — parameters `70`–`72` are little-endian 7-bit chunks holding BPM × 100.
  Confirmed against the hardware readout via the two empty baselines.
- **Track 1's fourth slot is zero-filled, not sentinel-filled**, in every pattern of every
  sample. Read naively, an *empty* project decodes as 2,048 phantom notes. The `!= 127`
  existence rule needs the zero-fill exception alongside it (spec §4). Capture D2 later showed
  the slot is a phantom outright — a 4th chord voice does not go there.
- **Parameter `100` does not identify drum mode** — it reads 26 everywhere. Usually harmless,
  because the unused parameter set is sentinel-filled, but `initial_project` Track 1 pattern 1
  holds a real melody *and* real drums, so the reader reports both. Resolved since: the flag is
  `86` bit 6, confirmed at the device by capture `T3-track1-drum`.
- ~~**The drum step-active bitmask (`52`) is not fully decoded.**~~ **Resolved:** lane-major,
  7 bits per entry, 10 entries per lane, confirmed by captures D1 and D3. Spec §4.
- **The drum note array is a pool with holes, not a compacted list.** Deleting a note empties its
  entry and leaves the later ones in place, so `127` marks an empty *entry* rather than the end of
  the list. The reader stopped at the first sentinel and discarded 43 live notes in
  `initial_project`. **Fixed**; melodic keeps the stop, which is verified across all five files.

One discrepancy is recorded rather than resolved: `project_5_description.txt` gives Time Shift
−1 for both kick hits, and the file stores −1 and **+1**. The fixture asserts the conflict so it
stays visible until someone re-checks it on the device.

---

### M1.5 — Drum map ✅ **done**
**Artifact:** `ksp.drum_map.DrumMap` — the 24-lane ↔ MIDI note mapping, with GM percussion
names, and `ksp-dump --drum-map`.

**Why it was needed:** a drum note stores a *lane index* in `117`, not a pitch. Without a map,
M2 cannot emit a drum note and M6 cannot turn an incoming note 36 back into a lane. No milestone
owned this gap.

**What the investigation found.** The map did not need reverse-engineering — MCC's parameter
dictionary defines it outright (spec §3.2.1): Mode (`globalParamId 81`), Low note (`82`) and
Note 1…Note 24 (`83`–`106`, defaults 36…59). Three consequences:

- **24 lanes is now derived rather than assumed.** Previously the spec asserted it as background
  knowledge with no citation; the highest lane in any sample is 19.
- **The map is device-global (`paramId 65`) and is not in the project file** — not recoverable
  from one, not writable into one. So the tool treats it as *configuration with a documented
  default* (chromatic from 36), never as a decoded fact, and always prints which map it used.
- **The drum-mode flag is `86` bit 6, not `100`** (spec §5). Found incidentally, confirmed by
  MCC's own field name and by exact correlation across all five samples. This removes one of the
  two blockers listed at the bottom of this file.

**Still needs hardware — Test D1.** Two things MCC's `defaultValue`s cannot settle: whether a
factory device is chromatic-from-36 or chromatic-from-0, and whether chromatic mode maps lane
*i* to `low + i` or `low + i + 1`.

Method, following `analysis/project_9_tests.txt`: on an untouched pattern with Track 1 in DRUM
mode, first write down the device's current Drum Map readout, then place one hit on each of the
24 lanes — lane *i* at step *i+1*, 24-step pattern, everything else left at fresh-note defaults.
Export, then capture the MIDI output while it plays once. Step *n* fires exactly one note-on, so
the captured pitch *is* the note for lane *n−1*: all 24 mappings from one capture, and the
lane encoding cross-checks against `123_117_*` in the export.

One hit per step rather than 24 at once keeps each step's note unambiguous in the captured MIDI.
(The `52` packing this test was also meant to discriminate is now decoded from captures D1 and
D3 — see spec §4 — so this export only has to resolve the drum map.)

**Test D2**, five minutes and no capture: change the Drum Map, export again, expect a
byte-identical file. Turns "not project state" from an inference into an asserted fact.

---

### M2 — KeyStep Pro → MIDI export ✅ **done**
**Artifact:** `.KeyStepPro` → `.mid`, openable in any DAW.

**Why it stands alone:** this is genuinely useful software on its own. MCC has **no MIDI export at
all for the KeyStep Pro** — confirmed in the UI; the export people remember is the BeatStep Pro's
`.mbseq` path. It also directly serves the README's "and vice versa".

A consequence worth stating: `ksp2midi` is therefore the only MIDI writer for this device, so
there is no reference render to diff against and the hardware's live output is the only ground
truth for timing (M7, protocol tier 8).

**Test:** convert `project_5`, open in a DAW, confirm the notes, timing and velocities match the
documented description. This is the first point where a mistake becomes *audible*, which catches
whole classes of error that diffing does not.

**Delivered:** `ksp.midi_export` and the `ksp2midi` command (`--split`, `--track`, `--pattern`,
`--steps-per-beat`, `--ticks-per-beat`, `--drum-map`, `--drum-channel`, `--default-gate`,
`--include-stale`, `--no-swing`, `--dry-run`, `--force`, `--quiet`).
`tests/test_midi_export.py` asserts the exported notes of `project_5` and `project_9` against the
hardware-confirmed descriptions rather than against our own reader.

**M2.2 (issue #22)** finished the option set the M2 plan specified and split the module into three
layers — `render_pattern` (plain tick data) → `arrange` (timeline placement) → `build_midi_file`
(the only part that knows what `mido` is). The layering is for M8–M9: the Swift port translates
arithmetic instead of hunting for a MIDI library, and the tests assert against plain data rather
than parsed MIDI. It also added `--split` (one file per non-empty (track, pattern), no layout
invented at all), `--dry-run`, `--default-gate`, and a warning when tracks hold different total
lengths — the point past which the file and the hardware stop agreeing about what plays together.

**Two options from that plan were deliberately not shipped**, both for the same reason: the number
they need has never been measured, and a wrong one produces a file that loads cleanly and plays
wrong.

- **`--passes`** (expanding the 16/32/48/64 step-skip cycle) waits on **protocol T5.8**. The spec
  reads the four sequences as *pages* of a 64-step pattern, but `project_5`'s 16-step pattern
  carries notes masked to 48 and 64, which under that reading could never sound. Until the device
  says which it is, the export renders one pass, includes every note, and warns.
- **`--time-shift approx`** waits on **protocol tier 8**. There is no documented guess to opt into
  — the centre of `112`/`120` is confirmed but the duration of one unit is not, so there is
  nothing to scale by that we would not be inventing.

**Built on M1.5.** Drum lanes resolve through `ksp.drum_map.DrumMap`, sharing `ksp-dump`'s
`--drum-map` grammar and config file, and the map used is named on every export. `--drum-map
none` is refused here: `ksp-dump` can print an unresolved `lane 0`, but a MIDI file has to name a
note for every lane. The drum-mode flag matters too — where a pattern holds both note sets, only
the one parameter `86` bit 6 says the device plays is exported, because the other is stale and
would put notes in the file that no hardware produces (`--include-stale` overrides).

**The layout decision.** The device stores no arrangement — 4 tracks × 16 independent loops — so
a linear MIDI file has to invent one. Patterns holding notes are laid end to end in pattern
order, and **pattern N starts at the same tick on every track**, which preserves the one
relationship the hardware does give (pattern N plays against pattern N). Unused patterns take up
no time. Each KeyStep Pro track becomes a MIDI track; Track 1's drum set becomes a second one.

**What it turned up.**

- **Gate is a length in steps.** `project_5`'s note placed on beat 9 and tied through beat 12 —
  four steps — stores gate 4. That is what makes a gate convertible into a duration at all, and
  it is now recorded in `ksp.constants`. The ladder has since been measured in full, so only a
  value outside 0–127 falls back to the fresh-note default (0.5) with a warning; nothing is
  interpolated.
- **Long gates have to be truncated at the next note of the same pitch.** `project_5` beat 1 has
  gate 2 with the same pitch repeating on beat 2. The device retriggers; MIDI would be left
  holding an unmatched note-on. The export shortens and warns.
- **Two things the export needs are not in the project file**: step size (in the undecoded
  `99`/`116` bitfield) and the drum map (a device global, spec §3.4). Each is an explicit option
  with a documented default rather than a buried constant. Gate was a third until tier 2 measured
  the ladder.
- **Time shift is not applied.** Its centre is confirmed but the *duration* of one unit has never
  been measured, so the export keeps the flat grid and says so. Measuring it belongs with M7's
  tier 7–8 captures — same hardware session, and the same batched method that reduced the gate
  sweep to one capture.

---

### M3 — Byte-identical round-trip ✅ **done**
**Artifact:** load `Default.KeyStepPro`, re-emit unchanged, assert byte-identical output.

**Why it stands alone:** locks down write fidelity — tab indentation, key order, the `version` key
(spec §2) — before any real mutation exists to confuse the picture. If this fails, nothing
downstream can be trusted. (The trailing comma was a fourth until T6.2 showed MCC does not need
it; see below.)

**Test:** `md5` comparison. Pure desk work, no hardware, no MIDI involved.

**The target is known to be reachable.** Capture B0.2 exported an untouched project twice and the
two files are **byte-identical**, so MCC's writer is deterministic and there is no drift to chase.
Any difference this milestone sees is ours.

**Delivered:** `ksp.lenient_json.dumps` / `dump_path` / `canonical`, and
`tests/test_round_trip.py`, which holds **all five** samples to byte identity rather than only the
factory default. Writing lives in the same module as reading because the dialect is one thing.
`dump_path` writes bytes to a temp file alongside the destination and renames it into place —
these are 3.5 MB files whose destination is often MCC's Templates folder, where a half-written one
would be found and parsed. No console entry point: nothing user-facing writes a `.KeyStepPro`
file until M5.

**What it turned up.**

- **The rules were already sufficient.** Applying the documented write-fidelity rules to a parsed
  sample reproduces its bytes on the first attempt, for every sample. There was no reverse
  engineering left in this milestone — only pinning it down as tested code.
- **Key order was undocumented, and it is not the obvious one.** MCC writes `device`, then
  `version`, then every numeric key **sorted as a string**: `126_99_16` before `126_99_2`. Now
  spec §2, and `canonical` implements it. This matters precisely once, but it matters: injecting
  the `version` key M5 needs appends it to the *end* of a dict loaded from the factory template,
  producing a key order no file MCC wrote has ever had.
- **Only `device` and `version` are strings.** Project names are stored as integer parameters, so
  there is no string escaping to reproduce and no sample holds a non-ASCII byte. The writer
  rejects any other value type outright — a float would emit `1.0` and a bool `true`, neither of
  which the firmware has been shown.
- **One changed value is one changed line**, asserted against `project_5`. That is the desk half
  of M4, so what M4 has to prove on the device is narrowed to key *addressing* alone.

**Settled afterwards: protocol T6.2 (2026-08-01) — MCC does not need the trailing comma.** M3
shipped re-emitting it, which was the safe direction: it is what MCC writes, so a file carrying it
cannot be wrong. The test then showed the requirement can be dropped. A candidate differing from a
known-good export by exactly that one byte loaded in MCC and transferred to the device, so
`dumps` now emits strict JSON and there is no flag to choose otherwise.

The round-trip target moved with it: MCC's bytes **minus that one byte**, via the
`sample_bytes_strict` fixture, plus `test_output_differs_from_mcc_by_exactly_the_trailing_comma`
to hold the deviation at one byte. The milestone is not weakened — key order, tab indentation, the
absent final newline and all 153,497 lines are still asserted exactly. Nothing else in the write
rules has been shown optional, and the reader still accepts the comma because every file that
exists has one.

---

### M4 — Targeted mutation ✅ **done**
**Artifact:** write a note into a real project from software, load it in MCC, push to the device.

**Why it stands alone:** first write that reaches hardware. Confirms our key addressing is
correct end to end rather than merely self-consistent.

**The milestone as originally framed — "change a single pitch" — was not enough.** Changing one
value on a note that already exists activates nothing: the note was already audible, so the edit
proves addressing and says nothing about whether we can make the device play something we
created. The write M5 depends on is **placement**, and placement is not a one-key edit.

**Delivered:** `ksp.mutate` (`place_note`, `set_pitch`, `pitch_key`), `tests/test_mutate.py`, and
`tests/test_hardware_mutation.py` — the repository's first `@pytest.mark.hardware` tests. No
console entry point: the candidates come from a marker-gated test for the person at the device, so
`midi2ksp` stays unclaimed and nothing an installed user can invoke writes a `.KeyStepPro` file.

**The placement recipe, measured rather than inferred.** `B0-baseline` → `T1-note-place` is what
the device wrote when a human placed one note, and it is **8 keys**: six note-indexed parameters
(`50` step, `109` pitch, `110` gate, `111` velocity, `112` time shift, `113` randomness), the
step-active flag `48`, and the pattern data-state latch `40`. Fresh-note defaults are gate 7,
velocity 100, time shift 49 and randomness 100, agreed across four independent captures and now in
`ksp.constants`.

**Two traps the recipe has to avoid**, both visible in the captures:

- **`49` (step skip) is not written.** An empty project already holds 15 — "plays on all four
  sequences" — everywhere, which is why it never appears in the diff.
- **`48` is step-indexed and lives in slot 1**, while the pool is note-indexed. The D2 chord
  captures put four notes on step 1: four pool entries, **one** `48` bit. A writer that indexed
  `48` by ordinal would light steps 1–3 and produce a file that decodes plausibly and plays wrong.

**What it turned up before the device was touched.** The two replay tests are the milestone's real
gate: `place_note` applied to `baseline.KeyStepPro` reproduces `T1-note-place` **byte for byte**,
and `set_pitch` applied to that reproduces `T1-note-pitch`. Those are the device's own files, so
key addressing is validated at the desk and a hardware session is only booked once they pass.
`baseline.KeyStepPro` is committed for exactly this reason — it is byte-identical to the
`B0-baseline` capture, so the 8-key result is CI-enforced rather than local to one machine.

**Scope: melodic only.** A drum note's lane (`117`) is not a comparable write, because the drum
step-active array `52` is indexed *by lane* — moving a lane moves its bit too. M6 owns that.

**Confirmed on the device**, protocol tier M4, 2026-08-01.

- **M4.1 — the placement recipe is complete on *load*, not just on save.** A file built by
  `place_note` from the baseline loaded in MCC, transferred, and showed exactly what was written:
  one note lit and sounding, one placed and dark. Re-exporting it from the device returns the
  candidate with **zero keys changed** — a full file → MCC → device → MCC → file round trip with
  no drift whatsoever. That also settles T4.5 from the side that matters for writing: the silent
  note's `48` was cleared by *us*, in a file the firmware loaded, and the firmware honoured it.
- **M4.2 — key addressing is correct end to end.** `project_5` Track 3 loaded with its notes
  intact and step 5 read **C#3** on the device's own display, against C#2 in
  `project_5_description.txt`, with the neighbouring ordinals unmoved.

**What the readbacks turned up.** The pitch readback differs from the candidate by five keys and
**none of them are ours**: `39` latches 2 → 3 per item, alongside `40`, and `123_117_<pattern>`
— a per-pattern scalar on the drum item, distinct from the note-indexed `117` and previously
undocumented — is normalised from 247 to 60. So `247` is something MCC writes and the firmware
does not keep. M5 and M6 should expect those and not mistake them for their own output drifting.

---

### M5 — MIDI → KeyStep Pro (MVP)
**Artifact:** `midi2ksp in.mid -o out.KeyStepPro` — one track, one pattern, monophonic,
default gate.

**Why it stands alone:** **this is the core deliverable.** A 16-step MIDI clip becomes a playable
pattern on the device. Everything after this is breadth, not capability.

**Approach:** template-and-overwrite. Start from `Default.KeyStepPro`, overwrite values, write
back. Never synthesise the key set (spec §2).

**Test:** convert a simple clip, drop it in
`/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/`, restart MCC, confirm it appears in
the Project Browser and loads. Round-trip through M2 as a desk check first.

**Scope discipline:** monophonic and single-pattern on purpose. Resist widening this — M6 exists
for that.

---

### M6 — Full conversion
**Artifact:** multi-track (1–4), polyphony slots, drum track, tempo/swing/step count, and
patterns longer than 64 steps split across pattern slots.

**Why it stands alone:** handles real musical material instead of toy clips.

**Test:** convert a real multi-track MIDI file and verify on the device.

**Watch for:**
- Track 1 in DRUM mode uses a completely different parameter set (spec §3.2), and the mode
  bitfield must match what you write. The flag is **`86` bit 6**, hardware-confirmed by capture
  `T3-track1-drum` as a one-key diff; `100` never moves.
- Both step-active arrays must be written consistently with the note list, because **the device
  plays the flags, not the pool** (capture D1). A pooled note whose flag is clear is silent. The
  drum bitmask `52` is now decoded — 7 bits per entry, lane-major, 10 entries per lane (spec §4).
- Anything over 64 steps must be split and chained, never silently truncated.
- `idx2` is a **64-entry pool chunk, not a polyphony voice** (captures D2, D3). Chords sit in one
  chunk as consecutive ordinals sharing a step, so there is no 3- or 4-note ceiling. The real
  limit is **192 events per pattern**, which the firmware enforces with an on-screen error. The
  open question is what a writer should do when source material exceeds it — split across
  patterns, or drop and warn. Track 1's slot 4 stays zero-filled even when a 4th chord voice is
  added; never write there.

---

### M7 — Timing calibration
**Artifact:** the measured constants for the encodings that place a note in time — gate length,
time shift, swing — as data, plus the randomness reading the timing work rests on.

**Why it is separate:** these are the encodings still unresolved (spec §6). Until measured, M2
exports on the grid and warns. Gate is done and turned out to fit a very clean rule — an index —
but only once a *consecutive* run of detents was captured rather than scattered samples; that is
the lesson the rest of the tier inherits.

**Scope.** Gate is closed. The remainder resolves in one session because the device is already
out, except tier 8, which needs a different rig:

- **Gate table** (`110` / `118`) — ✅ **done** (issue #9). Protocol tier 2, captures
  `T2-gate-table` and `D25-gate-capture`. The encoding is an index: `stored = detent − 1`, 128
  entries, gate 0.0625–64 steps, drum identical. `ksp.constants.GATE_TABLE` holds all 128 and
  `tests/test_gate_ladder.py` ties it to `analysis/gate_ladder.txt`. No transcribed rung rests on
  interpolation. Spec §6.1 has the full record.
- **Time shift range and linearity** (`112` / `120`) — **issue #42.** The centre of 49 is confirmed
  but nothing establishes the range; `project_5`'s ±4 may not be the limit. Protocol T7.1–T7.3.
  T7.1 is a **go/no-go that jumps the queue** — if the range really is ±4, most of this and of
  tier 8 is not worth running. T7.3 also settles the `project_5` drum conflict (issue #15).
- **Swing semantics** (`74`, `97` / `114`) — **issue #43.** **Never exercised in any sample file**,
  so it cannot be decoded at the desk at all. Protocol T7.4–T7.7, which also settles whether
  `reader._swing` is right to read the per-pattern value as absolute rather than a signed offset.
- **Randomness** (`113`) — **issue #44.** Probability, or timing jitter? A fresh note defaults to
  100; if that means jitter, every timing measurement in the protocol is measuring noise. Two
  captures (T7.8), and they **gate tier 8 entirely**.
- **What one time-shift unit is worth in time** — **issue #45.** Needs a recording of the device's
  MIDI output rather than an export, because the quantity is not in the file. Protocol tier 8, run
  after #42 supplies the range to sweep and #44 says whether the readings mean anything.

See `analysis/Timing_Calibration.md` for the model and the arithmetic.

**Needs hardware**, and tier 8 additionally needs a DAW or interface to record MIDI. Do not guess
any of it — a wrong timing constant produces files that load fine and play wrong, with nothing to
signal the error.

---

### M8 — Distribution
**Artifact:** a signed, notarised thing another KeyStep Pro owner can actually run.

**Why it matters:** this is where the intended audience is served. Until this exists the tool
only works for people willing to set up a Python environment.

**Test:** hand it to someone else with a KeyStep Pro and have them convert a file without
touching a terminal or reading setup instructions.

---

### M9 — Native GUI
**Artifact:** drag-and-drop macOS app that writes straight into MCC's Templates directory.

**Why last:** it removes the terminal from the workflow, but adds no capability. Revisit whether
it is worth building after M6 — see the caveat under **Stack**.

**Test:** drag a `.mid` onto the app, restart MCC, pattern is there.

---

## Dependency summary

| Milestone | Status | Needs hardware? | Depends on |
|---|---|---|---|
| M1 Reader | ✅ done | No | — |
| M1.5 Drum map | ✅ done | Test D1 confirms the default | M1 |
| M2 MIDI export | ✅ done | No | M1, M1.5 |
| M3 Round-trip | ✅ done | No | M1 |
| M4 Mutation | ✅ done | **Yes** (done) | M3 |
| M5 MVP convert | | No (desk-testable) | M3, drum `52` packing |
| M6 Full convert | | No (desk-testable) | M5, M1.5 |
| M7 Timing calibration | | **Yes** | M3 |
| M8 Distribution | | For final check | M6 |
| M9 GUI | | For final check | M8 |

M1–M3 and M5–M6 can all be built and tested with nothing but the files already in this repo.

Both format questions M1 surfaced are now closed:

- ~~**Drum step-active packing (`52`)**~~ — **resolved**: lane-major, 7 bits per entry, confirmed
  by D1/D3. Spec §4.
- ~~**Drum-mode bit (`100`)**~~ — **resolved at M1.5**: the flag is `86` bit 6. Spec §5.

Still open in the code rather than in the format: `Format_Corrections_Issue.md` finding 2
(`SLOTS_BY_ITEM[123]` should be 3, and `slot_is_initialised` should go with it), and
`P_DRUM_POLY_STEP_COUNT` (`51`), which is per-lane drum length — confirmed real by capture D4 but
read by nothing, so every lane renders at the pattern-level `115`.

Hardware captures worth doing in one session: M7's tiers 7–8, M1.5's Test D1 (drum map, and the
`52` packing case for free) and D2, plus the `project_5` drum time-shift re-check.
