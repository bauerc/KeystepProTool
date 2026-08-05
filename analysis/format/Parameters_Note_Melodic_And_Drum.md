# Note parameters — melodic and drum

**Spec section:** §3.1–§3.2 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The per-note parameters of both parameter sets: the melodic sequencer (`48`–`50`, `109`–`113`) and Track 1's drum set (`51`–`54`, `117`–`121`).

---

## 3. Parameter dictionary

`KeyStepPro.json` → `fields[]`. Each entry has an internal `id` **and** a `paramId` — the file
keys use **`paramId`**. Confusing the two is an easy mistake.

### 3.1 Sequencer (melodic) — items 123–126

| paramId | Arturia's name | Indexed by | Range / encoding |
|---|---|---|---|
| `48` | Step Seq step active | **step** 1–64 | 0 / 1 |
| `49` | Step Seq step skip | **step** 1–64 | 4-bit mask, see [the step-skip mask](./Step_Skip_Mask_And_Passes.md) |
| `50` | Seq note corresponding step | **note** 1–64 | 0-based step, `127` = empty |
| `109` | Seq note pitch | **note** | MIDI note 0–127 |
| `110` | Seq note gate length | **note** | non-linear, see [the gate ladder](./Gate_Length_Ladder.md) |
| `111` | Seq note velocity | **note** | 0–127 **directly** |
| `112` | Seq note time shift | **note** | offset, **centre = 49** |
| `113` | Seq note randomness | **note** | 0–100 |

**`109` is a raw MIDI note number, and the device's own note names are C3 = 60.** Capture
`D2-chord4-tr3` stores 48, 52, 55, 59 for a chord the operator played and named **C2, E2, G2,
B2**; `D25-gate-capture`'s single note stores 48 and is likewise C2. So the device labels an
octave one lower than the C4 = 60 convention, and a display transcription reading "C2" means
MIDI 48, not 36. This affects **transcriptions only** — no conversion is applied to `109` itself,
and the drum set's `117` is a lane index rather than a pitch (§3.2).

### 3.2 Drum — item 123 (Track 1) only

| paramId | Arturia's name | Indexed by |
|---|---|---|
| `51` | DRUM poly step count — **per lane**, 0-based (see below) | **lane** |
| `52` | DRUM step active | **packed bitmask**, lane-major, 7 steps per index (see [the two index spaces](./Index_Spaces_And_Note_Placement.md)) |
| `53` | DRUM step skip | **note** |
| `54` | DRUM step corresponding step | **note** (`127` = empty) |
| `117` | DRUM note pitch (drum lane) | **note** |
| `118` | DRUM note gate length | **note** |
| `119` | DRUM note velocity | **note** |
| `120` | DRUM note time shift | **note** |
| `121` | DRUM note randomness | **note** |

Track 1 plays the drum set *or* the sequencer set depending on its mode. That mode is documented
as living in the `100` bitfield, which does not work — the flag is **`86` bit 6**, per [resolved mode flags](./Resolved_Mode_Flags_And_Bitmasks.md).

Usually the unused set is fully sentinel-filled, which makes the live one obvious. That is not
guaranteed: `initial_project` Track 1 pattern 1 has real content in **both**. A converter must
set the mode to match what it writes, and a reader should not assume only one set is populated.

`117` holds the **drum lane**, 0-based — lane 0 is the kick, confirmed by `project_5`; lanes up
to 19 appear in `initial_project`. Its value in an *empty* list is `60`, not `127`, and drum
velocity `119` defaults to `100` rather than `127`. Neither is a note: existence is decided by
`54` alone, which is sentinel-filled as usual.

**`51` is a step count per drum lane**, 0-based like the melodic `98`, with one entry for each
of the 24 lanes. Every sample file holds a uniform 15 across all lanes, which left it ambiguous;
capture `D4-lane-steplength` sets one lane to a different length and only that lane's entry
moves (`123_51_1_1_1` → 11, entries 2–24 unchanged at 15). So drum lanes really can run at
different lengths, and a writer must set all 24.

**0-based is measured, not inferred.** The operator's display read **12** for the shortened lane
and **16** for the others, against stored 11 and 15. Stored = displayed − 1, on the same footing
as `98`.

**Independent lane lengths require drum *Poly* mode**, which the same capture also switched on:
`D4-lane-steplength` moves **two** pattern scalars, `123_51_1_1_1` 15 → 11 **and `123_116_1`
16 → 20** — bit 2. In *Mono* mode all 24 lanes share one length. On the device the mode is
SHIFT + E2 (Poly) / SHIFT + D#2 (Mono); it is not on the display.

> **A writer must set `116` bit 2 whenever it writes a non-uniform `51`.** Per-lane lengths
> without the bit produce a file that loads clean and plays wrong — the same silent-failure mode
> as a guessed time shift encoding. See [resolved mode flags](./Resolved_Mode_Flags_And_Bitmasks.md) for what bit 2 is and is not pinned to.
