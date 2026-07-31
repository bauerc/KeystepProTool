# KeyStep Pro hardware capture protocol

**Purpose:** resolve the format questions that cannot be answered from files already on disk, by
setting known values on the device, exporting them, and diffing.

**Audience:** a human at the device, and an agent re-reading this later to interpret the captures.

**Companion documents:**
[`Format_Corrections_Issue.md`](./Format_Corrections_Issue.md) — read its summary table before
starting. [`Capture_Ledger_Gaps.md`](./Capture_Ledger_Gaps.md) — the handful of displayed values
and device behaviours from the completed captures that were never written down.

> **This document contains only unfinished work.** B0 and tiers 1, 3 and 4 have been run (18
> captures, in `project_files/captures/`, which is gitignored). Their procedures have been
> **deleted** from this file so that everything still here is something to do. What they found is
> in [`KeyStepPro_Format_Spec.md`](./KeyStepPro_Format_Spec.md), which is the authoritative
> record — not here.
>
> Briefly, so nobody re-runs them: drum mode is `86` bit 6 and `100` never moves; a pooled note
> whose step-active bit is clear does not sound; `idx2` is a 64-entry pool chunk rather than a
> polyphony voice, with a hardware-enforced 192-event ceiling; `52` is a lane-major 7-bit array;
> `40` and `39` latch; and two untouched exports are byte-identical.

**The baseline every test below starts from** is `B0-baseline.KeyStepPro` — an initialised,
untouched project, already captured. Where a test says "from the baseline", start by loading or
re-initialising to that state; do not re-derive it.

**What is genuinely unknown and needs the device:**

| Question | Blocks | Tier |
|---|---|---|
| The gate length table (`110` / `118`) | M7, and correct note durations in M5/M6 | 2 |
| Whether melodic step-off behaves like drum step-off | M5/M6 export correctness | 4 |
| Whether a melodic pool spills into slot 2 like a drum pool | M6 | 4 |
| The `99` / `116` bitfield layout | M6 | 5 |
| Pattern chaining beyond 64 steps (`84`) | M6 | 5 |
| Time Shift range and linearity (`112` / `120`) | M7; whether shift is usable at all | 7 |
| Which parameter governs effective swing (`74` / `97` / `114`) | M7, and `reader._swing` may be wrong | 7 |
| Whether `113` randomness is probability or timing jitter | the validity of every timing measurement | 7 |
| What one Time Shift unit is worth in time | M2's grid-quantise warning, M5's quantiser | 8 |

The last four are the subject of [`Timing_Calibration.md`](./Timing_Calibration.md), which carries
the model and the arithmetic; tiers 7 and 8 below are the captures that feed it.

---

## How to run a capture

Every test below is one capture. A capture is:

1. **Start from a known state.** Either a freshly initialised project, or the immediately
   preceding capture in the same tier — each test says which. Never start from an unknown state.
2. **Change exactly one thing.** One parameter, one note, one setting.
3. **Read the device display and write down what it says.** The stored value is what we are
   trying to learn, so the *displayed* value is the ground truth and only exists in your notes.
   This is the step that cannot be recovered later.
4. **Export.** Same route you used to produce `project_5.KeyStepPro`: sync the project from the
   KeyStep Pro into MIDI Control Center, then save it out of MCC as a `.KeyStepPro` file. Write
   the route down in the ledger the first time so it is reproducible.
5. **Save it as** `project_files/captures/<test-id>.KeyStepPro`, using the test ID verbatim.
6. **Log it** in the ledger at the bottom of this file: test ID, displayed value, date, anything
   that felt off.

### Rules

- **One change per capture.** A capture containing more than one deliberate change is discarded,
  not interpreted. Two changes make the diff ambiguous and there is no way to tell afterwards.
- **Do not touch anything else** — not the tempo, not the transport, not another track. Every
  key that moves is a signal, and unrelated changes bury the one you want.
- **If you lose track of what you changed, discard and redo.** A wrong entry in the table is worse
  than a missing one, because it will be believed.
- **Use untouched patterns** for new tests, the way `project_9` does. A pattern with history in it
  carries stale pool entries that make diffs noisier.
- Captures are data, not source. Once written they get the same treatment as
  `project_files/*.KeyStepPro` — never reformatted, re-indented, or given a final newline.

### Diffing

No tooling needs to exist first. This is enough:

```python
# uv run python - <<'EOF'
from ksp import lenient_json

BASE = "project_files/captures/B0-baseline.KeyStepPro"
CAP  = "project_files/captures/T2-gate-04.KeyStepPro"

a = lenient_json.load_path(BASE)
b = lenient_json.load_path(CAP)

for k in sorted(a.keys() | b.keys(), key=lambda s: [int(p) if p.isdigit() else p
                                                    for p in s.split("_")]):
    va, vb = a.get(k), b.get(k)
    if va != vb:
        print(f"{k:24s} {va!r:>8} -> {vb!r}")
# EOF
```

A clean single-parameter capture should print a handful of lines. If it prints hundreds, either
more changed than you intended or you are diffing against the wrong baseline.

A `ksp-diff` command would be a natural by-product of M4 and would make tiers 3–5 much faster to
read, but nothing here waits on it.

### Per-test format

Each test states: **what it resolves · device steps · capture name · keys to diff · what confirms
the current assumption · what falsifies it · what to do if falsified.**

---

## Tier 2 — M7, the gate length table

**~20 captures.** The long pole, and the only tier that is pure lookup data. Spec §6 has six
hardware-confirmed points and explicitly warns against inventing a formula for the rest, because
a wrong table produces files that load fine and play with wrong note durations, with nothing to
signal the error.

| Displayed | Stored |
|---|---|
| 0.5 | 7 |
| 1 | 11 |
| 2 | 19 |
| 3 | 27 |
| 3.5 | 29 |
| 4 | 31 |

Below 3 this fits `stored = 8·g + 3`; above 3 it compresses to roughly `4·g`. Two independent
captures gave `4 → 31`, so the break is real. `initial_project` also contains a stored `2`, which
is *below* the 0.5 point — so the range extends further down than any documented capture reaches.

### T2.1–T2.n — Melodic gate sweep

- **Resolves:** the full `110` table.
- **Device:** from the baseline. Track 2, pattern 1. Place one note at beat 1, any pitch. Then step Gate
  from its **minimum to its maximum, one detent at a time**, exporting at every single value.
  Change nothing else, ever.
- **Capture:** `T2-gate-<display>.KeyStepPro`, where `<display>` is the displayed value with the
  decimal point replaced by `p` — `T2-gate-0p5`, `T2-gate-1`, `T2-gate-3p5`. If the display shows
  something non-numeric at the extremes (e.g. a tie or hold indication), name it literally:
  `T2-gate-tie`.
- **Diff against:** the previous capture in the sweep.
- **Keys:** `124_110_1_1_1` only.
- **Confirms if:** exactly one key moves per capture, and the six known points reproduce. Those
  six are a built-in check that the procedure is being followed — **if a known point disagrees,
  stop and re-read the display rather than recording it.**
- **Falsified if:** two displayed values map to one stored value, or the sequence is not monotonic.
- **If falsified:** capture both directions (sweep up, then down) — a non-monotonic or
  hysteretic encoder reading is a different problem from a non-linear table, and the fix is
  different.
- **Note the count.** However many detents there are is how many captures this is. Record the
  minimum and maximum displayed values in the ledger; the range itself is currently unknown, and
  the stored `2` in `initial_project` says the bottom is lower than 0.5.

### T2.x — Where does the stored `2` come from?

- **Resolves:** the one unmeasured value that exists in real user material.
  `initial_project` Track 1 pattern 1 has a drum note with `118` = 2, which `ksp-dump` prints as
  `?(2)`.
- **Device:** during the sweep, when the stored value reaches 2, note the displayed value.
- **Confirms if:** 2 appears in the sweep at all.
- **If it does not appear:** 2 may only be reachable on the drum track, or via a control other
  than the Gate encoder (a tie, a very short trigger). Try T2.y before concluding it is unreachable.

### T2.y — Drum gate spot-check

- **Resolves:** whether `118` (drum) uses the same table as `110` (melodic), or a different one.
  Nothing currently establishes this — spec §6 assumes one table for both.
- **Device:** from the baseline. Track 1 in drum mode, an untouched pattern. Place a Kick at beat 1. Set
  Gate to each of **0.5, 1, 2, 4** and the minimum, exporting at each. Five captures.
- **Capture:** `T2-drumgate-<display>.KeyStepPro`
- **Keys:** `123_118_<pattern>_1_1`
- **Confirms if:** the stored values match the melodic table at the same displayed values.
- **Falsified if:** they differ at any point.
- **If falsified:** the drum table needs its own full sweep — repeat T2.1–T2.n on the drum track.
  Budget another ~20 captures. Better to discover this from five captures than after writing the
  converter.

---

## Tier 4 — M6, step-active semantics on the melodic side

**3 captures.** D1–D4 are done and removed; what they established is in spec §4. Both tests here
extend those drum results to the melodic parameter set, which nothing has measured.

