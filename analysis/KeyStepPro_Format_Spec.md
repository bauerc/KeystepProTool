# Arturia KeyStep Pro `.KeyStepPro` Format Specification

**Status:** current and validated.
Supersedes [`KeyStepPro_File_Format_Analysis_deprecated.md`](./KeyStepPro_File_Format_Analysis_deprecated.md).

**Device:** Arturia KeyStep Pro, firmware/format `2.5.20`
**Derived from:** MIDI Control Center 1.23.0.134 and the project files in `../project_files/`
**Validated against:** `project_5_description.txt` / `project_9_tests.txt` (settings confirmed
on the physical hardware)
**Executable check:** every claim below is asserted by the M1 reader's test suite, which decodes
all five sample projects. Sections 4 and 6 in particular are enforced by
`tests/test_reader.py`.

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
  *writer* need not emit it: T6.2 showed MCC loads a file without it (§2).
- Its structure is encoded entirely in the **key names**: `<itemId>_<paramId>[_i1][_i2][_i3]`.
- The complete parameter dictionary is **shipped by MCC on disk** — you do not need to guess it.
- Within a track/pattern/slot, **some parameters are indexed by step and others by note ordinal**.
  This is the single most important thing to get right.
- The key set is **fixed**. A converter overwrites values; it never adds or removes keys.

---

## 1. Where the authoritative data lives

MCC keeps device data **outside** its app bundle, in a shared, world-readable directory:

| Path | What it is |
|---|---|
| `/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json` | **The parameter dictionary** — 217 KB, 205 field definitions, 25 item types, 18 bulk-transfer descriptors |
| `/Library/Arturia/MIDI Control Center/Resources/KeyStepProTest.json` | Factory-test variant of the same schema |
| `/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.ui` | Panel hit-boxes for the Device Test view. Plain JSON despite the extension. **No format-relevant data** |
| `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/Factory/Default.KeyStepPro` | **Canonical blank project** — the ideal converter baseline |
| `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/` | MCC's project library. Files here appear in the Project Browser |
| `/Library/Arturia/MIDI Control Center/Firmware/keystep-pro_Firmware_Update_2.5.20.0.kspf` | Firmware. A ZIP containing `info.json` + a DFU `.bin` |

Device identity, from `KeyStepPro.json`:

```
usbVendorId          7285 (0x1C75)      usbProductId    536 / 8728
manufacturerId       00 20 6B           familyId        0200
productId            42                 familyMemberId  0900
protocol             arturia_v2         templateExtension  .KeyStepPro
memories             16                 minimalVersionRequired  2.5.14
deviceGlobalParametersId  65
```

### MCC implementation constraints worth knowing

- MCC is a **JUCE** application (not Qt): a single 24 MB Intel-only Mach-O, no bundled frameworks.
  It parses this JSON with **Boost.PropertyTree**, which is exactly why trailing commas are accepted.
- `Info.plist` declares **no `CFBundleDocumentTypes` and no UTIs**. `.KeyStepPro` is not a
  registered document type and MCC never opens files via LaunchServices. Projects are found
  purely by **scanning the Templates directory**, which is world-writable — so a tool can drop
  files there with no elevation and no Finder integration. MCC scans at launch, so expect to
  restart it before a new file appears.
- **MCC has no MIDI export for the KeyStep Pro, and no import either** — confirmed in the UI.
  `KeyStepPro.json` declares only `actions: ["store", "recall"]`, and the binary's sole
  MIDI-file-writing code sits in the **BeatStep Pro** `.mbseq` save path, which is where the
  often-repeated "MCC can export MIDI" claim comes from. Getting patterns out as `.mid` is the gap
  this project fills, and it means there is no reference render to check our own output against.
- There is no CLI, AppleScript dictionary, or headless mode. Automation must be file-level.

---

## 2. File format

A single flat JSON object. No nesting anywhere.

```json
{
	"device": "KeyStepPro",
	"version": "2.5.20",
	"120_101": 127,
	"123_109_10_1_1": 64,
	"125_49_1_1_5": 5,
	...
	"126_99_9": 20,
}
```

### Key grammar

```
<itemId>_<paramId>[_<idx1>][_<idx2>][_<idx3>]
```

`itemId` selects a functional section, `paramId` selects a parameter within it, and one to three
indices address pattern / pool chunk / step-or-note. "Pool chunk" is `idx2`; it is *not* a
polyphony voice, and `52` does not follow this scheme at all — see section 4.

### Write-fidelity rules

These are easy to get wrong and will produce files MCC rejects or misreads:

| Rule | Detail |
|---|---|
| **Trailing comma** | **Read:** MCC writes a `,` before the final `}`, so `json.loads` fails on every file it produces. Strip with `,(\s*[}\]])` → `\1`, or use a lenient/JSON5 parser. **Write: not required** — protocol test T6.2 (2026-08-01) put a file identical to a known-good export apart from that one byte into MCC; it loaded and transferred to the device. `ksp.lenient_json.dumps` therefore emits strict JSON. This is the *only* rule in this table shown to be optional |
| **Indentation** | Tab-indented |
| **No final newline** | The file ends at `}`. A standard end-of-file fixer breaks byte identity |
| **Line format** | Every line is exactly `\t"<key>": <value>,\n` — one tab, the key quoted, `": "` as the separator. Values are integers (0–247 across all samples) or the two strings below, each formatted exactly as `json.dumps` would. There are no floats, no booleans and no nesting anywhere |
| **Key order** | `device` first, then `version` if present, then every numeric key **sorted as a string**: `126_99_16` comes before `126_99_2`. A numeric sort produces a different file |
| **`version` key** | User-saved projects have `"version": "2.5.20"` immediately after `"device"`. The factory `Default.KeyStepPro` **does not**. A converter starting from the factory default must inject it — and put it in position, because assigning it to a loaded dict appends it at the end |
| **Fixed key set** | All observed files share an identical set of **153,495 numeric keys**. `Default.KeyStepPro` = 153,496 total (no `version`); user projects = 153,497. Never add or remove keys — only overwrite values |

