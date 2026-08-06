# Arturia KeyStep Pro `.KeyStepPro` Format Specification

**Status:** current and validated. The authoritative format reference — nothing else in the
repository supersedes it. An earlier analysis reached several wrong field mappings; [§8 Corrections](./format/Corrections_And_Prior_Art.md) records
what they were, so a future reader recognises them rather than re-deriving them.

**Device:** Arturia KeyStep Pro, firmware/format `2.5.20`
**Derived from:** MIDI Control Center 1.23.0.134 and the project files in `../project_files/`
**Validated against:** `project_5_description.txt` / `project_9_tests.txt` (settings confirmed
on the physical hardware)
**Executable check:** every claim in these files is asserted by the M1 reader's test suite, which
decodes all five sample projects. The index spaces and the timing encodings in particular are
enforced by `tests/test_reader.py`.

### Sample projects

| File | What it is |
|---|---|
| `Default.KeyStepPro` | MCC's factory template, exported from the application. No `version` key |
| `user_empty_project.KeyStepPro` | Initialised and exported by the user with no edits. The empty baseline |
| `project_5.KeyStepPro` | The main ground truth — one drum pattern and one melodic pattern, documented step by step |
| `project_9.KeyStepPro` | Three targeted single-note tests isolating gate and step skip |
| `initial_project.KeyStepPro` | Real user material across several tracks and patterns. Not documented, but it is where the format's awkward cases show up |

---

## 0. The short version

- A `.KeyStepPro` file is one **flat JSON object** of ~153,495 integer entries plus 1–2 string keys.
- It is **not strict JSON** — MCC writes a trailing comma, so a reader must tolerate one. A
  *writer* need not emit it: T6.2 showed MCC loads a file without it
  (see [the file dialect](./format/File_Dialect_And_Write_Fidelity.md)).
- Its structure is encoded entirely in the **key names**: `<itemId>_<paramId>[_i1][_i2][_i3]`.
- The complete parameter dictionary is **shipped by MCC on disk** — you do not need to guess it.
- Within a track/pattern/slot, **some parameters are indexed by step and others by note ordinal**.
  This is the single most important thing to get right.
- The key set is **fixed**. A converter overwrites values; it never adds or removes keys.

---

### Format Traps

- Flat JSON, ~153,495 integer entries; all structure lives in key names
  `<itemId>_<paramId>[_i1][_i2][_i3]`.
- **Not strict JSON** — trailing comma, tab indentation, no final newline. `json.loads` rejects
  what MCC writes, so the reader must tolerate the comma. The **writer omits it** so its output
  is strict JSON and one byte shorter than MCC's; every other byte must still match. Nothing else in the dialect is optional.
- Key set is **fixed**: template-and-overwrite from `Default.KeyStepPro`, never add or remove
  keys. The factory default lacks the `version` key user projects have — inject it.
- **Two index spaces** (see [the two index spaces](./format/Index_Spaces_And_Note_Placement.md)) — the top source of bugs. `48`/`49` are step-indexed; `50` and `109`–`113`
  are indexed by note ordinal, with `50` giving each note's 0-based step. The device stores an
  event list, not a step grid.
- **Existence ≠ audibility** (see [existence versus audibility](./format/Existence_Versus_Audibility.md))**.** A note exists when `50 != 127` (`54` for drums); it *sounds* only if
  its step-active bit is set (`48` melodic, `52` drum — packed lane-major). Never infer a note
  from its velocity, and never infer emptiness from `40` (it latches).
- **Placing a melodic note is 8 keys, not one**
  (see [note placement](./format/Index_Spaces_And_Note_Placement.md)): `50`, `109`–`113` by note ordinal, plus
  `48` **by step, in slot 1**, plus `40` = 3. `49` is not written — it already reads 15. Four notes
  on one step means four pool entries and *one* `48` bit. `ksp.mutate.place_note` is the only
  thing that should be building that set.
- Track 1 (item `123`) carries a second DRUM parameter set. The mode flag is **`86` bit 6**, not
  `100`. A writer must set `86` to match whichever set it writes.
- A drum note's `117` is a **lane index (0–23)**, not a pitch (see [the drum lane map](./format/Parameters_Drum_Lane_Map.md)). The lane→note map is a global
  device setting absent from the file; `ksp.drum_map` holds it as configuration and every consumer
  states which map it assumed.
- **Gate is measured** (see [the gate ladder](./format/Gate_Length_Ladder.md)): an index, `stored = detent − 1`, 128 rungs, 0.0625–64 steps,
  drum ladder identical. `tests/test_gate_ladder.py` holds `GATE_TABLE` against the transcription.