**T4.5 is the highest-value remaining capture in this document** — not because it is likely to
surprise, but because shipped code already assumes its answer.

### T4.5 — Melodic step-off ⬜ not yet run

**3 captures.** The melodic counterpart to D1, which tested drums only.

- **Resolves:** whether `48` behaves like `52` — i.e. whether a melodic note left in the pool
  with its step-active flag clear is silent. The reader and MIDI export now drop such notes on
  *both* parameter sets, but only the drum half is measured. The melodic half rests on D1 plus
  the fact that `48` and the note list agree in every file we have, which is suggestive, not
  proof.
- **Device:** from the baseline. Track 2, pattern 1. Place notes at **beat 1** and **beat 5**, export.
  Then **toggle step 5 off without deleting the note** — the same control D1 used, not a clear —
  export. **Then listen: play the pattern and note whether beat 5 sounds.**
- **Captures:** `T4-melodic-two-notes.KeyStepPro`, `T4-melodic-step-off.KeyStepPro`
- **Keys:** `124_48_1_1_5`, and `124_50_1_1_<1..2>` plus `124_109_1_1_<1..2>` to show the pool
  is untouched
- **Confirms if:** `124_48_1_1_5` goes 1 → 0, the pool entry survives unchanged, and beat 5
  does not sound — exactly D1's shape.
- **Falsified if:** the pool entry is cleared alongside the flag (then melodic deletion and
  deactivation are the same operation), or the note still sounds with its flag clear.
- **If falsified:** `ExportOptions.include_inactive` must stop applying to melodic notes, and
  the reader's melodic `active` decode becomes informational only.

### T4.6 — Melodic pool overflow ⬜ not yet run

**1 capture.** D3 established that a *drum* pool spills into chunk 2 at 64 events. Nothing shows
that a melodic one does, and no sample file has more than 64 melodic notes in a pattern.

- **Resolves:** whether melodic notes chunk the way drum notes do, and — the part that matters
  for code — **whether `48` stays wholly in slot 1 or follows the chunking**. The reader
  currently reads melodic step-active from slot 1 only and treats it as pattern-wide; that is
  the one assumption in the change with no capture behind it.
- **Device:** from the baseline. Track 2, pattern 1, 64 steps. Enter **more than 64 notes** — chords on
  every step is the fastest route. Export. Note whether the device refuses any, and at what count.
- **Capture:** `T4-melodic-overflow.KeyStepPro`
- **Keys:** `124_50_1_2_*` and `124_109_1_2_*` (did the pool spill?), `124_48_1_1_*` and
  `124_48_1_2_*` (did the flags spill?)
- **Confirms if:** events past 64 appear in slot 2, and `124_48_1_2_*` stays all-zero with every
  flag still in slot 1.
- **Falsified if:** `48` slot 2 is populated — then step-active is chunked alongside the pool and
  the reader must read all chunks, not just the first.
- **Also record the ceiling.** If the device errors, note the number and whether it matches the
  192 that D3 produced for drums.

---

## Tier 5 — M6, pattern scalars

**~12 captures.** Lower value per capture than tiers 2–4, but these are the settings that make a
converted pattern *sound* like the source material rather than merely contain the right notes.

### T5.1–T5.5 — The `99` bitfield

`99` is "Pattern Seq triplet state, swing offset state, polyrythm state, step size, playback
direction in a bitfield", with the dictionary's own comment placing **playback direction at bits
5–6**. Everything else is unallocated guesswork.

Known values: `Default.KeyStepPro` holds `99` = **20** (`0b0010100`) on every pattern, and
`116` (the drum equivalent) holds **16** (`0b0010000`). `initial_project` has `99` = 16 on Track 1
pattern 1 and Track 3 pattern 1, and 20 elsewhere — so bit 2 (value 4) is the one that varies in
real material. Note the seq and drum defaults already differ by exactly that bit.

- **Device:** from the baseline, Track 2 pattern 1. Change **one field at a time**, returning to default
  between captures: step size, triplet on, polyrhythm on, swing offset on, playback direction
  through each of its settings.
- **Captures:** `T5-99-stepsize-<value>`, `T5-99-triplet`, `T5-99-polyrhythm`,
  `T5-99-swingoffset`, `T5-99-direction-<name>`
- **Keys:** `124_99_1`
- **Confirms if:** playback direction occupies bits 5–6, and each other field maps to a
  contiguous bit range that accounts for the observed defaults of 20 and 16.