The fixed key set is a significant simplification: there is no risk of omitting a key the
firmware requires, because you always start from a complete file.

Together these rules are enough: applying them to a parsed sample reproduces its bytes exactly.
`ksp.lenient_json.dumps` / `canonical` implement them and `tests/test_round_trip.py` holds all
five samples to byte identity (milestone M3) — save the trailing comma, which the writer
deliberately omits on T6.2's evidence, so its output is one byte shorter than MCC's and is strict
JSON. Every other byte still has to match. Project names are **not** an exception — they are
stored as integer parameters, not JSON strings, so `device` and `version` are the only strings in
the file and no sample contains a non-ASCII byte.

### Item IDs

From `bulkOperation[].bulkItemId` in `KeyStepPro.json`:

| Item ID | Meaning | Entries |
|---|---|---|
| `120` | Project / global — tempo, swing, ARP globals | ~30 |
| `121` | **Scenes** (16 per project) | ~1,488 |
| `122` | **Control track** — 5 CC automation lanes | ~7,316 |
| `123` | **Track 1** — carries **both** a sequencer and a full drum parameter set | ~70,102 |
| `124` / `125` / `126` | **Tracks 2 / 3 / 4** — sequencer only | ~24,853 each |

Track 1 is roughly three times the size of tracks 2–4 because it holds a complete **second
parameter set for DRUM mode**, not because of any extra modulation lane.

---

## 3. Parameter dictionary

`KeyStepPro.json` → `fields[]`. Each entry has an internal `id` **and** a `paramId` — the file
keys use **`paramId`**. Confusing the two is an easy mistake.

### 3.1 Sequencer (melodic) — items 123–126

| paramId | Arturia's name | Indexed by | Range / encoding |
|---|---|---|---|
| `48` | Step Seq step active | **step** 1–64 | 0 / 1 |
| `49` | Step Seq step skip | **step** 1–64 | 4-bit mask, see §5 |
| `50` | Seq note corresponding step | **note** 1–64 | 0-based step, `127` = empty |
| `109` | Seq note pitch | **note** | MIDI note 0–127 |
| `110` | Seq note gate length | **note** | non-linear, see §6 |
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
| `52` | DRUM step active | **packed bitmask**, lane-major, 7 steps per index (§4) |
| `53` | DRUM step skip | **note** |
| `54` | DRUM step corresponding step | **note** (`127` = empty) |
| `117` | DRUM note pitch (drum lane) | **note** |
| `118` | DRUM note gate length | **note** |
| `119` | DRUM note velocity | **note** |
| `120` | DRUM note time shift | **note** |
| `121` | DRUM note randomness | **note** |

Track 1 plays the drum set *or* the sequencer set depending on its mode. That mode is documented
as living in the `100` bitfield, which does not work — the flag is **`86` bit 6**, per section 5.

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
> as a guessed time shift encoding. See §5 for what bit 2 is and is not pinned to.

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

Two points still need the hardware, recorded as **Test D1** in the roadmap:

- MCC's `defaultValue` for Mode is Chromatic with Low note `0`, which would put lane 0 at MIDI
  note 0 — disagreeing with both the manual and the Custom defaults. MCC `defaultValue`s are its
  UI fallback when no device is attached, so the device's factory state is unconfirmed.
- Whether chromatic mode maps lane *i* to `low + i` or `low + i + 1`. The manual's "which note
  the lowest key will trigger" implies the former, but `maxValue: 103` then puts the top lane at
  126, one short of 127, whereas the latter lands exactly on 127.

### 3.3 Per-pattern scalars (index = pattern 1–16)

| paramId | Meaning |
|---|---|
| `97` / `114` | Seq / DRUM swing % — stored with a **+25 offset** (±25% → 0…50) |
| `98` / `115` | Seq / DRUM step count — **0-based** (15 = 16 steps) |
| `99` / `116` | Bitfield: triplet, swing offset, polyrhythm, step size, playback direction. Only **`116` bit 2** is measured — drum Mono/Poly, i.e. per-lane step lengths (§3.2, §5). The rest is unallocated |
| `100` | Bitfield. Dictionary says ARP/Drum mode, ARP type, ARP octave; only **ARP octave (bits 4–6)** is hardware-confirmed, as `stored = octave + 1` (§5). Drum mode is `86` bit 6, not here |
| `107` / `108` | Root note / scale |
| `40` | Pattern data state: `0` in the factory template, `2` initialised but empty, `3` holds data. **A latch** — see below |
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

### 3.4 Per-track and project

`39` track data state · `85` / `86` transposition & octave bitfields · `122` track transposition ·
`87` chord (16 per track) · `59` / `60` track seq / drum colour · `123` track MIDI channel ·
`70`–`72` project tempo · `73` global BPM + metronome bitfield ·
`74` global swing · `75` current scene (0-based) · `68` / `69` ARP groups.

**Tempo is decoded.** `70`–`72` are a little-endian value in 7-bit chunks holding **BPM × 100**:

```
bpm = (p70 + p71 * 128 + p72 * 16384) / 100
```

