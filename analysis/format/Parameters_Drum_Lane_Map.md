# The drum lane map

**Spec section:** §3.2.1 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The 24 drum lanes, why the lane-to-note map is device state that no project file can carry, and what the factory map measures as on hardware.

---

### 3.2.1 The drum map — 24 lanes, and it is **not in the project file**

The device has exactly **24** drum lanes. This is *derived*, not assumed: `KeyStepPro.json`
defines 24 `Note N` fields in a `globalFields` group named "Drum Map". No array in any project
file has cardinality 24 — a full index scan of the corpus finds dimension sizes
`{3, 4, 5, 16, 64}` only. The lane is a **value** of `117`, never an index.

| globalParamId | Name | Range | Default | Shown when |
|---|---|---|---|---|
| `81` | Mode | `0` = Chromatic, `1` = Custom | `0` | always |
| `82` | Low note | 0–103 | `0` | Mode = Chromatic |
| `83`–`106` | Note 1 … Note 24 | 0–127 | **36…59** | Mode = Custom |

Related globals: `74` / `79` are the Drum input / output MIDI channels, both defaulting to `10`
(tracks 1–4 default to 0–3), and `128`–`135` are "Drum Gate 1".."Drum Gate 8" for CV.

**These carry `paramId 65` — `deviceGlobalParametersId` — so they are device state, not project
state.** No `bulkOperation` has `bulkItemId: 65`; no sample file contains a key beginning `65_`;
MCC keeps no copy on disk and reads them live over SysEx. The drum map therefore **cannot be
recovered from a `.KeyStepPro` file and cannot be written into one.** A converter's lane↔note
mapping is necessarily an assumption about the owner's device and must be labelled as one —
which is what `ksp.drum_map` does, defaulting to chromatic from 36 (the manual: "the default
mapping starts at MIDI note 36", and the Custom defaults 36…59 are exactly that run).

#### What the device's map actually is — measured

**Hardware, capture D5.** One hit per lane on 24 consecutive steps — lane *i* on step *i+1* — and
the pattern recorded while it played once. The device transmitted **36, 37, … 59** in lane order
on **channel 10**, which settles both halves of the question at once:

- **The factory map is chromatic from 36**, not from 0. MCC's `defaultValue` of `0` for Low note
  is its UI fallback with no device attached and does not describe the hardware.
- **Lane *i* plays `low + i`**, not `low + i + 1` — lane 0 fired 36 with the low note at 36. So
  the top lane at the maximum low note is 126: Arturia's range is one short of 127, rather than
  this being an off-by-one in the reading.

The recording cross-checks against the export, which makes it a whole-chain result rather than a
MIDI observation alone: the 24 *sounding* notes in `D5-drum-map.KeyStepPro` carry `117` = 0…23 on
steps 1…24, in the same order as the pitches heard. (The pattern also holds five superseded hits
on lanes 19–23; they are pooled with their step-active bits clear, so the `52` decode is what
separates them — see [the two index spaces](./Index_Spaces_And_Note_Placement.md).)

The operator's menu readout supplies the rest of the shape, and exists nowhere else:

| Mode | What it takes | Range | Default |
|---|---|---|---|
| Chromatic | one Low note; lane *i* = `low + i` | 0–103 | **36** |
| Custom | all 24 notes independently, overlaps permitted | 0–127 each | **36…59** |

**D6 — the map is not in the project file, and there is nothing there to find.** No byte-identity
capture was taken and none is needed: the setting lives in the device's own menus with no project
representation at all. The file evidence agrees — D5's export diffed against `B0-baseline` moves
only `40`, `52`, `54`, `86`, `115` and `117`–`121`, all note and pattern parameters, with nothing
that could hold 24 note assignments. This is the same conclusion the parameter dictionary gives
above, now with the device's own behaviour behind it.

**None of this makes a converter's map any less an assumption.** The map is device state, so an
export can never be certain which one the owner has — it can only say which one it used, and
`ksp.drum_map` still does.
