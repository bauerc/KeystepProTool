# MIDI → KeyStep Pro: Research Findings & Documentation Deliverables

> **Scope of this plan: documentation only. No application code is written.**
> Three markdown files are produced: a corrected format specification, a deprecation of the
> old analysis, and a staged build roadmap. The tool itself is a separate future task.
>
> Audience for the eventual tool: **other KeyStep Pro owners**, so distribution is a real
> constraint and the roadmap ends in a shippable native macOS app.

## Context

The goal is a macOS tool that converts standard MIDI files into Arturia KeyStep Pro
project files (`.KeyStepPro`) that can be loaded through MIDI Control Center (MCC) and
pushed to the hardware.

The repo already contained a prior analysis (`analysis/KeyStepPro_File_Format_Analysis.md`)
that reverse-engineered the format from the project files alone, because it concluded MCC
ships no readable KeyStep resource file. **That conclusion was wrong, and so were several
of its field mappings.** MCC actually ships a complete, authoritative parameter dictionary
on disk. This investigation recovered it and validated it end-to-end against the user's own
documented test projects. The format is now essentially fully understood, which changes the
plan from "guess and diff" to "generate directly from a known schema."

---

## 1. Where the authoritative data lives

MCC keeps its device data **outside** the app bundle, in a shared directory:

| Path | What it is |
|---|---|
| `/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json` | **The parameter dictionary** (217 KB) — 205 field definitions, 25 item types, 18 bulk-transfer descriptors |
| `/Library/Arturia/MIDI Control Center/Resources/KeyStepProTest.json` | Factory-test variant of the same schema |
| `/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.ui` | UI layout for the device panel |
| `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/Factory/Default.KeyStepPro` | **Canonical blank project** — the ideal converter baseline |
| `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/` | MCC's project library; files here appear in MCC's Project Browser |
| `/Library/Arturia/MIDI Control Center/Firmware/keystep-pro_Firmware_Update_2.5.20.0.kspf` | Firmware image |

Device identity from `KeyStepPro.json`: USB vendor `7285` (0x1C75), product `536`/`8728`,
SysEx manufacturer ID `00 20 6B`, family `0200`, member `0900`, protocol `arturia_v2`,
`templateExtension: ".KeyStepPro"`, `memories: 16` (16 device project slots),
`minimalVersionRequired: 2.5.14`.

### How MCC itself is built (relevant constraints)

- MCC 1.23.0.134 is a **JUCE** app (not Qt), a single 24 MB Intel-only Mach-O with no bundled
  frameworks. It parses the device/project JSON with **Boost.PropertyTree** — which is exactly
  why the trailing commas are tolerated.
- `Info.plist` declares **no `CFBundleDocumentTypes` and no UTIs**. `.KeyStepPro` is not a
  registered document type; MCC never opens files via LaunchServices. Projects are discovered
  purely by **scanning `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/`**, which is
  world-writable, so the tool can drop files there with no elevation and no Finder integration.
  MCC appears to scan at launch, so expect to restart MCC (or refresh the browser) to see a new file.
- **MCC has MIDI-file *export* but no import path.** That is precisely the gap this tool fills.
- There is no CLI, AppleScript dictionary, or headless mode — the only `--` flags belong to the
  bundled software-updater subprocess. Automation must be file-level.
- `.kspf` firmware is a ZIP containing `info.json` + a DFU `.bin`; `libusb` in
  `/Library/Arturia/Shared/` is used only for firmware updates. Not relevant to project files.

> **Caveat:** both `KeyStepPro.json` and the `.KeyStepPro` project files contain **trailing
> commas** and are not strict JSON. `json.load` fails on both. Strip `,` before `}`/`]`
> (regex `,(\s*[}\]])` → `\1`) or use a lenient parser (JSON5).

---

## 2. File format

A `.KeyStepPro` file is a **single flat JSON object** — no nesting. Two string keys
(`"device": "KeyStepPro"`, `"version": "2.5.20"`) plus ~153,495 integer entries.

Key grammar:

```
<itemId>_<paramId>[_<idx1>][_<idx2>][_<idx3>]
```

**All structure is encoded in the key name.** Critically, all three sample projects plus the
factory default share an **identical set of 153,495 numeric keys**. The format is a
fixed-size dense dump: a converter never adds or removes keys, it only **overwrites values**.
That removes an entire class of risk the prior analysis worried about.

Two write-fidelity details that are easy to get wrong:

- Files are **tab-indented** JSON with a **trailing comma before the closing brace**.
- `Default.KeyStepPro` has 153,496 keys — it carries `"device"` but **no `"version"` key**.
  User-saved projects have 153,497 (they add `"version": "2.5.20"` right after `"device"`).
  A converter using the factory default as its baseline must **inject the `version` key**.

### Item IDs (from `bulkOperation[].bulkItemId`)

| Item ID | Meaning |
|---|---|
| `120` | Project / global (tempo, swing, ARP globals) |
| `121` | Scenes (16 scenes) — *not* the arpeggiator, as previously guessed |
| `122` | Control track (5 CC automation lanes) |
| `123` | **Track 1** (dual-natured: sequencer **and** drum) |
| `124` / `125` / `126` | **Tracks 2 / 3 / 4** (sequencer only) |

Track 1 is bigger than tracks 2–4 not because of a mystery "modulation lane" (the prior
analysis's guess) but because it carries **a complete second parameter set for DRUM mode**.

---

## 3. The parameter dictionary (validated)

`KeyStepPro.json` → `fields[]`. Each entry has an internal `id` and a `paramId`;
**the file keys use `paramId`.** The sequencer-relevant subset:

### Melodic / sequencer parameters

| paramId | Name (Arturia's own wording) | Indexed by |
|---|---|---|
| `48` | Step Seq step active | **step** 1–64 |
| `49` | Step Seq step skip | **step** 1–64 |
| `50` | Seq note corresponding step | **note** 1–64 |
| `109` | Seq note pitch | **note** |
| `110` | Seq note gate length | **note** |
| `111` | Seq note velocity | **note** |
| `112` | Seq note time shift | **note** |
| `113` | Seq note randomness | **note** |

### Drum parameters (Track 1 / item 123 only)

| paramId | Name | Indexed by |
|---|---|---|
| `51` | DRUM poly step count | step |
| `52` | DRUM step active | **packed bitmask**, 8 steps per index |
| `53` | DRUM step skip | **note** |
| `54` | DRUM step corresponding step | **note** |
| `117`–`121` | DRUM note pitch / gate / velocity / time shift / randomness | **note** |

### Per-pattern scalars

| paramId | Name |
|---|---|
| `97` / `114` | Pattern Seq / DRUM swing (%) — stored with **+25 offset** (±25% → 0…50) |
| `98` / `115` | Pattern Seq / DRUM step count — **0-based** (value 15 = 16 steps) |
| `99` / `116` | Bitfield: triplet, swing offset, polyrhythm, step size, playback direction |
| `100` | Bitfield: ARP/Drum mode, ARP type, ARP octave |
| `107` / `108` | Root note / scale |
| `40` | Pattern data state |
| `20`–`23`, `25`–`28` | Program Change (Seq / Drum) |

### Per-track / global

`39` track data state · `85`/`86` transposition & octave bitfields · `122` track transposition ·
`87` chord (16 per track) · `59`/`60` track seq/drum colour · `123` track MIDI channel ·
`70`–`72` project tempo (MSB/MidSB/LSB) · `74` global swing · `75` current scene.

Global device settings (CV/gate, MIDI channels, sync, drum map, knob assignments) live under
`deviceGlobalParametersId: 65` and are addressed by `globalParamId`, not by project keys.

---

## 4. The crucial structural insight: two index spaces

This is the thing that makes or breaks the converter, and the prior analysis missed it entirely.

Within one `(track, pattern, slot)`, the third index means **two different things depending on
the parameter**:

- **Step-indexed** (`48`, `49`): index = physical step position 1–64.
- **Note-indexed** (`50`, `109`–`113`): index = ordinal position in a **note list**, and
  `paramId 50` maps that note to its **0-based step**.

So the KeyStep Pro does **not** store a step grid of note data. It stores a *compact event list*
per slot, plus a separate per-step activity/skip array. Notes must be written **contiguously
from index 1** with no gaps.

The sentinel for "empty" is **`127`**. Note that `127` is also a legal velocity, so the
authoritative "does this note exist" test is **`paramId 50` (or `54` for drums) `!= 127`**,
never the velocity value.

`idx2` is the polyphony slot: **1–4 on Track 1, 1–3 on Tracks 2–4** (chord/poly voices).

---

## 5. Validation against ground truth

Decoded values were checked against the user's `analysis/project_5_description.txt`, which
documents settings confirmed on the physical hardware. Track 3 = item `125`, pattern 1:

| Documented | Decoded | ✓ |
|---|---|---|
| Notes C2, C#2, D | pitch `109` = 48, 49, 50 | ✓ |
| Velocities 60, 70, 90, 100 | `111` (by note) = 60, 70, 90, 100 | ✓ |
| Time shift +1…+4 then −1…−4 | `112` = 50,51,52,53 then 48,47,46,45 → **centre = 49** | ✓ |
| Randomness 10,20,30,40 / 100 | `113` = 10,20,30,40 / 100 | ✓ |
| Step skip "16,32,48,64" | `49` = 15 (4-bit mask over the four 16-step sequences) | ✓ |
| Step skip "16,48" / "32,64" | `49` = 5 (`0b0101`) / 10 (`0b1010`) | ✓ |
| Second D note plays on "48,64" | `49` at **step 13** = 12 (`0b1100`) | ✓ |
| Drum kick on beats 1 and 5 | `52` index 1 = 17 = `0b0001_0001` → bits 0 and 4 | ✓ |
| Kick velocities 127 / 50, randomness 80 / 90 | `119` = 127, 50; `121` = 80, 90 | ✓ |
| 16-step patterns | `98` = 15 (0-based) | ✓ |

Every documented value reproduces. The dictionary is trustworthy.

### The one unresolved encoding: gate length

Gate (`110` / `118`) is **not** linear. Observed (display → stored):
`0.5→7`, `1→11`, `2→19`, `3→27`, `3.5→29`, `4→31`.
It is `8·g + 3` up to gate 3, then compresses to ~`4·g` above it. Two independent captures
both gave `4 → 31`, so this is real, not a misreading. **This needs a dedicated sweep before
the converter can write gate lengths accurately** (see Verification).

---

## 6. Prior art

- Arturia's own FAQ confirms KeyStep Pro's data structure is **incompatible** with BeatStep Pro,
  so BeatStep Pro tooling cannot be reused.
- The only documented community MIDI-import workflow
  ([JonDent blog](https://djjondent.blogspot.com/2023/12/importing-midi-from-ableton-to-keystep.html))
  is **real-time recording** from a DAW into the hardware — arm record, play the clip. It is
  limited by pattern length and captures no per-step skip/randomness/time-shift data.
- The `arturia2midi` project cited by the prior analysis **could not be found**; treat that
  claim as unverified.

A file-level converter would therefore be genuinely new work, not a reimplementation.

### Optional future path: direct-to-hardware over SysEx

Worth recording, though **not recommended for v1**. MCC's `arturia_v2` protocol pushes projects
as an ack-per-chunk SysEx bulk stream inside an `F0 00 20 6B … F7` envelope (a canned frame in
the binary reads `f0 00 20 6b 7f 42 02 00 40 6a 31 f7`, where `42` is the KSP `productId` and
`0200` the `familyId`). The bulk stream is addressed by the tuple
`(bulkItemId…, paramId, valueId/index)` — **the same address tuple the file keys encode**, which
is why `bulkOperation` in the device JSON describes both. So a CoreMIDI direct-transfer path is
structurally feasible and would reuse the same model layer. However, the binary's strings do not
reveal the byte-level command layout beyond the envelope, so it would need real frame capture to
reverse. The file route requires none of that.

---

## 7. Deliverables (what this task actually produces)

Three markdown files. No code.

### 7.1 `analysis/KeyStepPro_File_Format_Analysis_deprecated.md`
The existing `analysis/KeyStepPro_File_Format_Analysis.md`, **renamed** (content preserved
verbatim as a record of the earlier reasoning) with a prominent banner added at the top:
superseded, do not build from this, see the new spec, and a one-line summary of what was wrong.

### 7.2 `analysis/KeyStepPro_Format_Spec.md` — the corrected reference
The authoritative format document. Contents drawn from §§1–6 above:
- where MCC's data lives, and the MCC build constraints (JUCE, no UTIs, Templates drop dir)
- file structure, key grammar, fixed key set, trailing-comma/tab/`version` write-fidelity rules
- item IDs 120–126
- the parameter dictionary, focused on the ~30 sequencer-relevant params, with the full
  205-field table pointed at in `KeyStepPro.json` rather than duplicated wholesale
- **the two index spaces** (step-indexed vs note-indexed) and the `127` sentinel rule
- the ground-truth validation table, presented as the method as well as the result
- gate length documented as an open question with its observed data points
- the `arturia_v2` SysEx envelope, recorded as a future direct-transfer path

### 7.3 `ROADMAP.md` — staged build plan
See §8. Every milestone is a testable artifact with standalone value.

### 7.4 `PLAN.md` — this document, in the repo
This plan currently lives outside the repo at
`/Users/cameronbauer/.claude/plans/investigate-the-midi-control-nifty-lovelace.md`, which is
scratch space. It gets written to the repo root as `PLAN.md` so the research findings, the
deliverable list and the roadmap rationale travel with the project rather than living in a
throwaway location.

Note: this originally recorded that the directory was not a git repository. That changed
mid-task — the repo was initialised and pushed to `github.com/bauerc/KeystepProTool` while the
deliverables were being written, and the deprecation rename was committed there directly. The
remaining docs therefore go through a branch and PR like normal.

---

## 8. Build roadmap (documented, not executed)

Ordering principle: **prove reading before writing, and get something audible early.** Export
to MIDI lands before import from MIDI — it is easier, independently useful, and it validates
our understanding of the format in a way you can *listen to* rather than merely diff.

| # | Milestone | Testable artifact | Why it has standalone value |
|---|---|---|---|
| **M1** | **Reader + dump** | `ksp-dump project_5.KeyStepPro` prints tracks → patterns → notes | Inspect any project file without MCC. Test: output must match `project_5_description.txt` and `project_9_tests.txt` exactly — these become the regression fixtures |
| **M2** | **KeyStepPro → MIDI export** | `.KeyStepPro` → `.mid` openable in any DAW | Immediately useful on its own: get hardware sequences into a DAW, which MCC cannot do. Test: convert, open, confirm it sounds/looks right |
| **M3** | **Byte-identical round-trip** | Load and re-emit `Default.KeyStepPro` unchanged, assert identical | Proves write fidelity (tabs, trailing comma, `version` key) before any real mutation. Pure desk test, no hardware |
| **M4** | **Targeted mutation** | Change one note in a real project, load in MCC, push to device | First write that touches hardware. Confirms our key addressing is genuinely correct end to end |
| **M5** | **MIDI → KeyStepPro (MVP)** | `midi2ksp in.mid -o out.KeyStepPro` — one track, one pattern, monophonic, default gate | **The core deliverable.** A 16-step MIDI clip becomes a playable pattern on the device |
| **M6** | **Full conversion** | Multi-track (1–4), polyphony slots, drum track, >64-step splitting, tempo/swing/step count | Handles real musical material rather than toy clips |
| **M7** | **Gate table** | Derived display→stored table from a hardware sweep | Unblocks accurate note durations. Needs ~10–15 exports from the physical device; pure data once captured |
| **M8** | **Distribution** | Signed, notarised artifact another KSP owner can run | Where the "other owners" audience is actually served |
| **M9** | **Native GUI** | Drag-and-drop macOS app writing into MCC's Templates dir | Removes the terminal from the workflow entirely |

**Stack, per §7 reasoning:** M1–M7 in Python (the format layer is where all the risk is, and
`mido` handles MIDI parsing free). M8–M9 in Swift, by which point the core is a proven,
mechanically translatable set of rules rather than a reverse-engineering problem. The roadmap
will state this explicitly, including the caveat that M5's CLI may prove sufficient and M9 may
never be worth building.

**Hardware dependency:** M1, M2, M3, M5 and M6 are pure desk work testable against the files
already in `project_files/`. Only M4, M7 and final M8/M9 validation need the KeyStep Pro present.

---

## Appendix: converter design notes (for whoever implements M1–M6)

### Approach: template-and-overwrite

Start from `Default.KeyStepPro` (or a user-supplied project), mutate values in place, write back.
Never synthesise the key set from scratch.

### Module breakdown

**`ksp/lenient_json.py`** — load/dump with trailing-comma tolerance. Must **re-emit the trailing
comma** on write, byte-compatible with MCC's own output, until we confirm MCC accepts strict JSON
(cheap to test; see Verification).

**`ksp/schema.py`** — parse `/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json`
at runtime to build the paramId → name/range map. Falls back to a vendored copy if MCC is not
installed. This keeps the tool honest against future MCC updates rather than hardcoding.

**`ksp/project.py`** — a `Project` wrapper over the flat dict exposing a sane object model:
`project.track(n).pattern(p).notes` etc. Handles:
- the step-indexed vs note-indexed split (§4),
- contiguous note-list packing with `127` fill for the tail,
- keeping `50`/`54` (note→step) consistent with `48`/`52` (step active),
- the drum bitmask packing for `52`.

**`ksp/midi_import.py`** — MIDI → project mapping:
- quantise MIDI note-ons to the pattern grid (step size from `99`/`116`; default 1/16),
- map MIDI channels/tracks → KSP tracks 1–4, patterns 1–16,
- distribute simultaneous notes across polyphony slots (max 3, or 4 on Track 1),
- MIDI velocity 0–127 → `111` directly (no 16-level quantisation — the prior analysis was wrong
  about that),
- note duration → gate, **pending the gate table** (§5); until resolved, default gate and warn,
- set `98`/`115` step count (0-based) from clip length; split clips >64 steps across patterns,
- write tempo into `70`/`71`/`72`.

**`ksp/cli.py`** — `midi2ksp in.mid -o out.KeyStepPro [--template T] [--track-map 1:1 2:3] [--pattern N]`.

### Constraints to respect
- 4 tracks × 16 patterns × 64 steps; 3 poly slots (4 on Track 1).
- Track 1 in DRUM mode uses params `51`–`54`/`117`–`121`; in SEQ mode it uses `48`–`50`/`109`–`113`.
  Mode is in the `100` bitfield — the converter must set it to match what it writes.
- Anything beyond 64 steps must be split across patterns and chained, not truncated silently.

---

### Verification techniques (map onto the M1–M7 milestones)

1. **Round-trip identity** — load `Default.KeyStepPro`, write it back unmodified, assert the
   output is byte-identical. This locks in formatting/trailing-comma fidelity before anything else.
2. **Regression against ground truth** — parse `project_files/project_5.KeyStepPro` and assert the
   decoded model matches `analysis/project_5_description.txt` (the table in §5 becomes the test
   fixture). Same for `project_9` against `project_9_tests.txt`.
3. **Gate-table sweep** *(needed before gate support ships)* — on the hardware, place one note and
   step its gate through every selectable value, exporting at each; build the display→stored table
   from the diffs. Roughly 10–15 captures.
4. **Strict-JSON tolerance test** — export one file without the trailing comma, import into MCC,
   confirm it loads. If it does, drop the comma-preservation requirement.
5. **End-to-end** — convert a simple 16-step MIDI clip, drop the result into
   `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/`, confirm it appears in MCC's
   Project Browser, push to the device, and verify on the hardware display.

Steps 1, 2 and 4 are pure desk work. Step 3 and the hardware half of step 5 need the KeyStep Pro
physically present.

---

## 9. Corrections to the existing `analysis/` document

**Decision: keep the old document, renamed to mark it dead.**
`analysis/KeyStepPro_File_Format_Analysis.md` →
`analysis/KeyStepPro_File_Format_Analysis_deprecated.md`, with a banner at the top pointing to
the new spec. It stays as a record of how the earlier conclusions were reached, but nothing
should be built from it — it is confidently wrong in ways that would break a converter:

| Prior claim | Reality |
|---|---|
| "MCC ships no readable KeyStep resource file" | `/Library/Arturia/.../Resources/KeyStepPro.json` is the full dictionary |
| `48`=tie, `49`=velocity, `50`=pitch | `48`=step active, `49`=step skip, `50`=note→step; pitch is `109` |
| Velocity stored as 16 discrete levels | Full 0–127, stored directly |
| Item `121` = arpeggiator/chord memory | Scenes |
| Track 1's extra params are a modulation lane | A complete DRUM-mode parameter set |
| All indices are `pattern_slot_step` | Two index spaces: step-indexed vs note-indexed |
| Risk of omitting required keys | Numeric key set is fixed at 153,495 and identical across all files |

---

## 10. Verifying this documentation task

Since the deliverable is documentation, "testing" means the claims are reproducible and
nothing was lost in the rename:

1. **Old doc preserved** — the deprecated file's body is byte-identical to the original apart
   from the added banner. Since there is no git history to diff against, verify by hashing the
   original's 178 lines before the rename and re-checking after. Nothing rewritten, nothing deleted.
2. **Every spec claim is reproducible** — each table in the spec traces to either
   `KeyStepPro.json` or a named key in `project_files/`. The §5 validation table is the
   strongest form of this: someone can re-derive it with a short script and get the same answer.
3. **No stale cross-references** — nothing in the repo still points at the old filename as
   authoritative.
4. **Roadmap milestones are independently checkable** — each M-row names an artifact and a test
   that can be run without having completed later milestones.

The spec deliberately marks gate length as unresolved rather than guessing. That honesty is
part of the deliverable: a converter built on an invented gate table would produce
plausible-looking files with wrong note durations.