`project_5` stores 96, 93, 0 → 12000 → **120.00 BPM**. `initial_project` stores 16, 103, 0 →
13200 → **132.00 BPM**. Both empty baselines store 96, 93, 0 and the hardware readout shows
120 BPM, which confirms the decode against the device rather than against another file.
Note the ordering: `70` is the **least** significant chunk.

Global *device* settings — CV/gate outputs, MIDI channel routing, sync, drum map, knob
assignments, velocity/aftertouch curves — are **not** in the project file. They live under
`deviceGlobalParametersId: 65` and are addressed by `globalParamId`.

---

## 4. The two index spaces

**This is the part that breaks naive implementations.**

Within a single `(item, pattern, slot)`, the third index means two different things depending on
which parameter you are reading:

- **Step-indexed** — `48`, `49`: index is the physical step position, 1–64.
- **Note-indexed** — `50`, `109`–`113` (and drum `53`, `54`, `117`–`121`): index is the ordinal
  position in a **note list**, and `paramId 50` (or `54`) maps that note to its **0-based step**.

The KeyStep Pro therefore does **not** store a step grid of note data. It stores a **compact
event list** per slot, plus a separate per-step activity array.

### A third layout: the drum step-active bit array (`52`)

`52` is neither step-indexed nor note-indexed. It is a **flattened `[lane][part]` bit array**,
lane-major, packed **7 bits per entry** with **10 entries per lane** (10 × 7 = 70 ≥ 64 steps).
Its two trailing indices are storage geometry, not lane and step:

```
flat = lane * 10 + (step // 7)
key  = 123_52_<pattern>_<flat // 64 + 1>_<flat % 64 + 1>
bit  = step % 7
```

Hardware-confirmed on `D1-two-hits` / `D1-step-off` (lane 0 → steps {0, 4}, then {0} after the
toggle) and `D3-drum-overflow` (lanes 0–2 all 64 steps set, lane 3 clear — exactly the three
lanes that were filled). It also reproduces on real user material: `initial_project` pattern 1
lane 0 → {0, 4, 8, 12} and pattern 3 lane 7 → all 16 steps, each matching that lane's pool
exactly.

The melodic equivalent `48` is far simpler — one entry per step, value `1` or `0`, and in every
file observed the whole pattern's flags sit in **slot 1**, with slots 2–3 unused. No capture yet
shows what `48` does once a melodic pool spills past 64 events.

Consequences for writing files:

1. Notes should be packed **contiguously from index 1**, with no gaps. **This is a rule for
   writers only** — see "The `127` sentinel" below. A reader must not assume it.
2. Every written note needs its step recorded in `50` / `54`.
3. `48` / `52` (step active) must be kept consistent with the note list. They are **not**
   merely redundant with it: the firmware plays the flags, so a pooled note whose flag is clear
   is silent (see "Pooled does not mean audible" below).
4. The tail of every array must be sentinel-filled.

### The `127` sentinel

`127` marks "empty". But `127` is also a **legal velocity** (and a legal pitch), so
velocity `127` is genuinely ambiguous in isolation.

> **The authoritative existence test is `paramId 50` (or `54` for drums) `!= 127`.**
> Never infer note presence from velocity.

**`127` marks an empty *entry*, not the end of the list — and the two parameter sets differ.**
The drum array is a pool with holes: deleting a note empties its entry and leaves the later ones
where they are. The melodic array is genuinely compacted — verified across all five sample files,
no slot holds a non-`127` value after an interior `127`.

So the scan rules are asymmetric, and a reader that applies rule 1 to the drum set destroys data.
`initial_project` Track 1 pattern 5 slot 1 has holes at entries 28–29 and 35, with five lane-12
notes at entries 30–34 and four lane-17 notes at 36–39 behind them; pattern 9 has holes at
entries 22–24 and 28. Stopping at the first sentinel drops **43 live notes** across the two
patterns, and then reports their step-active flags as orphans.

> **The check that settles it:** scanning the whole pool takes flags-without-a-note to **exactly
> zero** on every pattern of every sample file, while leaving the pooled-but-unflagged notes
> (capture D1) untouched. Every flagged step having a pooled note is an invariant, so a violation
> means the pool was decoded wrongly — not that the file is damaged.

### `idx2` is a pool chunk, not a voice — and the zero-fill trap

`idx2` runs **1–4 on Track 1** and **1–3 on Tracks 2–4**, and it is tempting to read it as a
poly/chord voice. It is not. It **chunks one flat note pool into blocks of 64 entries**, giving
a real capacity of **192 events per pattern** (3 × 64) on every track.

Polyphony is expressed inside a chunk, as **consecutive note ordinals sharing the same `50`
(or `54`) value**. Hardware-confirmed by capture `D2-chord4-tr3` / `D2-chord4-tr1`: a four-note
chord is accepted on both Track 3 and Track 1, and lands in **slot 1, ordinals 1–4**, all with
`50` = 0, while slots 2 and 3 stay entirely sentinel-filled. There is no three-voice ceiling,
and Track 1 has no extra voice. The device gave **no feedback at all** on the fourth voice — it
simply took it, which is what settles that the ceiling was never there. (Building a chord on the
device needs **Step Edit** mode; that is data entry, not format — see the test protocol.)

Notes reach slot 2 only when slot 1's 64 entries are full. `D3-drum-overflow` fills a drum
pattern past capacity: the events land 64 in slot 1, 64 in slot 2, 64 in slot 3, and the device
then displays a **192-note limit** error. So the ceiling is real and the firmware enforces it.