- **Falsified if:** direction is elsewhere, or two fields share a bit.
- **Record the displayed setting name for every capture** — the mapping from stored bits to the
  device's own labels is the deliverable, and it cannot be reconstructed from the file.
- **Step size needs one capture per setting**, not one total, since it is a multi-bit field.
- **Then repeat one capture on the drum side** (`116`, `123_116_<pattern>`) to check the layout is
  shared. If seq and drum differ, both need sweeping.

### T5.6 — Root note and scale

- **Resolves:** `107` (root note) and `108` (scale), which are 0 in every sample file, and the
  user-scale parameters `101`–`106`.
- **Device:** from the baseline. Set a non-default root note, export. Set a non-default scale, export.
- **Captures:** `T5-rootnote`, `T5-scale`
- **Keys:** `124_107_1`, `124_108_1`
- **Confirms if:** each moves independently and the scale value indexes the device's scale list in
  display order.
- **Record the full scale list in display order** if you can page through it — that turns `108`
  into pure lookup data, like the gate table.

### T5.7 — Pattern chaining

- **Resolves:** how patterns chain, which is the mechanism M6 needs for source material longer
  than 64 steps. Scene parameter `84` is documented as "16 pattern in a chain (value between 0 and
  15 if defined, otherwise 127)" and reads **127 across all 16 entries of all 5 tracks in every
  sample file** — so no sample has ever used a chain.
- **Device:** from the baseline. Build a chain of **3 patterns** on Track 2 within scene 1. Export.
- **Capture:** `T5-chain-3.KeyStepPro`
- **Keys:** `121_84_1_2_<1..16>` (scene 1, track 2), and `121_83_*` (current pattern per track)
- **Confirms if:** the first three entries hold 0-based pattern numbers and the rest stay 127.
- **Falsified if:** the chain lands somewhere else, or the ordering is not what the display shows.
- **Note the track index mapping.** `121_84_<scene>_<track>_*` uses track index 5 for the Control
  track and 1–4 for the sequencer tracks, per the descriptors — worth confirming, since it is the
  one place the item ordering is not the obvious one.

### T5.8 — What the four step-skip sequences are