- **Time shift and swing are measured** (see [time shift and swing](./format/Time_Shift_And_Swing.md)): shift is a plain offset,
  `stored = 49 + displayed`, stored 0–99, drum identical; swing is an absolute 50–75 %, stored per
  pattern, delaying the even steps only. **One shift unit is 1/400 of a beat** — a fixed count, not
  a fraction of the step, so it does not change with the step size. The **per-pattern swing takes
  precedence over the global `74`**, which is therefore reported rather than applied.


Keep the unknowns user-visible: each is an `ExportOptions` field with a documented default, never
a buried constant, and anything the export decides for itself is reported as a warning.

---

## Where to look

The body of this specification lives in [`analysis/format/`](./format/). Each file names its
section in a `**Spec section:**` line, so `grep -l '§4' analysis/format/*.md` resolves a section
number without opening this page.

Section numbers are the stable address: roughly fifty references across `src/`, `tests/`,
`tools/`, `README.md`, `ROADMAP.md` and the two companion analysis documents cite this spec as
"§4" or "section 3.3". Nothing here is ever renumbered.

| § | File | What is in it |
|---|---|---|
| 1 | [`MCC_Resources_And_Device_Identity.md`](./format/MCC_Resources_And_Device_Identity.md) | Where the parameter dictionary lives on disk; device identity; MCC's constraints |
| 2 | [`File_Dialect_And_Write_Fidelity.md`](./format/File_Dialect_And_Write_Fidelity.md) | The JSON dialect, key grammar, byte-level write rules, item IDs |
| 3.1, 3.2 | [`Parameters_Note_Melodic_And_Drum.md`](./format/Parameters_Note_Melodic_And_Drum.md) | Per-note parameters of both sets — melodic `109`–`113`, drum `117`–`121` |
| 3.2.1 | [`Parameters_Drum_Lane_Map.md`](./format/Parameters_Drum_Lane_Map.md) | The 24 drum lanes, and why the lane→note map is not in the project file |
| 3.3 | [`Parameters_Pattern_Scalars.md`](./format/Parameters_Pattern_Scalars.md) | Per-pattern scalars: swing, step count, the `99`/`116` bitfield, root and scale, the `40` latch |
| 3.3.1, 3.4 | [`Parameters_Scenes_Tracks_And_Project.md`](./format/Parameters_Scenes_Tracks_And_Project.md) | Scenes and pattern chaining, per-track state, project globals, the tempo decode |
| 4 | [`Index_Spaces_And_Note_Placement.md`](./format/Index_Spaces_And_Note_Placement.md) | Step- vs note-indexed parameters, the `52` bit array, the 8-key placement recipe |
| 4 | [`Note_Pool_Sentinels_And_Capacity.md`](./format/Note_Pool_Sentinels_And_Capacity.md) | The `127` sentinel, `idx2` as a pool chunk, the zero-fill trap, the 192-event ceiling |
| 4 | [`Existence_Versus_Audibility.md`](./format/Existence_Versus_Audibility.md) | Pooled does not mean audible; the six reasons a note might not play |
| 5 | [`Worked_Example_Project_5.md`](./format/Worked_Example_Project_5.md) | `project_5` decoded against its hardware-confirmed description |
| 5 | [`Step_Skip_Mask_And_Passes.md`](./format/Step_Skip_Mask_And_Passes.md) | `49`/`53` as a 4-bit mask over four passes — repeats, not pages |
| 5 | [`Resolved_Mode_Flags_And_Bitmasks.md`](./format/Resolved_Mode_Flags_And_Bitmasks.md) | The `52` layout; drum mode is `86` bit 6, not `100`; ARP octave; `116`/`99` bit 2 Mono/Poly |
| 6 | [`Time_Shift_And_Swing.md`](./format/Time_Shift_And_Swing.md) | Time shift and swing as measured, and the one timing quantity still missing |
| 6.1 | [`Gate_Length_Ladder.md`](./format/Gate_Length_Ladder.md) | Gate as a 128-rung index ladder, `stored = detent − 1` |
| 7 | [`SysEx_Direct_Transfer_Path.md`](./format/SysEx_Direct_Transfer_Path.md) | The `arturia_v2` bulk stream — future path, not needed for file conversion |
| 8 | [`Corrections_And_Prior_Art.md`](./format/Corrections_And_Prior_Art.md) | What the earlier analysis got wrong, and the prior art |
| 9 | [`Reproducing_Findings_And_Index_Shapes.md`](./format/Reproducing_Findings_And_Index_Shapes.md) | A minimal parser; how `bulkOperation` gives the index shapes |

Companion documents: [`Timing_Calibration.md`](./Timing_Calibration.md) for the timing model,
[`Hardware_Test_Protocol.md`](./Hardware_Test_Protocol.md) for the captures that measure it.

**The trap list above is a digest.** It restates findings detailed in the linked files; where the
two disagree, the linked file wins.