**At the ceiling the device refuses the next hit — it does not overwrite.** The operator confirms
the 193rd hit was rejected outright, with the error shown immediately and no existing event
disturbed. So there is no "oldest note wins" recycling to emulate: a writer handed more than 192
events per pattern must either **reject the source** or **drop the overflow and warn**, and
either way the file it emits stays a faithful prefix rather than a scrambled pool.

> **Track 1's fourth slot is zero-filled, not sentinel-filled.** In all 16 patterns of all five
> sample projects — including both empty baselines and real user material — `123_50_*_4_*` and
> `123_54_*_4_*` are entirely `0`, as are the matching pitch and velocity arrays. The firmware
> appears never to initialise it.

This is the one place where the `!= 127` existence rule is not sufficient on its own. Read
literally, a zero-filled slot is 64 notes at step 0 with velocity 0, in both parameter sets, in
every pattern — so a completely empty project decodes as 2,048 phantom notes.

The reliable test is narrow: treat a slot as uninitialised only when **note→step, pitch and
velocity are all uniformly zero**. That cannot be confused with real data, because a note with
velocity 0 is silent and 64 notes cannot all sit on step 0. `project_5`'s kick is note→step `0`
with pitch (lane) `0` and is correctly kept, because its velocity is 127.

Slot 4 is now measured, and it is a phantom: `D2-chord4-tr1` adds a fourth chord voice on
Track 1 and `123_*_1_4_*` does not move at all — the note goes to slot 1 ordinal 4 like every
other track. A writer must never place events there.

### Pooled does not mean audible

A note can sit in the pool, fully formed, and still not play. **"Why a note might not play" below
lists every reason;** this section is the evidence for the commonest one, row 2.

`D1-two-hits` / `D1-step-off` toggle a drum step off **without deleting its note**: the pooled
entry survives byte-for-byte and only the step-active bit clears — and the step does not sound on
the device.

> **Existence and audibility are different tests.** `50` / `54` `!= 127` says a note *exists*.
> Whether it *plays* additionally requires its **step-active bit** (`48` melodic, `52` drum) to
> be set. A reader that reports pooled notes is correct; an exporter that renders them without
> checking the flag emits audio the hardware never makes.

This is not hypothetical. In `initial_project`, pattern 3 lanes 0 and 19 hold 20 pooled drum
notes with no flags at all, and pattern 1 lane 17 holds 8 of which only 4 are flagged.

**The device itself cannot show you the difference**, which is why the corpus is full of these.
Asked directly whether the UI distinguished "step off, note still stored" from "step empty" after
the D1 toggle, the operator reports it showed **nothing** — the step button's lamp *is* the
step-active bit and there is no second indicator behind it. Two consequences worth stating
because they are not guessable from the file:

- **A stored note cannot be overwritten by playing over it.** Entering a new pitch and pressing
  an unlit step re-lights the *old* note; the new pitch does not replace it.
- **ERASE + the step button is the only way to actually clear one.** Toggling a step off is a
  mute, not a delete, in the UI exactly as in the file.

So a pooled-but-unflagged note is the normal residue of ordinary playing, not a sign of a damaged
file — and a converter that silently drops them is discarding material the owner can still hear
by tapping one button.

### Why a note might not play

Existence and audibility are different tests, and there is more than one way to fail the second.
**This table is the complete list.** Everything below it is the evidence.

| # | Why it does not play | Key in the file | Example, from a committed file | Undo on the device | Confidence |
|---|---|---|---|---|---|
| 1 | The pool entry is empty — there is no note | `<item>_50_<pat>_<slot>_<ord>`, `54` for drums | `123_54_9_1_22` = `127` — a **hole**, not the end: ordinals 21 and 25 hold steps 42 and 44 | n/a, nothing is stored | Certain |
| 2 | **Disabled: step turned off** | drum `123_52_<pat>_<slot>_<idx>`, one **bit**; melodic `<item>_48_<pat>_1_<step>`, one entry | `123_52_9_1_1` = `0` → lane 0 step 5 is off. Contrast `123_52_9_1_2` = `2` = `0b0000010` → lane 0 step 9 is on. **No melodic example exists** — see below | Re-light the step; the note returns intact | **Hardware** (D1), drums only |
| 3 | **Disabled: past the last step** | `<item>_98_<pat>` melodic, `123_115_<pat>` drum, 0-based | `123_115_9` = `47` → 48 steps, while `123_54_9_1_45` = `56` → step 57 | Raise Last Step | **Hardware** (O1) |
| 4 | Velocity 0 | `<item>_111_<pat>_<slot>_<ord>`, `119` for drums | **None in the corpus** — no note in any committed file has velocity 0 | Raise the velocity | Inferred, never tested |
| 5 | Skipped on this pass | melodic `<item>_49_<pat>_<slot>_<step>` (**step**-indexed), drum `123_53_...` (**note**-indexed) | `125_49_1_1_5` = `5` = `0b0101` → plays on 16 and 48 only; `15` is the default "always" | Set the mask to all four | ⚠ **Unresolved** — repeats or pages? **T5.8** |
| 6 | Lost to randomness | `<item>_113_<pat>_<slot>_<ord>`, `121` for drums | `125_113_1_1_1` = `10`, against a fresh note's default of `100` | Set randomness to always | ⚠ **Unresolved** — probability or timing jitter? **T7.8** |

Row 2's drum key needs the packing from "A third layout" above, because one entry holds seven
steps of one lane. Worked through for the disabled kick at step 5 of `initial_project` pattern 9 —
lane 0, 0-based step 4:

```
flat = lane * 10 + step // 7   = 0 * 10 + 4 // 7 = 0
key  = 123_52_9_<flat//64 + 1>_<flat%64 + 1>     = 123_52_9_1_1   -> 0 = 0b0000000
bit  = step % 7 = 4                              -> (0 >> 4) & 1  = 0   step is OFF
```

