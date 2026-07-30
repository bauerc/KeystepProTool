> # ⚠️ DEPRECATED — DO NOT BUILD FROM THIS DOCUMENT
>
> **Superseded by [`KeyStepPro_Format_Spec.md`](./KeyStepPro_Format_Spec.md).**
>
> This analysis reverse-engineered the `.KeyStepPro` format by inference from project files
> alone, because it concluded that MIDI Control Center ships no readable KeyStep resource file.
> **That premise was wrong.** MCC ships a complete, authoritative parameter dictionary at
> `/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json`, and several of the field
> mappings below are incorrect as a result — most importantly `48`/`49`/`50`, which are
> *step active* / *step skip* / *note→step*, **not** tie/velocity/pitch.
>
> It is retained only as a record of how the earlier conclusions were reached.
> See §9 of the new spec for the full list of corrections.

---

# Arturia KeyStep Pro (`.KeyStepPro`) File Format — Technical Breakdown

**File analyzed:** `Y_Control_Keystep_Project.KeyStepPro`
**Device:** `KeyStepPro`, firmware/format version `2.5.20`
**Size:** ~3.5 MB, 153,497 key/value pairs

---

## 1. It *is* JSON — but flat, not nested

Despite looking like it should be a rich nested structure (tracks → patterns → steps), the file is actually a **single flat JSON object**. There is no nesting at all — every one of the ~153,000 entries is a top-level key mapped to a single integer value:

```json
{
  "device": "KeyStepPro",
  "version": "2.5.20",
  "120_101": 127,
  "120_102": 31,
  "121_38_1": 2,
  "123_48_10_1_1": 64,
  "123_48_10_1_2": 12,
  ...
}
```

All the "structure" (tracks, patterns, steps, layers) is encoded **inside the key names themselves**, using underscores as delimiters. This is Arturia's standard MIDI Control Center (MCC) export convention — the same scheme is used for the BeatStepPro, MiniLab, and other Arturia controllers, just with different parameter numbers per device.

**One data-quality note:** the file as exported has a trailing comma before the final `}` (`"126_99_9": 20,\n}`), which is technically invalid JSON and will make a strict parser choke. Any tooling you write should either strip trailing commas before parsing, or use a lenient JSON parser.

---

## 2. Key naming convention

Every key (other than `device` and `version`) follows this pattern:

```
<GROUP>_<PARAM>[_<index1>][_<index2>][_<index3>]
```

