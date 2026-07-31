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
in `project_files/`. Only M4, M7 and final validation need the device present.

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
- **Track 1's fourth polyphony slot is zero-filled, not sentinel-filled**, in every pattern of
  every sample. Read naively, an *empty* project decodes as 2,048 phantom notes. The `!= 127`
  existence rule needs the zero-fill exception alongside it (spec §4).
- **Parameter `100` does not identify drum mode** — it reads 26 everywhere. Usually harmless,
  because the unused parameter set is sentinel-filled, but `initial_project` Track 1 pattern 1
  holds a real melody *and* real drums, so the reader reports both. M6 must isolate the real bit.
- **The drum step-active bitmask (`52`) is not fully decoded.** Its packing fits both
  hardware-confirmed projects but not real user material. Harmless for reading — the note list is
  authoritative — but it blocks writing, so M5/M6 depend on it.

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

- **24 lanes is now derived rather than assumed.** The spec asserted it as background knowledge
  with no citation; the highest lane in any sample is 19. Two independent derivations now agree:
  MCC's 24 `Note N` fields, and `51`'s lane-indexed 1–24 array (finding 6 of
  `analysis/Format_Corrections_Issue.md`).
- **The map is device-global (`paramId 65`) and is not in the project file** — not recoverable
  from one, not writable into one. So the tool treats it as *configuration with a documented
  default* (chromatic from 36), never as a decoded fact, and always prints which map it used.
- **The drum-mode flag is `86` bit 6, not `100`** (spec §5). Found incidentally, confirmed by
  MCC's own field name and by exact correlation across all five samples. This removes one of the
  two blockers listed at the bottom of this file, and cuts Tier 3 of the hardware protocol from
  four captures to one.

**Still needs hardware — test D5** in
[`analysis/Hardware_Test_Protocol.md`](./analysis/Hardware_Test_Protocol.md), where the full
procedure lives. Two things MCC's `defaultValue`s cannot settle: whether a factory device is
chromatic-from-36 or chromatic-from-0, and whether chromatic mode maps lane *i* to `low + i` or
`low + i + 1`. It is the one test in that document needing a **MIDI monitor** rather than an
export diff, because no export can contain the answer.

---

### M2 — KeyStep Pro → MIDI export
**Artifact:** `.KeyStepPro` → `.mid`, openable in any DAW.

**Why it stands alone:** this is genuinely useful software on its own. MCC has MIDI export for
some things but no path for getting sequencer patterns out as MIDI files. It also directly
serves the README's "and vice versa".

**Test:** convert `project_5`, open in a DAW, confirm the notes, timing and velocities match the
documented description. This is the first point where a mistake becomes *audible*, which catches
whole classes of error that diffing does not.

---

### M3 — Byte-identical round-trip
**Artifact:** load `Default.KeyStepPro`, re-emit unchanged, assert byte-identical output.

**Why it stands alone:** locks down write fidelity — tab indentation, the trailing comma, the
`version` key (spec §2) — before any real mutation exists to confuse the picture. If this fails,
nothing downstream can be trusted.

**Test:** `md5` comparison. Pure desk work, no hardware, no MIDI involved.

**Also settle here:** whether MCC accepts strict JSON without the trailing comma. Export one file
without it and try loading. If it works, drop the comma-preservation requirement permanently.

---

### M4 — Targeted mutation
**Artifact:** change one note in a real project, load it in MCC, push to the device.

**Why it stands alone:** first write that reaches hardware. Confirms our key addressing is
correct end to end rather than merely self-consistent.

**Test:** change a single pitch, confirm on the KeyStep Pro's own display. Deliberately minimal —
one changed value means an unambiguous diff.

**Needs hardware.**

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
  bitfield must match what you write. **M1 found that parameter `100` does not currently
  distinguish the modes** — isolating the real bit is part of this milestone.
- The drum step-active bitmask `52` must be written consistently with the note list, and **its
  packing is not yet decoded** (spec §5). Reading does not need it; writing does.
- Anything over 64 steps must be split and chained, never silently truncated.
- Poly slots cap at 3 (4 on Track 1) — decide and document what happens to a 5-note chord.
  Track 1's fourth slot is zero-filled in every known file and may not be usable at all; do not
  assume it works without testing on the device.

---

### M7 — Gate length table
**Artifact:** the measured display → stored lookup table, as data.

**Why it is separate:** gate is the one encoding still unresolved (spec §6). It is non-linear and
does not fit a clean formula. Until measured, M5/M6 write a default gate and warn.

**Test:** place one note, step its gate through every selectable value, export at each, diff.
Roughly 10–15 captures. Once captured it is pure lookup data and drops straight in.

**Needs hardware.** Do not guess this — a wrong table produces files that load fine and play
wrong, with nothing to signal the error.

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
| M1.5 Drum map | ✅ done | D5 confirms the default | M1 |
| M2 MIDI export | | No | M1, M1.5 |
| M3 Round-trip | | No | M1 |
| M4 Mutation | | **Yes** | M3 |
| M5 MVP convert | | No (desk-testable) | M3 |
| M6 Full convert | | No (desk-testable) | M5, M1.5 |
| M7 Gate table | | **Yes** | M3 |
| M8 Distribution | | For final check | M6 |
| M9 GUI | | For final check | M8 |

M1–M3 and M5–M6 can all be built and tested with nothing but the files already in this repo.

Both format questions M1 surfaced are now closed, from the desk:

- ~~**Drum step-active packing (`52`)**~~ — **resolved** in
  `analysis/Format_Corrections_Issue.md` (finding 3): a flat 240-entry array laid out lane-major,
  24 lanes × 10 parts × 7 bits. That document is a work order and its code and spec edits are
  still to be applied.
- ~~**Drum-mode bit (`100`)**~~ — **resolved at M1.5**: the flag is `86` bit 6. Spec §5.

Hardware work is scheduled in `analysis/Hardware_Test_Protocol.md`, not here. The captures most
relevant to drums are **D5** (the drum map — the one test needing a MIDI monitor), **D1** (does
an unflagged pooled drum note sound), T2.y (whether drum gate shares the melodic table) and T6.1
(the `project_5` drum time-shift conflict).