- **Resolves:** whether 16 / 32 / 48 / 64 are four **repeats** of a pattern shorter than 64 steps
  or four **pages** of a 64-step one. This blocks `ksp2midi --passes` (issue #22), which cannot be
  written until it is known, and it is the same question for `midi2ksp` in reverse.
- **Why it is open:** spec §5 calls them "four consecutive 16-step sequences", which reads like
  pages — but `project_5` pattern 1 is 16 steps long and carries notes masked to 48 and 64
  (`49` = 5 and 12). Under the pages reading those notes could never sound, which contradicts a
  hardware-confirmed description. Under the repeats reading every mask is meaningful at any
  pattern length. The file cannot settle it; only the device can.
- **Device:** from the baseline. Track 2, pattern 1, length **16 steps**. Four notes at beats 1, 5, 9, 13
  on four different pitches. Set their skip masks to 16-only, 32-only, 48-only and 64-only
  respectively. Export, then **play the pattern and listen through at least eight loops**.
- **Capture:** `T5-skip-16step.KeyStepPro`
- **Keys:** `124_49_1_1_<1..16>` (step-indexed, unlike the drum `53`)
- **Confirms repeats if:** the four notes sound on successive loops in turn — beat 1 only on
  loop 1, beat 5 only on loop 2, and so on, cycling every four loops.
- **Confirms pages if:** only the 16-masked note ever sounds and the other three are silent, or
  the device refuses to set a mask above 16 on a 16-step pattern at all.
- **Then repeat at 64 steps.** Set the pattern to 64 steps with one note per 16-step quarter, each
  masked to a *different* sequence than the quarter it sits in. Under repeats it plays all four
  over four loops; under pages three of them never sound. This is the case that separates the
  readings when the pattern is long enough for both to be coherent.
- **Also note the display.** Whatever the device calls the setting is worth transcribing verbatim —
  the vocabulary usually gives the model away.

---

## Tier 6 — Re-checks

**2 captures.** Cheap, and each removes a standing caveat.

### T6.1 — The `project_5` drum time-shift conflict

- **Resolves:** the one documented discrepancy in the corpus.
  `analysis/project_5_description.txt` states Time Shift **−1 for both kick hits**;
  `project_5.KeyStepPro` stores `120` = 48 and 50, which decode to **−1 and +1** against the
  centre of 49. The melodic ramp in the same project independently confirms the centre is 49, so
  a transcription slip is the likelier explanation — but nobody has looked at the device since.
- **Device:** load `project_5` on the KeyStep Pro. Read the Time Shift of both kick hits off the
  display. **This is a read, not a capture** — no export needed unless the values disagree with
  the file.
- **Confirms if:** the display shows −1 and +1, i.e. the description has a typo.
- **Falsified if:** the display shows −1 and −1, i.e. time shift does not decode the way we think
  on the drum track specifically.
- **If falsified:** drum time shift (`120`) needs its own sweep — it may not share the melodic
  centre of 49. **T7.3 is that sweep**, and it covers the full range rather than assuming ±4 is it;
  run T7.3 rather than improvising captures here.
- Either way, update `tests/fixtures/project_5.expected.json`, which currently asserts the
  conflict deliberately so it cannot quietly disappear.

### T6.2 — Is the trailing comma required?

- **Resolves:** a standing write-fidelity requirement. `.KeyStepPro` files have a trailing comma
  before the closing brace, which is why `json.loads` rejects them. MCC parses with
  Boost.PropertyTree, which tolerates it — but nothing establishes that it *requires* it.
- **Device:** none. This is a desk test, listed here because it belongs with the other
  MCC-behaviour checks.
- **Method:** take `user_empty_project.KeyStepPro`, remove the trailing comma, leave everything
  else byte-identical, drop it in
  `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/`, restart MCC, and see whether it
  appears in the Project Browser and loads.
- **Confirms if:** it loads. Then comma preservation can be dropped from the M3 requirements
  permanently.
- **Falsified if:** it does not appear or fails to load. Then the comma is mandatory and M3's
  byte-identical round-trip is the right target rather than a nicety.
- **Do this before M3**, not after — it decides what M3 is trying to prove.

---

## Tier 7 — Time Shift and Swing encodings

**~13 captures.** Ordinary export-and-diff captures, same workflow as every tier above. These
resolve what the *stored* values mean; Tier 8 resolves what they are worth in time. Background and
the model are in [`Timing_Calibration.md`](./Timing_Calibration.md).

Two things make this tier necessary. **Time Shift has never been swept** — the only non-default
values in the whole corpus are `project_5`'s ±1…±4 ramp, so the range is unknown and T6.1's
fallback branch merely *assumes* ±4. And **swing has never been set at all**: `74` reads 50 and
`97` / `114` read 25 in all 16 patterns of all four tracks of all five sample files, so there is
zero observational data on it.

> **Set swing to 0 for the whole of T7.1–T7.3, and place shift test notes on odd-numbered steps
> (1, 3, 5 …).** Swing displaces even-numbered steps, so a stray swing setting cannot contaminate
> the shift captures if the notes sit where swing does not reach.

### T7.1 — Time Shift range

- **Resolves:** `D_min` and `D_max`. **Run this first** — it decides whether the rest of the tier is
  worth doing. If the range is only ±4, Time Shift spans roughly ±4 % of a step and is useless as a
  quantization target, so M5 would snap to the grid and report the loss instead of pretending to
  represent it. If it is ±49, shift covers the entire gap between steps.
- **Device:** from the baseline. Track 2, pattern 1. Place one note at beat 1. Turn Time Shift **all the way
  down** until the display stops moving, export. Then **all the way up**, export.
- **Captures:** `T7-shift-min.KeyStepPro`, `T7-shift-max.KeyStepPro`
- **Diff against:** `T1-note-place.KeyStepPro` (or the baseline plus the note)
- **Keys:** `124_112_1_1_1` only
- **Confirms if:** exactly one key moves per capture, and the two stored values sit symmetrically
  about 49.
- **Falsified if:** the range is asymmetric about 49, or the stored value leaves 0–127.
- **Record the displayed value at both extremes.** That is the deliverable — the stored number is
  in the file, the displayed one exists only in your notes.

### T7.2 — Time Shift linearity

- **Resolves:** whether display → stored stays 1:1 across the whole range, which is only known
  today over `project_5`'s ±4 window.
- **Device:** from the baseline. Track 2, pattern 1. Place notes on **steps 1, 3, 5, 7, 9, 11, 13** and set
  each to a different Time Shift spread across the range found in T7.1 — both extremes, both
  half-way points, ±1, and 0. One capture holds the whole curve.
- **Capture:** `T7-shift-linearity.KeyStepPro`
- **Keys:** `124_112_1_1_<1..7>`, and `124_50_1_1_<1..7>` to confirm which note is on which step
- **Confirms if:** stored = 49 + displayed at every point.
- **Falsified if:** the mapping compresses at the extremes, the way gate does above 3.0.
- **If falsified:** it becomes lookup data like the gate table. Sweep every detent and record the
  full mapping — **do not fit a formula to it.**
- **Write down each note's displayed shift against its step number.** Note ordinal and step number
  are different index spaces (spec §4) and the mapping is not recoverable afterwards.

### T7.3 — Drum Time Shift

- **Resolves:** whether `120` shares the melodic centre of 49 and the same range. Also supersedes
  T6.1's fallback branch.
- **Device:** from the baseline. Track 1 in drum mode, an untouched pattern. Place a Kick at beat 1. Set
  Time Shift to **minimum, −1, 0, +1, maximum**, exporting at each. Five captures.
- **Captures:** `T7-drumshift-<display>.KeyStepPro` — `min`, `m1`, `0`, `p1`, `max`
- **Keys:** `123_120_<pattern>_1_1`
- **Confirms if:** the stored values match the melodic mapping from T7.1/T7.2 at the same displayed
  values.
- **Falsified if:** they differ at any point.
- **If falsified:** drum shift needs its own full sweep, and `project_5`'s −1/+1 reading is a real
  encoding difference rather than the transcription slip T6.1 assumes.

### T7.4 — Global swing alone

- **Resolves:** what `74` stores, and how the device displays it. The KeyStep Pro manual gives the
  swing range as 50 %–75 %, and `74` reads 50 in every sample file, so it is probably the percentage
  directly — but nothing has ever tested it.
- **Device:** from the baseline. Change **only** the global Swing encoder. Export at three settings: the
  minimum, something near the middle, and the maximum. Touch no per-pattern swing.
- **Captures:** `T7-swing-global-<display>.KeyStepPro`
- **Keys:** `120_74`, and **watch whether `97` / `114` move too** — they should not.
- **Confirms if:** `120_74` alone tracks the displayed percentage.
- **Falsified if:** per-pattern keys move as well, or the stored value is not the displayed one.
- **Record the minimum and maximum the encoder will reach.** If the minimum is below 50, swing is
  signed in both directions and the −25 % end of MCC's label is real.

### T7.5 — Per-pattern swing alone

- **Resolves:** the single most consequential question in this tier. MCC labels `97` / `114`
  *"swing (%) (an offset of 25 is applied to be send by MIDI) (−25 % to +25 %)"* — a **signed
  offset**. But `src/ksp/reader.py::_swing` reads it as an **absolute percentage** (`stored + 25`,
  so the default 25 → 50 %). Both readings agree when the global is 50, which is why every sample
  file hides the difference and no test catches it.
- **Device:** from the baseline, global swing left at its default. On **Track 2, pattern 1 only**, set the
  per-pattern swing (SHIFT + Swing encoder) to its maximum. Export. Then its minimum. Export.
- **Captures:** `T7-swing-pattern-max.KeyStepPro`, `T7-swing-pattern-min.KeyStepPro`
- **Keys:** `124_97_1`; also check `124_97_2` and `125_97_1` are untouched, so the scope really is
  one pattern of one track, and check `124_99_1` for the "swing offset state" bit.
- **Confirms if:** only pattern 1 of track 2 moves, and `99` bit changes when a non-default
  per-pattern swing exists — which would mean the flag marks "this pattern overrides the global".
- **Falsified if:** `99` does not move, or other patterns follow.
- **Record the displayed percentage.** If the display reads an absolute 50–75 %, the reader is
  right; if it reads a signed ±N %, the reader is wrong and `_swing` needs fixing.

### T7.6 — Global and per-pattern together

- **Resolves:** which of the three candidates governs the effective swing: `74` alone,
  `74 + (97 − 25)`, or `97 − 25` overriding `74` when the `99` flag is set.
- **Device:** from T7.5's max capture, now **also** move the global Swing to a non-default value
  distinct from the per-pattern one. Export.
- **Capture:** `T7-swing-both.KeyStepPro`
- **Keys:** `120_74`, `124_97_1`, `124_99_1`
- **Confirms if:** both keys hold their own value independently.
- **Then listen.** Play the pattern and judge whether its shuffle matches the global setting, the
  per-pattern setting, or something between. **This listening note is the actual result** — the
  stored values cannot distinguish the three candidates on their own, only the audible behaviour
  can. Tier 8 measures it precisely; this is the cheap version.

### T7.7 — Drum swing spot-check

- **Resolves:** whether `114` behaves like `97`.
- **Device:** from the baseline. Track 1 in drum mode. Set per-pattern swing to maximum. Export.
- **Capture:** `T7-swing-drum.KeyStepPro`
- **Keys:** `123_114_<pattern>`, `123_116_<pattern>`
- **Confirms if:** it mirrors T7.5 with the drum parameter pair.
- **Falsified if:** it does not — then drum swing needs its own sweep.

### T7.8 — Randomness control

- **Resolves:** whether `113` is play-probability or timing jitter. **This gates Tier 8 entirely.**
  A fresh note defaults to randomness 100, and if that means "randomise timing by 100" then every
  timing measurement in this document is measuring noise.
- **Device:** from the baseline. Track 2, pattern 1, four notes at beats 1, 5, 9, 13, all at default
  randomness. Play the pattern for a minute and **listen**: do notes ever fail to sound, and does
  the timing wander? Then set randomness to its **minimum** on all four and listen again. Export
  both.
- **Captures:** `T7-random-default.KeyStepPro`, `T7-random-min.KeyStepPro`
- **Keys:** `124_113_1_1_<1..4>`
- **Confirms if:** at 100 every note sounds every pass with steady timing — i.e. 100 means "always
  plays" and randomness is probability.
- **Falsified if:** notes drop out at 100, or onsets wander audibly.
- **If it is timing jitter:** set randomness to its minimum for **every** Tier 8 capture and say so
  in the ledger. If it is probability, minimum randomness may mean "never plays" — check which end
  is safe before relying on it.

---

## Tier 8 — Live timing capture

**~6 recordings.** The only tier that does not work by exporting files. Everything above reads what
the device *stores*; this measures what the device *does*, because the quantity we need — what one
Time Shift unit is worth in time — does not appear in the file at all.

Run this **after Tier 7**, which supplies the range to sweep, and **after T7.8**, which says whether
the measurement is meaningful.

### How to run a recording

Different from a capture. A recording is:

1. **Rig:** KeyStep Pro MIDI out → interface → DAW. Set the DAW's tempo to the value under test and
   **lock it**; do not let it chase incoming clock.
2. **Reference track.** Track 3, pattern 1: four notes at beats 1, 5, 9, 13, everything at default —
   swing 0, shift 0. Put it on its own MIDI channel. **Every measurement is a difference between a
   test note and its reference note**, which cancels interface latency and clock drift exactly.
   Never measure an absolute onset.
3. **Test track.** Track 2, pattern 1, carrying whatever shift or swing the row calls for, on a
   different channel.
4. **Record at least 8 bars** so per-cell variance is visible rather than averaged away.
5. **Export the recording** as `analysis/captures/<recording-id>.mid` and reduce it with
   `uv run python tools/reduce_timing.py`, which pairs the two channels and prints offsets in both
   ticks and milliseconds.
6. **Log the row** in the ledger: recording ID, BPM, step size, displayed shift/swing, measured
   offset, observed spread.

### The matrix

| ID | BPM | Step size | Varying | Resolves |
|---|---|---|---|---|
| R1 | 30 | 1/4 | shift = 0, ±1, ±half, ±max | the unit `U` at maximum resolution |
| R2 | 120 | 1/4 | same shift values | is `U` tempo-invariant? |
| R3 | 30 | 1/16 | same shift values | is `U` a fraction of a step or a fixed tick count? |
| R4 | 30 | 1/4 | swing at min / mid / max, shift 0 | the swing formula, and which parameter governs it |
| R5 | 30 | 1/4 | swing max **and** shift max together | do they add, or interact? |
| R6 | 30 | 1/4 | repeat of R1, fresh session | reproducibility |

**Start at 30 BPM with 1/4-note steps.** That makes a step 2000 ms, so even a very fine shift unit
is tens of milliseconds — comfortably above MIDI jitter. At 120 BPM with 1/16 steps a step is
125 ms and a fine unit would be around a millisecond, which is at or below the noise floor. **The
slow, coarse setting is what makes this measurable at all.**

### Reading the result

Three candidate encodings, and the matrix separates all three:

| Model | What one unit is | Signature in the data |
|---|---|---|
| **A** — fraction of a step | `t_step / N` | R1 ≡ R2 in *ticks*; R3 differs from R1 in ms by exactly the step-size ratio |
| **B** — fixed clock ticks | a constant tick count | R1 ≡ R2 in ticks; **R3 ≡ R1 in ms** |
| **C** — absolute time | a constant in ms | **R1 ≡ R2 in ms**, not in ticks |

- **R1 vs R2 separates C** from the other two: only under C does a tempo change leave the
  millisecond offset unchanged.
- **R1 vs R3 separates A from B.** This is why BPM alone is not enough — A and B are both
  tempo-invariant, and only changing the step size tells them apart.
- **If R6 does not reproduce R1**, stop. Something in the rig is drifting and no result from this
  tier can be trusted until it is found.

Record the outcome in [`Timing_Calibration.md`](./Timing_Calibration.md) §6 and put the constant in
`ksp.constants.TIME_SHIFT_UNIT`, which is `None` until this tier produces a number. **Do not fill it
in from a plausible-looking pattern in one recording** — the failure mode is a file that loads
cleanly and plays with wrong timing, and nothing errors.

---

## Capture ledger

Fill in as you go. This table is the record; the `.KeyStepPro` files are the evidence.

Rows for the completed tiers have been removed along with their procedures. The few values those
captures still owe are in [`Capture_Ledger_Gaps.md`](./Capture_Ledger_Gaps.md).

| Test ID | Date | Displayed value / setting | Stored value | Notes |
|---|---|---|---|---|
| T2.* | | gate = | | one row per detent |
| T2.y | | drum gate = | | same table as melodic? |
| T4.5 | | melodic step 5 toggled off | | **did beat 5 sound?** |
| T4.6 | | >64 melodic notes | | did `48` spill to slot 2? ceiling reached at: |
| T5.* | | `99` field = | | one row per setting |
| T5.6 | | root note / scale | | |
| T5.7 | | 3-pattern chain | | |
| T5.8 | | 16-step pattern, one note per skip mask | | **repeats or pages?** which notes sounded: |
| T6.1 | | project_5 kick time shifts | | −1/+1 or −1/−1? |
| T6.2 | | no trailing comma | | loaded? |
| T7.1 | | shift min / max displayed | | **the range — run first** |
| T7.2 | | shift per step: | | one row per note |
| T7.3 | | drum shift = | | matches melodic? |
| T7.4 | | global swing = | | min/max the encoder reaches: |
| T7.5 | | pattern swing = | | absolute % or signed ±%? |
| T7.6 | | global + pattern swing | | **which one did you hear?** |
| T7.7 | | drum swing = | | |
| T7.8 | | randomness 100 then min | | **notes drop? timing wander?** |
| R1 | | 30 BPM, 1/4, shift sweep | | measured offset per unit: |
| R2 | | 120 BPM, 1/4 | | same ticks as R1? |
| R3 | | 30 BPM, 1/16 | | same ms as R1? |
| R4 | | 30 BPM, swing sweep | | |
| R5 | | swing + shift together | | additive? |
| R6 | | repeat of R1 | | reproduced? |

## Effort summary

Remaining work only. B0 and tiers 1 and 3 are complete and are not listed.

| Tier | Captures left | Resolves | Milestone |
|---|---|---|---|
| 2 | ~20 | gate table | M7 |
| 4 | 3 | melodic step-active and pool chunking | M6, M5 |
| 5 | ~14 | pattern scalars, chaining, step-skip semantics | M6, M2 |
| 6 | 2 | standing caveats | M3 |
| 7 | ~13 | Time Shift range, swing semantics | M7, M5 |
| 8 | ~6 recordings | what a Time Shift unit is worth in time | M2, M5 |
| | **~58 left** of ~76 | | |

Each tier is independently useful — stopping after any one leaves a coherent result rather than a
half-finished one.

**Remaining ranking: T4.5 → T7.1 → Tier 2 → rest of Tier 7 → T4.6 → Tier 6 → Tier 5 → Tier 8.**

- **T4.5 leads** because it is the one open question that the *shipped* code already depends on:
  the export drops inactive melodic notes on the strength of D1's drum result plus a corpus where
  `48` never disagrees with the pool. Three captures make that measured instead of inferred.
- **T7.1 is two captures and jumps the queue** because it is a go/no-go: if the Time Shift range is
  only ±4, the rest of Tier 7's shift work and most of Tier 8 are not worth running at all.
- **T7.5 is the other place the code may be wrong** — `reader._swing` and MCC's own field label
  disagree about whether per-pattern swing is absolute or a signed offset, and no existing test can
  tell, because every sample file is swing-neutral.
- **Tier 8 is last** because it is the only tier needing a recording rig rather than just the device
  and MCC, and because Tier 7 supplies the range it sweeps.

This ordering has a track record. The previous version put D1 and Tier 3 first as "the two places
where the current code is arguably wrong", and both were: D1 found the export emitting silent
notes, and Tier 3 confirmed the mode flag. D2 then overturned the polyphony-slot model, which
nothing had flagged as doubtful — so the ranking is a guide, not a guarantee, and a capture that
merely confirms is still worth its five minutes.