**Two of these six have no example in any committed file**, and that is a finding rather than an
omission. No melodic note anywhere in the corpus has its `48` bit clear, which is why row 2's
melodic half rests on the drum result plus agreement between `48` and the note list — protocol
**T4.5** is the capture that settles it, and it is the highest-value one outstanding. No note
anywhere has velocity 0, so row 4 is inference from MIDI convention alone.

Rows **2 and 3 are what "disabled" means** — one state, two mechanisms, both toggled the same way
on the device, and the only two the tools report under that word. Say "disabled (step turned
off)" or "disabled (past the last step)"; never "silent", "inactive" or "lost".

Rows 5 and 6 differ in kind: they are properties of a *pass*, not of the note's stored state, so
the same note can sound on one loop and not the next. Neither is decodable at the desk. Until
T5.8 and T7.8 run, `ksp2midi` renders one pass and includes every note whatever its mask.

Row 1 is not a disabled note at all — it is the absence of one. Note also that `127` marks an
empty *entry*, not the end of the list; see "The `127` sentinel" above, because reading it as a
terminator silently discards live notes.

#### Evidence for row 3 — the last step

**Hardware-observed** on `initial_project` Track 1 pattern 9. `123_115_9` = 47, i.e. a 48-step
drum pattern, and the pattern holds pooled, step-active notes out to step 63.

**In the project's saved state those notes are disabled and do not play** — that is the file's
own configuration and the correct behaviour. The observation was made by deliberately raising
Last Step to 64, at which point they appear and sound; lowering it back to 48 disables them
again, with the step-64 light going out. The toggle was a diagnostic action, not the file's state.

> **Notes past the last step are disabled, not stale.** Being past the last step is one of the
> two ways a note is disabled — the other is its step being turned off — and both are toggled the
> same way on the device. So shortening a pattern disables those notes without deleting anything,
> and lengthening it enables them again, intact. A writer must therefore preserve them, and a
> reader must not treat "past the declared length" as evidence that an entry is leftover junk.
> `ksp2midi` drops them by default, the same as any other disabled note, and says how many;
> `--include-disabled` exports them.

