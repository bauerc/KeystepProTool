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
- It is **not strict JSON** — it has trailing commas.
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
- **MCC can export MIDI files but cannot import them.** That is the gap this project fills.
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
indices address pattern / slot / step-or-note.

### Write-fidelity rules

These are easy to get wrong and will produce files MCC rejects or misreads:

| Rule | Detail |
|---|---|
| **Trailing comma** | There is a `,` before the final `}`. `json.loads` fails. Strip with `,(\s*[}\]])` → `\1`, or use a lenient/JSON5 parser. Re-emit it on write until proven unnecessary |
| **Indentation** | Tab-indented |
| **`version` key** | User-saved projects have `"version": "2.5.20"` immediately after `"device"`. The factory `Default.KeyStepPro` **does not**. A converter starting from the factory default must inject it |
| **Fixed key set** | All observed files share an identical set of **153,495 numeric keys**. `Default.KeyStepPro` = 153,496 total (no `version`); user projects = 153,497. Never add or remove keys — only overwrite values |

The fixed key set is a significant simplification: there is no risk of omitting a key the
firmware requires, because you always start from a complete file.

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

### 3.2 Drum — item 123 (Track 1) only

| paramId | Arturia's name | Indexed by |
|---|---|---|
| `51` | DRUM poly step count | step |
| `52` | DRUM step active | **packed bitmask**, 8 steps per index |
| `53` | DRUM step skip | **note** |
| `54` | DRUM step corresponding step | **note** (`127` = empty) |
| `117` | DRUM note pitch (drum lane) | **note** |
| `118` | DRUM note gate length | **note** |
| `119` | DRUM note velocity | **note** |
| `120` | DRUM note time shift | **note** |
| `121` | DRUM note randomness | **note** |

Track 1 plays the drum set *or* the sequencer set depending on its mode, which is documented as
living in the `100` bitfield — but see the caveat in section 5: `100` does not currently
distinguish them.

Usually the unused set is fully sentinel-filled, which makes the live one obvious. That is not
guaranteed: `initial_project` Track 1 pattern 1 has real content in **both**. A converter must
set the mode to match what it writes, and a reader should not assume only one set is populated.

`117` holds the **drum lane**, 0-based — lane 0 is the kick, confirmed by `project_5`; lanes up
to 19 appear in `initial_project`, consistent with the device's 24 lanes. Its value in an
*empty* list is `60`, not `127`, and drum velocity `119` defaults to `100` rather than `127`.
Neither is a note: existence is decided by `54` alone, which is sentinel-filled as usual.

### 3.3 Per-pattern scalars (index = pattern 1–16)

| paramId | Meaning |
|---|---|
| `97` / `114` | Seq / DRUM swing % — stored with a **+25 offset** (±25% → 0…50) |
| `98` / `115` | Seq / DRUM step count — **0-based** (15 = 16 steps) |
| `99` / `116` | Bitfield: triplet, swing offset, polyrhythm, step size, playback direction |
| `100` | Bitfield: ARP/Drum mode, ARP type, ARP octave |
| `107` / `108` | Root note / scale |
| `40` | Pattern data state: `0` in the factory template, `2` initialised but empty, `3` holds data |
| `20`–`23`, `25`–`28` | Program Change (Seq / Drum), MSB/LSB split |
| `101`–`106` | User scales 1 and 2, each split MSB / MidSB / LSB |

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

Consequences for writing files:

1. Notes must be packed **contiguously from index 1**, with no gaps.
2. Every written note needs its step recorded in `50` / `54`.
3. `48` / `52` (step active) must be kept consistent with the note list — they are redundant
   with it, and the firmware reads both.
4. The tail of every array must be sentinel-filled.

### The `127` sentinel

`127` marks "empty". But `127` is also a **legal velocity** (and a legal pitch), so
velocity `127` is genuinely ambiguous in isolation.

> **The authoritative existence test is `paramId 50` (or `54` for drums) `!= 127`.**
> Never infer note presence from velocity.

### Polyphony slots, and the zero-fill trap

`idx2` is the poly/chord voice: **1–4 on Track 1**, **1–3 on Tracks 2–4**. Simultaneous notes
at the same step are distributed across slots.

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

Whether slot 4 is usable at all on the hardware is untested — no sample project puts a fourth
voice on Track 1. A writer should not assume it works.

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

### Caveat: the drum step-active bitmask (`52`) is not fully decoded

The 8-steps-per-index reading above reproduces both hardware-confirmed projects exactly
(`project_5`: 17 → steps 1 and 5; `project_9`: 1 → step 1). It does **not** account for
`initial_project`, which is real user material: pattern 1 slot 1 holds a kick on steps 1, 5, 9,
13 and a second lane on every odd step, yet `52` reads `17, 34` where the packing predicts
`17, 17` and `85, 85` respectively.

Since `52` is redundant with the note list, this does not block reading — **notes come from
`54` plus `117`–`121`, which is authoritative**. It does block writing, because a writer has to
emit `52` consistently. Resolve before M5/M6.

By contrast the melodic step-active array (`48`) *is* understood, and agrees with the note list
on every slot of both hardware-confirmed projects. The M1 reader cross-checks it on every slot
and warns rather than reconciling.

### Caveat: parameter `100` does not currently identify drum mode

`100` is documented as the ARP/Drum mode bitfield, but it reads **26 in every pattern of every
sample project** — including patterns that are unambiguously melodic and ones that are
unambiguously drum. It cannot presently be used to tell which parameter set is live.

Usually this does not matter, because the unused set is fully sentinel-filled. But it is not
always decisive: **`initial_project` Track 1 pattern 1 holds both** a real 64-step melody and a
real 12-note drum pattern. A reader must report both; a writer must isolate the actual mode bit
before it can set it. Deferred to M6.

---

## 6. Open question: gate length encoding

Gate (`110` / `118`) is **not linear** and is not yet fully decoded. Observed
display → stored values, all hardware-confirmed:

| Displayed gate | Stored |
|---|---|
| 0.5 | 7 |
| 1 | 11 |
| 2 | 19 |
| 3 | 27 |
| 3.5 | 29 |
| 4 | 31 |

Up to gate 3 this fits `stored = 8·g + 3` exactly. Above 3 it compresses to roughly `4·g`.
Two independent captures both produced `4 → 31`, so the deviation is real rather than a
misreading.

**Do not invent a formula for this.** A converter using a plausible-but-wrong gate table
produces files that load fine and play with wrong note durations — the worst kind of bug,
because nothing errors.

**To resolve:** on the hardware, place a single note, step its gate through every selectable
value, and export at each setting. Diff to build the table. Roughly 10–15 captures. Gate is
pure lookup data once measured.

**Default gate is `7` (0.5).** A freshly placed note stores `7`, confirmed by `project_9`'s
untouched notes and by `initial_project`. Alongside it, a fresh note's other defaults are
velocity `100`, time shift `49` (0), randomness `100` and step skip `15` (all four sequences).

The M1 reader decodes only the six measured points and prints anything else as `?(raw)` rather
than interpolating. `initial_project` contains at least one such value (`2`).

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