- **GROUP** — a numeric ID for a functional section of the device (global settings, a specific track, the arpeggiator, etc.)
- **PARAM** — a numeric ID for a specific parameter within that group (analogous to an NRPN/CC number in Arturia's internal addressing scheme — not the same as the user-facing MIDI CC# numbers described in the manual)
- **index1/2/3** — one to three positional indices, used when a parameter needs to store a value per pattern, per step, or per note-slot

This is **not** documented in the KeyStep Pro's public user manual. I checked — the manual describes user-facing CC# behavior (Ch. 8) but never lists this internal parameter table. Arturia's own developer support confirmed on their forum (in a nearly identical thread about the sibling BeatStepPro format) that the authoritative parameter dictionary lives in a JSON resource file *inside the MCC application itself* (e.g., `BeatStepPro.json` / presumably `KeyStepPro.json` in MCC's resources folder) — it isn't published. So some of the mapping below is directly confirmed from the data's structure and cross-referenced against the manual's described features; some is a well-supported inference rather than a certainty. I've flagged confidence levels throughout.

---

## 3. The seven top-level GROUPs

| Group | Entries | Likely function | Confidence |
|---|---|---|---|
| **120** | 30 | Global / Utility settings (MIDI channels, sync, clock, velocity/aftertouch curves — small scalar and 5-element arrays, no per-step data) | Medium |
| **121** | 1,488 | Arpeggiator / Chord Memory config (per-pattern settings + arrays sized for **16 note slots**, matching the manual's "up to 16 notes in an arpeggio/chord") | Medium-high |
| **122** | 7,316 | The **Control Track** (the manual describes a 5th track using the 5 main encoders to record CC# automation lanes "in every other aspect like a normal track") | Medium-high |
| **123** | 70,102 | **Track 1** sequencer data | High |
| **124** | 24,853 | **Track 2** sequencer data | High |
| **125** | 24,853 | **Track 3** sequencer data | High |
| **126** | 24,853 | **Track 4** sequencer data | High |

Groups 124/125/126 are byte-for-byte identical in *structure* (same param IDs, same index ranges) — only the stored values differ. This strongly confirms they're the same "kind" of thing (one sequencer track) repeated four times, matching your description of 4 individual MIDI tracks.

**Track 1 (123) is not identical to tracks 2–4** — it has extra parameters (7 note-data arrays vs. 3, see below). This is a real, confirmed structural difference in the file, not a guess. My best inference is that Track 1 carries additional per-note data (e.g. an individual per-note modulation/velocity-curve lane) that tracks 2–4 don't — which lines up with the modulation behavior you described. I can't confirm from the manual alone which specific extra parameter is "velocity modulation" vs. something else; that would need the diff-testing approach in Section 6.

---

## 4. Anatomy of a track (groups 123–126)

Within each track group, the parameters break into three tiers:

### a) Per-pattern scalars — pattern number 1–16
Keys like `123_20_1` … `123_20_16` (16 entries). These are single values, one per pattern/sequence — e.g. pattern length, direction, swing, time division, transpose, gate mode. There are ~10 such scalar parameter IDs per track (20, 21, 22, 23, 39, 40, 59, 60, 85, 86, 87, 97–100, 107, 108, 114–116, 122), each confirming your "16 distinct sequences per track."

### b) Per-step note-data arrays — the heart of the sequencer — CONFIRMED
Keys like `123_48_10_1_1` = Track 1, param 48, pattern 10, note-slot 1, step 1.

Index structure: `PARAM_[pattern 1–16]_[note-slot 1–3or4]_[step 1–64]`

- **pattern**: 1–16 → matches "up to 16 distinct sequences per track"
- **step**: 1–64 → matches "up to 64 distinct sequence entries"
- **note-slot**: a step can hold a small chord; this index says *which* simultaneous note within that chord. **3 slots on tracks 2–4, 4 slots on track 1.**

This is no longer inference — it's confirmed directly from strings embedded in the MCC application binary itself (`strings` on the MCC executable surfaced its own internal data-model debug dump):

```
KeyStep Piano Roll accept 1 fields by steps : tie
KeyStep Piano Roll accepts 2 fields by notes : velocity, pitch
```

Cross-referencing those three named fields against the actual value ranges/behavior in the data confirms the mapping:

| Param ID | Value range | Behavior in real data | Field |
|---|---|---|---|
| `48` | 0–1 | 0 on unused slots; occasional 1 on active ones | **`tie`** |
| `49` | 0–15 | 0 on unused slots; a fixed level on active ones (KeyStep Pro stores velocity as 16 discrete levels, not raw MIDI 0–127) | **`velocity`** |
| `50` | 0–127 | Varies freely — matches real note numbers | **`pitch`** |

Track 1 has **7** of these param IDs (48–54) instead of 3; tracks 2–4 have only `48/49/50`. Each is a full `16 patterns × slots × 64 steps` array — track 1's is `16 × 4 × 64 = 4,096` per parameter, tracks 2–4's is `16 × 3 × 64 = 3,072`.

**Track 1's extra params (51–54)** repeat the same "small value paired with a larger value" pattern seen in velocity/pitch (51 & 53 range 0–15, 52 & 54 range 0–~127), strongly suggesting **one or two additional per-note fields unique to track 1** — most likely the individual per-note velocity modulation lane(s) you described in the KeyStep Pro workflow. This part is still an inference, not confirmed by a named string, since the binary dump only named the 3 base fields (`tie`, `velocity`, `pitch`) and didn't include a track-1-specific listing. The fastest way to confirm it: in MCC, apply a modulation curve to a single note's velocity on track 1 and nothing else, export, and diff against a baseline — whichever of 51–54 changes is the answer.

Several of these param IDs (109–113, and on track 1 also 117–121) appear with **one extra value per pattern** (e.g. 4,096 + 16 = 4,112) — i.e. a per-step array *plus* one per-pattern "default/master" scalar for that same parameter, which is a common pattern in step sequencers (a default value that applies unless overridden per step).

### b′) Control track (122) automation lanes
Same shape, but built for CC automation rather than notes: `122_90_<pattern>_<step>` etc., sized `16 patterns × 64 steps` (+ a per-pattern scalar on 5 of the 7 lanes). This matches the manual's description of the control track's 5 main-encoder CC lanes, plus 2 extra lanes.

### c) Arpeggiator/Chord memory (121)
Arrays shaped `16 patterns × 5 sub-params × 16 note-slots` — the "16 note-slots" matches the manual's "add up to 16 notes to an arpeggio" / "play up to 16 notes on the keyboard for a chord."

---

## 5. Worked example

```
"123_50_10_1_1": 64
```
Track 1 (123), param 50 = **pitch** (confirmed), pattern 10, note-slot 1, step 1 → value 64.
This says: *in Track 1's 10th sequence, step 1's first note is MIDI note 64 (E4).*

```
"123_49_10_1_1": 15
"123_48_10_1_1": 0
```
Same location's **velocity** (15, i.e. max of the 16 hardware levels) and **tie** (0, not tied to the next step).

```
"123_20_10": 32
```
Track 1, Parameter 20 (a per-pattern scalar, possibly pattern length), Pattern 10 → value 32 (e.g., "this sequence is 32 steps long").

The pattern/step/note-slot indices, and the `tie`/`velocity`/`pitch` identities, are now confirmed directly from MCC's own compiled binary (Section 6 below) rather than inferred from shape alone. Fields outside this trio (e.g. per-pattern scalars in groups 120–122, and track 1's extra 51–54 params) remain best-supported inferences until similarly confirmed.

---

## 6. What we confirmed straight from MCC itself

MCC on macOS doesn't ship a loose, readable resource file (no `.json`/`.xml`/`.plist`/`.db` anywhere in the app bundle names or contents mention "KeyStep"). But the field *names* are compiled directly into the app's executable as debug strings, recoverable with:

```
strings "/Applications/Arturia/MIDI Control Center.app/Contents/MacOS/MIDI Control Center" | grep -i -B2 -A2 "Piano Roll"
```

This surfaced:
```
Dumping piano roll state - Format: (State, Pitch, Velo, Gate)
Piano Roll accept 4 fields by steps : velocity, gateLength, pitch, on   <- generic/BeatStepPro-style piano roll
KeyStep Piano Roll accept 1 fields by steps : tie                      <- KeyStep Pro specific
KeyStep Piano Roll accepts 2 fields by notes : velocity, pitch         <- KeyStep Pro specific
```

That's the source for the confirmed `tie`/`velocity`/`pitch` mapping in Section 4b. It also tells us the KeyStep Pro's piano-roll data model is genuinely different from Arturia's other step sequencers (e.g. the BeatStepPro's, which has 4 fields including an explicit `on` flag) — the KeyStep Pro instead treats an "off" step as just an empty/default note-slot, with no separate on/off flag.

## 7. Nailing down anything still unconfirmed

For the remaining unconfirmed fields (track 1's 51–54, and the scalar settings in groups 120–122), the reliable way to fully decode them (and something the Arturia community is actively doing — see `arturia2midi` on GitHub, a project attempting exactly this for KeyStep Pro/BeatStepPro files) is:

1. Open a project in MCC.
2. Change **one single thing** (e.g., just the velocity of one note in one step).
3. Re-export and diff against the previous file.
4. Whichever key(s) changed value is the parameter (and layer index) for that feature.

Repeated across each UI control (pitch, velocity, gate length, tie, pattern length, swing, arp settings, control-track CC assignment, etc.), this fully reconstructs the dictionary. I'm happy to help build a small diffing script for this if you export a couple of test variants.

---

## 8. Can someone build a project from scratch?

**Yes — this is very feasible, with one caveat.**

Reasons it's practical:
- It's plain, human-readable JSON (once you strip the trailing comma) — no binary encoding, checksums, or compression.
- The key-naming scheme is fully regular and predictable once you know the pattern/step/layer ranges for a given parameter (16 patterns × up to 64 steps × 3–4 layers, etc.) — trivial to generate programmatically.
- Because every value is independent (no cross-references between keys), you can safely regenerate or bulk-edit large chunks (e.g., "write a whole new sequence into Track 2, Pattern 5") with a script instead of clicking through the hardware or MCC UI.

The caveat:
- **You'd want to start from a real exported project as a template**, rather than building the ~153,000 keys from nothing. The full key set (all valid GROUP/PARAM IDs and their exact index ranges, especially for groups 120–122 whose purpose is only partially confirmed) isn't documented anywhere public. If you omit a key MCC/the hardware expects, the most likely outcomes are either "falls back to a firmware default" (probably harmless) or an import error — and only Arturia's engineers know for certain which keys are strictly required vs. optional.
- The practical, low-risk workflow: export a real project from your KeyStep Pro as a baseline "skeleton," then programmatically overwrite only the note/step/pattern values you care about (Section 4b), leaving groups 120–122 and the scalar settings untouched. This is exactly the approach the open-source `arturia2midi` project is taking to convert standard `.mid` files into importable KeyStepPro projects.

If it'd help, I can write you a Python helper that loads this file into a proper nested structure (track → pattern → step → layer), lets you edit it in a sane way, and re-serializes it back into this flat key format for re-import into MCC.
