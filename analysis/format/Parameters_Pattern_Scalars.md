# Per-pattern scalars

**Spec section:** §3.3 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The scalars indexed by pattern 1–16: swing, step count, the `99` / `116` bitfield, root note and scale, and the `40` latch.

---

### 3.3 Per-pattern scalars (index = pattern 1–16)

| paramId | Meaning |
|---|---|
| `97` / `114` | Seq / DRUM swing % — stored with a **+25 offset** (±25% → 0…50) |
| `98` / `115` | Seq / DRUM step count — **0-based** (15 = 16 steps) |
| `99` / `116` | Bitfield: step size, triplet, polyrhythm, playback direction. **Measured in full** — one layout for both halves, see below |
| `100` | Bitfield. Dictionary says ARP/Drum mode, ARP type, ARP octave; only **ARP octave (bits 4–6)** is hardware-confirmed, as `stored = octave + 1` (see [resolved mode flags](./Resolved_Mode_Flags_And_Bitmasks.md)). Drum mode is `86` bit 6, not here |
| `107` / `108` | Root note (pitch class 0–11) / scale (index into the device's list). **Measured** — see below. `108` has no drum twin: one value serves both parameter sets |
| `40` | Pattern data state: `0` in the factory template, `2` initialised but empty, `3` holds data. **A latch** — see below |
| `123_117_<pat>` | **Item 123 only, and distinct from the note-indexed `117`** — same paramId, one index instead of three. Meaning unknown; `60` in every file except `initial_project`, `project_5` and `project_9`, which hold `247` at pattern 1 only. **A device round trip normalises it to 60** (protocol M4.2), so `247` is something MCC writes and the firmware does not keep. It is the only non-latch key that moved in an M4 readback |
| `20`–`23`, `25`–`28` | Program Change (Seq / Drum), MSB/LSB split |
| `101`–`106` | User scales 1 and 2, each split MSB / MidSB / LSB |

**`40` never goes back down.** Capture `T1-note-delete` removes a pattern's only note: every note
parameter returns to sentinel, but `124_40_1` stays at `3`. A pattern that has ever held a note
reads "holds data" forever, so emptiness must never be inferred from `40` — count the pool
instead. (The per-track equivalent `39` behaves the same way: it reads `3` on all five tracks of
a freshly initialised project.)

Params `109`–`113` and `117`–`121` also appear in a **one-index form** (`<item>_<param>_<pattern>`)
holding the pattern's **default** value for that field — hence array sizes of 4,112 (`16×4×64 + 16`)
rather than 4,096.

#### The `99` / `116` bitfield — measured

**Measured 2026-08-04, protocol tier 5**, against `B0-baseline`. The sequencer field and the drum
field are **one layout**; only their defaults differ.

| Bits | Value | Field | Values |
|---|---|---|---|
| 0 | 1 | Triplet | |
| 1 | 2 | — | set by nothing, in any file or capture |
| 2 | 4 | Polyrhythm (set) / Monorhythm (clear) | |
| 3–4 | 8, 16 | Step size | 0 = 1/4, 1 = 1/8, **2 = 1/16**, 3 = 1/32 |
| 5–6 | 32, 64 | Playback direction | 0 = Fwd, 1 = Rand, 2 = Walk |

The evidence, capture by capture:

- **Step size** — `T5-99-stepsize` sets patterns 1–4 to 1/4, 1/8, 1/16, 1/32 and stores
  **4 / 12 / 20 / 28**.
- **Triplet** — `T5-99-triplet` moves `124_99_1` 20 → **21**, and sweeps Track 3 to
  **5 / 13 / 21 / 29**, i.e. the triplet bit against each step size in turn.
- **Polyrhythm** — `T5-99-monorhythm` moves `124_99_1` 20 → **16**. This is the same bit `D4` moved
  on the drum side, and it is the **whole of the 20-vs-16 asymmetry**: sequencer patterns ship with
  polyrhythm on and drum patterns ship with it off. Nothing about the layout differs.
- **Direction** — `T5-99-direction` sets patterns 1–3 to Fwd, Rand, Walk and stores
  **20 / 52 / 84**, confirming the dictionary's "bits 5–6". The fourth value the two bits allow was
  never produced; it has no known name, and a reader should say so rather than pick one.
- **The drum half** — `T5-99-drum` sets 11 drum patterns to 0, 1, 8, 9, 16, 17, 24, 25, 48 and 80,
  which decode through the same four fields.

**Swing is not in this field.** MCC's dictionary names a *swing offset state* among its contents,
but `T5-99-swingoffset` leaves `99` untouched and moves `124_97_1` 25 → 50 instead. The per-pattern
swing parameter is the only thing that toggle writes.

#### Root note and scale — measured

**Also tier 5.** `107` is a **pitch class 0–11**: `T5-rootnote` selects root D and stores **2**; the
octave the display shows is not in the file at all. `108` indexes the device's scale list **in
display order**:

| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|
| Chromatic | Major | Minor | Dorian | Mixolydian | H.Min | Blues | Root | User 1 | User 2 |

`T5-scale` walks patterns 1–10 down that list on both item 123 and item 124 and stores 0–9 — with
**one exception that is the finding**: selecting **Root** (index 7) stores nothing. Pattern 8 stayed
at its previous value on both tracks, so a file never holds 7. `ksp.constants.SCALE_NAMES` carries
the list and `UNSTORABLE_SCALE` carries that caveat.