**This is not the step-skip question.** The 16 / 32 / 48 / 64 *mask* (`49` / `53`, "repeats or
pages?" in §5) is a separate mechanism and is still unresolved — protocol **T5.8** decides it.
The observation above is about the pattern's declared length only.

---

## 5. Worked example and validation

Verified against `project_5_description.txt`, whose values were confirmed on the hardware display.
**Track 3 = item `125`, pattern 1.** Slot 1 decodes as:

| Index | `48` (by step) | `49` (by step) | `50` (by note) | `109` pitch | `111` velo | `112` shift | `113` rand |
|---|---|---|---|---|---|---|---|
| 1 | 1 | 15 | 0 | 48 | 60 | 50 | 10 |
| 2 | 1 | 15 | 1 | 48 | 70 | 51 | 20 |
| 3 | 1 | 15 | 2 | 48 | 90 | 52 | 30 |
| 4 | 1 | 15 | 3 | 48 | 100 | 53 | 40 |
| 5 | 1 | 5 | 4 | 49 | 60 | 48 | 100 |
| 6 | 1 | 5 | 5 | 49 | 70 | 47 | 100 |
| 7 | 1 | 10 | 6 | 49 | 90 | 46 | 100 |
| 8 | 1 | 10 | 7 | 49 | 100 | 45 | 100 |
| 9 | 1 | 3 | 8 | 50 | 60 | 49 | 100 |
| 10 | 0 | 15 | **12** | 50 | 120 | 51 | 100 |
| 13 | **1** | **12** | 127 | 127 | 127 | 127 | 127 |

Reading that against the documented intent:

| Documented | Decoded | ✓ |
|---|---|---|
| Beats 1–4 note C2 | `109` = 48 | ✓ |
| Beats 5–8 note C#2 | `109` = 49 | ✓ |
| Beats 9+ note D | `109` = 50 | ✓ |
| Velocities 60, 70, 90, 100 | `111` = 60, 70, 90, 100 | ✓ |
| Time shift +1…+4 | `112` = 50, 51, 52, 53 → **centre 49** | ✓ |
| Time shift −1…−4 | `112` = 48, 47, 46, 45 | ✓ |
| Randomness 10, 20, 30, 40 | `113` = 10, 20, 30, 40 | ✓ |
| Plays on all of 16/32/48/64 | `49` = 15 = `0b1111` | ✓ |
| Notes 5–6 play on 16, 48 | `49` = 5 = `0b0101` | ✓ |
| Notes 7–8 play on 32, 64 | `49` = 10 = `0b1010` | ✓ |
| 2nd D note plays on 48, 64 | `49` **at step 13** = 12 = `0b1100` | ✓ |
| 16-step pattern | `98` = 15 (0-based) | ✓ |

Note rows 10 and 13 are what proves §4. The tenth *note* sits at step 13 (`50` = 12, 0-based),
so its velocity 120 appears at **note** index 10 while its skip mask 12 appears at **step**
index 13. Read with a single index space, this looks like a data inconsistency; read correctly,
every value lines up.

### Step skip is a 4-bit mask

The KeyStep Pro can run a pattern as four consecutive 16-step sequences (16 / 32 / 48 / 64).
`49` / `53` is a bitmask of which of those a note plays in:

| Bit | Value | Sequence |
|---|---|---|
| 0 | 1 | 16 |
| 1 | 2 | 32 |
| 2 | 4 | 48 |
| 3 | 8 | 64 |

`15` = plays always (the default). `5` = {16, 48}. `12` = {48, 64}.

> **Unresolved: repeats or pages?** "Four consecutive 16-step sequences" reads as four *pages* of
> a 64-step pattern, but `project_5` pattern 1 is only **16 steps** and carries notes masked to 48
> and 64 — which under the pages reading could never sound, contradicting a hardware-confirmed
> description. Under a *repeats* reading (the pattern loops four times and the mask picks which
> loops a note plays in) every mask is meaningful at any length. Nothing in the files separates
> the two; **protocol T5.8** does, on the device. Until then `ksp2midi` renders a single pass,
> includes every note whatever its mask, and warns that it did — a `--passes` expansion built on
> the wrong reading would produce files that play confidently wrong.

### Drum validation

Track 1 (item `123`), pattern 1, documented as "kick on beats 1 and 5":

- `123_52_1_1_1` = **17** = `0b0001_0001` → bits 0 and 4 → **steps 1 and 5**.
  `52` appears to pack 8 steps per index, so 64 steps would occupy indices 1–8. See the caveat below.
- `54` (note→step) = `0`, `4` → steps 1 and 5. ✓
- `119` velocity = 127, 50 ✓ · `121` randomness = 80, 90 ✓
- `120` time shift = 48, 50 → −1 and **+1**. ⚠ The description gives −1 for *both* kicks. See
  "Unresolved: drum time shift" below.
- `53` skip = 3 (`{16,32}`), 12 (`{48,64}`) ✓ — note-indexed here, unlike the melodic `49`.

> The melodic `49` is step-indexed while the drum `53` is note-indexed. This asymmetry is what
> the data shows consistently across files, but it is unusual enough to re-confirm before
> relying on it in a writer.

### Unresolved: drum time shift in `project_5`

`project_5_description.txt` states Time Shift **−1** for both kick hits. Parameter `120` stores
`48` and `50`, which decode to −1 and **+1** against the centre of 49.

Every other value in the project reproduces exactly, and the melodic +1…+4 / −1…−4 ramp
independently confirms that the centre is 49, so a transcription slip in the description is the
likelier explanation — but it has not been re-checked on the device. The M1 fixtures record the
file's value and keep the conflict asserted, so it cannot quietly disappear.

### Unresolved: how long one time-shift unit is

The *centre* of `112` / `120` is confirmed, so a stored value decodes to a signed shift. What a
shift of ±1 is worth **in time** is not known — presumably a fraction of a step, but nothing
measures it. M2's MIDI export therefore places every note on the flat grid and warns rather than
picking a scale. Protocol tiers 7 and 8: place one note per shift value across a pattern, export
once — the batched method that made tier 2 a single capture — and time the result against an
unshifted note.

### Resolved: the drum step-active bitmask (`52`)

An earlier 8-steps-per-index reading fitted both hardware-confirmed projects (`project_5`:
17 → steps 1 and 5; `project_9`: 1 → step 1) but failed on `initial_project`, where pattern 1
holds a kick on steps 1, 5, 9, 13 and a second lane on every odd step, yet `52` reads `17, 34`
where that packing predicts `17, 17` and `85, 85`.

The correct layout is **7 bits per entry, lane-major, 10 entries per lane**, given in section 4.
Under it `17, 34` decodes to lane 0 → steps {0, 4, 8, 12}, matching that lane's pool exactly,
and lane 17's flags are found at a different offset entirely. It reproduces on every file and
capture checked.

This unblocks writing: a writer can now emit `52` consistently, which M5/M6 require.

The melodic step-active array (`48`) is simpler — one entry per step — and agrees with the note
list everywhere observed. Both are cross-checked by the reader, which warns rather than
reconciling.

### Resolved: drum mode is parameter `86` bit 6, not `100`

`100` is documented as the ARP/Drum mode bitfield, but it reads **26 in every pattern of every
sample project** — including patterns that are unambiguously melodic and ones that are
unambiguously drum. It cannot be used to tell which parameter set is live.

The flag that *can* is **`86` bit 6**, and two independent lines of evidence agree:

- `KeyStepPro.json` names it — field id 17, `paramId 86`, `"name": "Track keyboard octave,
  chord mode state, Arp/Drum mode state in a bitfield"`, `"comment": "Arp/Drum mode state :
  bit 6"`.
- The data matches exactly. `123_86` is **66** (`0b1000010`, bit 6 set) in `project_5`,
  `project_9` and `initial_project` — every sample holding drum notes — and **2** in both empty
  baselines. Tracks 2–4 never set it.

**Confirmed on hardware.** Capture `T3-track1-drum` switches Track 1 from sequencer to drum mode
and produces a **one-key diff**: `123_86` 2 → 66. `100` does not move at all, in that capture or
any other.

It is **track-level, not per-pattern**, which matches the device's Drum button. The field is
named *Arp*/Drum, and on tracks 2–4 bit 6 does indeed mean ARP: `T3-arp-on` engages the
arpeggiator on Track 2 and sets `124_86` to 66. There is no ambiguity on Track 1, because Track 1
has no arpeggiator — drum mode replaces it entirely — so bit 6 there is unconditionally the drum
flag.

What `100` *does* carry is the **ARP octave, at bits 4–6**, matching the dictionary's own
comment: `T3-arp-octave` moves `124_100_1` from 26 to 42, i.e. that field from 1 to 2. Toggling
the arpeggiator on and off leaves `100` untouched, so ARP on/off is not stored there either.
Note the scope difference: `86` is per-track, `100` is per-pattern.

**The ARP octave has no display, and that is the whole encoding.** It is chosen by holding SHIFT
and striking one of five keys on the second physical octave, which are silkscreened with the
values — there is no screen readout to reconcile against. The range is five detents and the
default is 0, at C#3:

| Displayed / silkscreened | −1 | 0 | +1 | +2 | +3 |
|---|---|---|---|---|---|
| Stored in `100` bits 4–6 | 0 | **1** | 2 | 3 | 4 |

`T3-arp-octave` is the +1 move: default 0 → +1, stored 1 → 2. **`stored = octave + 1`**, so the
field is a plain unsigned offset with 0 as the floor rather than a signed value. Two of the five
rungs are measured and the remaining three follow from the range and the constant step; a
converter reporting ARP octave must state the offset it applied, since it cannot echo a screen.

This resolves the ambiguity that made the reader report `PatternMode.BOTH`. **`initial_project`
Track 1 pattern 1 holds both** a real 64-step melody and a real 12-note drum pattern; bit 6 is
set, so the drums are live and the melody is leftovers. The reader still reports every note and
warns — it resolves the *mode*, it does not discard data.

### Partly resolved: `116` bit 2 is drum Mono/Poly

The `99` / `116` bitfield is otherwise unallocated, but one bit is now measured.
`D4-lane-steplength` was taken to pin `51`, and it moves a second scalar nobody diffed for:
**`123_116_1` 16 → 20**, bit 2, set at the same moment the operator switched Track 1's drum
mode from Mono to Poly to give lanes independent lengths. That matches the dictionary's own
*polyrythm state* among the field's named contents.

So for the **drum** side: **bit 2 clear = Mono, all 24 lanes share one length; bit 2 set = Poly,
`51` is honoured per lane.** §3.2 states the writer's obligation.

**What is not pinned.** The capture moved the mode and a lane length together, so bit 2 is
established as "the thing that makes lanes independent" and not, strictly, as a bit named
polyrhythm in general. And it does **not** transfer to the melodic side by symmetry: `Default`
holds `99` = 20 with bit 2 **already set** on every pattern while `116` = 16 has it clear, so the
two halves cannot both mean "polyrhythm off by default". Either the bit means something else in
`99`, or its sense is inverted, or the defaults simply differ. Tier 5 resolves that; until it
does, treat only `116` bit 2 as known.

---

## 6. Open questions: the timing encodings

Two encodings remain unmeasured, and both displace a note in time. They are collected here
because one hardware session resolves them — see
[`Timing_Calibration.md`](./Timing_Calibration.md) for the model and
[`Hardware_Test_Protocol.md`](./Hardware_Test_Protocol.md) tiers 7 and 8 for the captures. Gate
length is **resolved** (§6.1) and kept in the table for contrast.

| Encoding | Parameters | State | Captures |
|---|---|---|---|
| Gate length | `110` / `118` | **measured** — 128-entry ladder, one derived entry | Tier 2 ✔ |
| Time shift range and linearity | `112` / `120` | centre 49 confirmed; range unknown | T7.1–T7.3 |
| Time shift unit (ticks? ms?) | `112` / `120` | wholly unknown | Tier 8 |
| Swing semantics | `74`, `97` / `114` | **never exercised** in any sample file | T7.4–T7.7 |

**Swing deserves particular caution.** `74` reads 50 and `97` / `114` read 25 in all 16 patterns of
all four tracks of all five sample projects, so there is no observational data on it whatsoever.
MCC labels `97` / `114` a signed offset (−25 %…+25 %) while `ksp.reader._swing` reads them as an
absolute percentage; the two agree only because the global is always 50 here.

### 6.1 Gate length

**Measured, 2026-07-31.** Capture `T2-gate-table.KeyStepPro`, protocol tier 2; the full ladder is
in `analysis/gate_ladder.txt`.

**The encoding is an index, not a curve.** `stored = detent index − 1` — the stored value is the
0-based position in the encoder's ladder. Every bit of the non-linearity lives in the *display*.
The earlier `stored = 8·g + 3` / `4·g` piecewise reading was an artefact of fitting six scattered
points as though they described the encoding; it is superseded.

The display ladder is five constant-increment runs, closing exactly on the 7-bit boundary:

| Increment | Display span | Stored | Count |
|---|---|---|---|
| 1/16 | 0.0625 → 0.5 | 0–7 | 8 |
| 1/8 | 0.625 → 3 | 8–27 | 20 |
| 1/4 | 3.25 → 8 | 28–47 | 20 |
| 1/2 | 8.5 → 32 | 48–95 | 48 |
| 1 | 33 → 64 | 96–127 | 32 |
| | | | **128** |

**128 detents, stored 0–127, gate 0.0625 → 64 steps.** `118` (drum) uses the identical ladder,
spot-checked at five points. The six previously known values (`0.5→7`, `1→11`, `2→19`, `3→27`,
`3.5→29`, `4→31`) all reproduce, and were the evidence that identified the index relation.

**Displayed values are exact binary fractions of a step, rendered to two decimals with
round-half-to-even** — `0.625` shows as `0.62`, `0.875` as `0.88`. A converter must use the exact
fraction; the two-decimal form is a display artefact and is wrong by up to 4 % at the bottom of
the range.

**The displayed gate is a length in steps.** `project_5_description.txt` documents a note placed
on beat 9 and tied through beat 12 — four steps — as gate 4, and the file stores `110` = 31 for
it. So a gate converts directly into a note duration; M2's MIDI export relies on this.

**Do not invent a formula for this.** A converter using a plausible-but-wrong gate table produces
files that load fine and play with wrong note durations — the worst kind of bug, because nothing
errors. That warning is against fitting a curve to sparse points, which is what the superseded
`8·g + 3` reading did. It is not an objection to the ladder above: 64 consecutive detents were
transcribed directly, the rest enumerated from an observed increment rule and count-verified by
the exact closure at stored 127.

**Stored `36` (gate 5.25) is now measured too.** It was the sweep's one derived rung — that note
had been over-turned by a detent and stored 37 — and capture `D25-gate-capture.KeyStepPro` closes
it: a single note placed with the Gate display reading **5.25**, diffing against `B0-baseline` to
eight keys on Track 2, with `124_110_1_1_1` = **36**. Predicted and observed agree, so no
transcribed rung of the ladder rests on interpolation any more.

(The stored 65–78, 80–94 and 97–125 spans remain *enumerated* from the increment rule rather than
transcribed. That is a different and weaker provenance class, count-verified only by the exact
closure at 127, and it is not upgraded by this capture.)

This also resolves the long-standing `?(2)`: `initial_project`'s drum gate stored `2` is detent 3,
gate **0.1875**.

**Default gate is `7` (0.5).** A freshly placed note stores `7`, confirmed by `project_9`'s
untouched notes and by `initial_project`. Alongside it, a fresh note's other defaults are
velocity `100`, time shift `49` (0), randomness `100` and step skip `15` (all four sequences).

**The complete key set a note-creating writer must produce** was measured directly by capture
`T1-note-place`, which placed one note in an untouched pattern and moved exactly eight keys —
no more:

| Key | Value | Meaning |
|---|---|---|
| `50` | `0` | note→step, 0-based |
| `109` | pitch | the MIDI note |
| `110` | `7` | gate (0.5) |
| `111` | `100` | velocity |
| `112` | `49` | time shift, centred |
| `113` | `100` | randomness |
| `48` | `1` | step active |
| `40` | `3` | pattern holds data |

Deleting that note returns all of them to sentinel **except `40`**, which latches at 3 (§3.3).
That capture's display read `0.5`, which confirms the ladder's `7 → 0.5` entry from a second
direction and a separate session.

**Implemented.** `ksp.constants.GATE_TABLE` now enumerates all 128 rungs from the five runs above,
and `decode_gate` reserves `?(raw)` for a value outside 0–127. The measured/derived provenance is
carried in the code comment, and `tests/test_gate_ladder.py` checks the enumeration against every
line of `analysis/gate_ladder.txt` — so the table cannot drift from the transcription
without a test failing.

---

## 7. Future path: direct-to-hardware over SysEx

Recorded for completeness; **not needed for file conversion.**

MCC's `arturia_v2` protocol pushes projects as an ack-per-chunk SysEx bulk stream inside an
`F0 00 20 6B … F7` envelope. A canned frame in the binary reads:

```
f0 00 20 6b 7f 42 02 00 40 6a 31 f7
         ^^ ^^    ^^ ^^^^^
         |  |     |  familyId 0200
         |  |     productId 42 (KeyStep Pro)
         manufacturerId 00 20 6B
```

The bulk stream is addressed by the tuple `(bulkItemId…, paramId, valueId/index)` — **the same
address tuple the file keys encode**, which is why `bulkOperation` in the device JSON describes
both transports. A CoreMIDI direct-transfer path is therefore structurally feasible and would
reuse the same model layer.

The blocker: the binary's strings do not reveal the byte-level command layout beyond the
envelope, so this would need live frame capture to reverse. The file route needs none of that.

(`libusb` in `/Library/Arturia/Shared/` is used only for DFU firmware updates — not for projects.)

---

## 8. Corrections to the deprecated analysis

| Prior claim | Reality |
|---|---|
| "MCC ships no readable KeyStep resource file" | `/Library/Arturia/.../Resources/KeyStepPro.json` is the full dictionary |
| `48` = tie, `49` = velocity, `50` = pitch | `48` = step active, `49` = step skip, `50` = note→step. Pitch is `109` |
| Velocity stored as 16 discrete levels | Full 0–127, stored directly |
| Item `121` = arpeggiator / chord memory | Scenes |
| Track 1's extra params are a modulation lane | A complete DRUM-mode parameter set |
| All indices are `pattern_slot_step` | Two index spaces: step-indexed vs note-indexed |
| `idx2` is a polyphony voice, capped at 3 (4 on Track 1) | A 64-entry pool chunk. Chords share a chunk as consecutive ordinals; capacity is 192 events |
| Risk of omitting keys the firmware needs | Key set is fixed and identical across all files |
| `arturia2midi` is doing this on GitHub | Could not be found. Treat as unverified |

The deprecated document's *high-level* observations — flat JSON, trailing comma, structure in
the key names, 16 patterns × 64 steps, template-and-overwrite as the practical strategy — were
sound. Its **field-level mappings** were not.

---

## 9. Reproducing these findings

Everything above is checkable from files already on disk. Minimal parser:

```python
import json, re

def load(path):
    s = open(path, encoding='utf-8', errors='replace').read()
    return json.loads(re.sub(r',(\s*[}\]])', r'\1', s))   # strip trailing commas

spec = load('/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json')
proj = load('project_files/project_5.KeyStepPro')

# the parameter dictionary
for f in spec['fields']:
    print(f.get('paramId'), f.get('name'))

# Track 3, pattern 1, slot 1 — pitch by note ordinal
print([proj.get(f'125_109_1_1_{i}') for i in range(1, 13)])
```

The §5 tables were produced this way. Any claim here that cannot be re-derived from
`KeyStepPro.json` plus the files in `../project_files/` should be treated as suspect.
