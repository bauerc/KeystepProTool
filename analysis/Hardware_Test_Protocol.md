# KeyStep Pro hardware capture protocol

**Purpose:** resolve the format questions that cannot be answered from files already on disk, by
setting known values on the device, exporting them, and diffing — or, for a write test, by running
that loop backwards: writing a known value into a file, loading it, and reading the device's own
export back out.

**Audience:** a human at the device, and an agent re-reading this later to interpret the captures.

> **This document contains only unfinished work.** What is found is in
> [`KeyStepPro_Format_Spec.md`](./KeyStepPro_Format_Spec.md), which is the authoritative record —
> not here.

**The baseline every test below starts from** is `B0-baseline.KeyStepPro` — an initialised,
untouched project, already captured. Where a test says "from the baseline", start by loading or
re-initialising to that state; do not re-derive it.

**What is genuinely unknown and needs the device:**

| Question                                                      | Blocks                                     | Tier |
| ------------------------------------------------------------- | ------------------------------------------ | ---- |
| Time Shift range and linearity (`112` / `120`)                | M7; whether shift is usable at all         | 7    |
| Which parameter governs effective swing (`74` / `97` / `114`) | M7, and `reader._swing` may be wrong       | 7    |
| Whether `113` randomness is probability or timing jitter      | the validity of every timing measurement   | 7    |
| What one Time Shift unit is worth in time                     | M2's grid-quantise warning, M5's quantiser | 8    |

The last four are the subject of [`Timing_Calibration.md`](./Timing_Calibration.md), which carries
the model and the arithmetic; tiers 7 and 8 below are the captures that feed it.

---

## How to run a capture

Every test below is one capture. A capture is:

1. **Start from a known state.** Either a freshly initialised project, or the immediately
   preceding capture in the same tier — each test says which. Never start from an unknown state.
2. **Change exactly one thing.** One parameter, one note, one setting.
3. **Read the device display and write down what it says.** The stored value is what we are
   trying to learn, so the _displayed_ value is the ground truth and only exists in your notes.
   This is the step that cannot be recovered later.
4. **Export**, by the route below. It is fixed — every capture in the corpus used it.
5. **Save it as** `project_files/captures/<test-id>.KeyStepPro`, using the test ID verbatim.
6. **Log it** in the ledger at the bottom of this file: test ID, displayed value, date, anything
   that felt off.
7. **Tick the test's checkbox** at the top of its section. That is the signal the capture exists and
   is ready to be read.

### The export route

Recorded once so the captures are reproducible; this is the route behind every file in
`project_files/captures/`.

1. **On the device:** hold **SAVE** and press **PROJECT**, then click the encoder next to the
   display to confirm. The corpus uses the **Project 2** slot throughout.
2. **In MIDI Control Center:** select that project and click **Recall From**, which pulls it off
   the device and writes it into MCC's template directory as
   `…/Arturia/MIDI Control Center/Templates/KeyStepPro/<name>.KeyStepPro`.
3. **Move it into the repo** under the test ID — `project_files/captures/<test-id>.KeyStepPro`.
   `project_files/captures/move_template.sh` does this step.

MCC's own Save As is not part of the route. Note that `project_files/captures/` is **gitignored**:
the captures are local evidence, and the finding has to reach the spec to survive.

### The import route

Its mirror, for any test that puts a file we generated _onto_ the device. Tiers M4 and M5 used it;
so does every future write test.

1. **Generate the candidates at the desk**, before the session:

   ```sh
   uv run pytest -m hardware
   ```

   The marker-gated tests write their candidates into `project_files/captures/` and assert on the
   way out that each differs from its source by the expected key count. Readback assertions skip
   until the matching capture exists.

2. **Copy into MCC's library**, which is world-writable and needs no `sudo`:

   ```sh
   cp project_files/captures/<name>.KeyStepPro \
      "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/"
   ```

3. **Restart MCC**, find the project in the Project Browser, load it, and send it to the device.

4. **Read the device, then export back** by the route above, saving as `<name>-readback`.

A readback diff is **empty** when the file is right (M4.1), which makes it the cheapest regression
net available — anything in it is the answer.

### Device operating notes

Things that are not on the display and are easy to lose between sessions. Each is needed to
_perform_ one of the tests below.

- **Step Edit** (a physical button) is required to add notes to an existing step — that is how a
  chord gets built. It is off by default and switches itself off when you change project and come
  back.
- **Drum Mono/Poly:** SHIFT + D#2 selects Mono, SHIFT + E2 selects Poly. Poly is what gives drum
  lanes independent step counts, and it moves `116` bit 2 (spec §5).
- **ARP octave** has no display readout at all. It is SHIFT plus one of five silkscreened keys on
  the second physical octave, −1 / 0 / +1 / +2 / +3, with 0 at C#3.
- **Erasing a note** is ERASE + the step button. Toggling a step off only mutes it; the note stays
  in the pool and playing a new pitch onto the dark step re-lights the _old_ note rather than
  replacing it.
- **The device names middle C as C3** (C2 = MIDI 48). Write displayed note names down as the
  device shows them and convert later — do not pre-convert in your notes.

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

### Batched sweep captures

**The one-change rule above applies to captures that are read by diffing.** A _sweep_ capture is
not read that way, and holding it to the same rule is what made the gate sweep — the former Tier 2,
now complete (spec §6.1) — unrunnable for months: one export per encoder detent is ~128
sync-and-save cycles through MCC. Batching collapsed it to a single capture, and **Tier 7's shift
sweep should be run the same way.**

One export contains every pattern of every track, and every note's parameter has its own key —
`124_110_<pattern>_1_<ordinal>`. So one export can carry hundreds of independent readings, read
directly by key rather than by diff. That is allowed when:

- **one parameter** is swept, and nothing else on the device is touched;
- **each value sits on a distinct note**, so no two changes share a key;
- a **note map** — which step carries which intended value — is written down _at capture time_,
  in the ledger or a companion data file. Without it the capture is unreadable afterwards.

Three rules that are not optional:

- **Pair by `50` (or `54` for drums), never by note ordinal.** Note ordinal and step number are
  different index spaces (spec §4) and the pool is in creation order. Read
  `124_50_<p>_1_<k>` to learn which step note `k` sits on, and sort by that. Getting this wrong
  silently permutes the whole table into something that still looks plausible.
- **Sweep a contiguous run of detents, not scattered samples.** Tier 2's six scattered gate points
  looked like a non-linear curve for months; a run of 64 consecutive ones showed in minutes that
  the encoding was a plain index. A sparse sample of a monotonic encoder tells you almost nothing.
- **Export after each pattern is filled** (`-wip1`, `-wip2`, …). A sweep capture is an hour of
  device work; a mishap should cost one pattern, not the session.

Two things to design against, both of which bit Tier 2:

- **A note you forget to set keeps its fresh-note default**, which is indistinguishable from a
  deliberate value. Build in a check that catches it — for a ramp, that the stored values are a
  gapless run.
- **Over-turning the encoder by one detent** produces a gap plus an adjacent duplicate. The repair
  is one extra note at the missing value, not a redo.

### Diffing

No tooling needs to exist first. This is enough:

```python
# uv run python - <<'EOF'
from ksp import lenient_json

BASE = "project_files/captures/B0-baseline.KeyStepPro"
CAP  = "project_files/captures/T7-shift-min.KeyStepPro"

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

## Tier 6 — Re-checks

**1 capture left**, and it removes a standing caveat. T6.2 (the trailing comma) is done — see the
preamble.

### T6.1 — The `project_5` drum time-shift conflict

- [x] not yet run

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

---

## Tier 7 — Time Shift and Swing encodings

**~13 captures.** Ordinary export-and-diff captures, same workflow as every tier above. These
resolve what the _stored_ values mean; Tier 8 resolves what they are worth in time. Background and
the model are in [`Timing_Calibration.md`](./Timing_Calibration.md).

Two things make this tier necessary. **Time Shift has never been swept** — the only non-default
values in the whole corpus are `project_5`'s ±1…±4 ramp, so the range is unknown and T6.1's
fallback branch merely _assumes_ ±4. And **swing has never been set at all**: `74` reads 50 and
`97` / `114` read 25 in all 16 patterns of all four tracks of all five sample files, so there is
zero observational data on it.

> **Set swing to 0 for the whole of T7.1–T7.3, and place shift test notes on odd-numbered steps
> (1, 3, 5 …).** Swing displaces even-numbered steps, so a stray swing setting cannot contaminate
> the shift captures if the notes sit where swing does not reach.

### T7.1 — Time Shift range

- [x] not yet run

- **Resolves:** `D_min` and `D_max`. **Run this first** — it decides whether the rest of the tier is
  worth doing. If the range is only ±4, Time Shift spans roughly ±4 % of a step and is useless as a
  quantization target, so M5 would snap to the grid and report the loss instead of pretending to
  represent it. If it is ±49, shift covers the entire gap between steps.
- **Device:** from the baseline. Track 2, pattern 1. Place one note at beat 1 Turn Time Shift **all the way
  down** until the display stops moving. Place a note at beat 5, turn timeshift **all the way up**, export.
- **Captures:** `T7-shift.KeyStepPro`
- **Diff against:** `T1-note-place.KeyStepPro` (or the baseline plus the note)
- **Keys:** `124_112_1_1_1`, `124_112_1_1_5` only
- **Confirms if:** the two stored values sit symmetrically
  about 49.
- **Falsified if:** the range is asymmetric about 49, or the stored value leaves 0–127.
- **Record the displayed value at both extremes.** That is the deliverable — the stored number is
  in the file, the displayed one exists only in your notes.

### T7.2 — Time Shift linearity

- [x] not yet run

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

- [x] not yet run

- **Resolves:** whether `120` shares the melodic centre of 49 and the same range. Also supersedes
  T6.1's fallback branch.
- **Device:** from the baseline. Track 1 in drum mode, an untouched pattern. Place a Kick at beat 1, 3, 5, 7, 9. Set
  Time Shift to -49, −1, 0, +1, 50, export.
- **Captures:** `T7-drumshift.KeyStepPro`
- **Keys:** `123_120_<pattern>_1_1`, etc
- **Confirms if:** the stored values match the melodic mapping from T7.1/T7.2 at the same displayed
  values.
- **Falsified if:** they differ at any point.
- **If falsified:** drum shift needs its own full sweep, and `project_5`'s −1/+1 reading is a real
  encoding difference rather than the transcription slip T6.1 assumes.

### T7.4 — Global swing alone

- [x] not yet run

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

- [x] not yet run

- **Resolves:** the single most consequential question in this tier. MCC labels `97` / `114`
  _"swing (%) (an offset of 25 is applied to be send by MIDI) (−25 % to +25 %)"_ — a **signed
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

- [x] not yet run

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

- [x] not yet run

- **Resolves:** whether `114` behaves like `97`.
- **Device:** from the baseline. Track 1 in drum mode. Set per-pattern swing to maximum. Export.
- **Capture:** `T7-swing-drum.KeyStepPro`
- **Keys:** `123_114_<pattern>`, `123_116_<pattern>`
- **Confirms if:** it mirrors T7.5 with the drum parameter pair.
- **Falsified if:** it does not — then drum swing needs its own sweep.

### T7.8 — Randomness control

- [x] not yet run

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
the device _stores_; this measures what the device _does_, because the quantity we need — what one
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

| ID  | BPM | Step size | Varying                              | Resolves                                           |
| --- | --- | --------- | ------------------------------------ | -------------------------------------------------- |
| R1  | 30  | 1/4       | shift = 0, ±1, ±half, ±max           | the unit `U` at maximum resolution                 |
| R2  | 120 | 1/4       | same shift values                    | is `U` tempo-invariant?                            |
| R3  | 30  | 1/16      | same shift values                    | is `U` a fraction of a step or a fixed tick count? |
| R4  | 30  | 1/4       | swing at min / mid / max, shift 0    | the swing formula, and which parameter governs it  |
| R5  | 30  | 1/4       | swing max **and** shift max together | do they add, or interact?                          |
| R6  | 30  | 1/4       | repeat of R1, fresh session          | reproducibility                                    |

- [x] R1 — 30 BPM, 1/4, shift sweep
- [x] R2 — 120 BPM, 1/4
- [x] R3 — 30 BPM, 1/16
- [x] R4 — 30 BPM, swing sweep
- [x] R5 — swing and shift together
- [x] R6 — repeat of R1

**Start at 30 BPM with 1/4-note steps.** That makes a step 2000 ms, so even a very fine shift unit
is tens of milliseconds — comfortably above MIDI jitter. At 120 BPM with 1/16 steps a step is
125 ms and a fine unit would be around a millisecond, which is at or below the noise floor. **The
slow, coarse setting is what makes this measurable at all.**

### Reading the result

Three candidate encodings, and the matrix separates all three:

| Model                      | What one unit is      | Signature in the data                                                       |
| -------------------------- | --------------------- | --------------------------------------------------------------------------- |
| **A** — fraction of a step | `t_step / N`          | R1 ≡ R2 in _ticks_; R3 differs from R1 in ms by exactly the step-size ratio |
| **B** — fixed clock ticks  | a constant tick count | R1 ≡ R2 in ticks; **R3 ≡ R1 in ms**                                         |
| **C** — absolute time      | a constant in ms      | **R1 ≡ R2 in ms**, not in ticks                                             |

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

Rows for the completed tiers have been removed along with their procedures. The values those
captures owed were collected in a separate gaps ledger, which is now **closed** — every row was
answered and folded into the spec on 2026-08-01.

| Test ID | Date | Displayed value / setting  | Stored value | Notes                                                                                                                                                                                                                                                                                   |
| ------- | ---- | -------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T6.1    |      | project_5 kick time shifts |              | −1/+1                                                                                                                                                                                                                                                                                   |
| T7.1    |      | shift min / max displayed  |              | **the range — run first** Min -49, Max 50. Increments by 1                                                                                                                                                                                                                              |
| T7.2    |      | shift per step:            |              | beat 1 -49, beat 3 -25, beat 5 -1, beat 7 0, beat 9 1, beat 11 25, beat 13 50                                                                                                                                                                                                           |
| T7.3    |      | drum shift =               |              | Time shift ranges matches, -49 to 50 at 1 increments                                                                                                                                                                                                                                    |
| T7.4    |      | global swing =             |              | min/max the encoder reaches: Min is 50%, max is 75%. Not exporting 50% since it is the min AND the default                                                                                                                                                                              |
| T7.5    |      | pattern swing =            |              | absolute %. Display shows two sections when moving, global and Track. Track swing has a default of 50%, min of 50%, and a max of 75%                                                                                                                                                    |
| T7.6    |      | global + pattern swing     |              | **which one did you hear?** Neither, swing only affects even numbered steps (step 2, 4, etc). When I changed the to even steps, I could hear the difference. The odd notes played on exact beat while the even notes were pushed later. Exact timing can be seen in the R4 timing test. |
| T7.7    |      | drum swing =               |              | It is a per track, not per pattern, same as melody, and the min and default is 50 and the max is 75.                                                                                                                                                                                    |
| T7.8    |      | randomness 100 then min    |              | **notes drop? timing wander?** This has nothing to do with timing whatsoever. This is all about if a note plays or not. At 0, note never plays. At 50% it play half the time. At 100 it plays all the time. No timing jitter ever.                                                      |
| R1      |      | 30 BPM, 1/4, shift sweep   |              | measured offset per unit:                                                                                                                                                                                                                                                               |
| R2      |      | 120 BPM, 1/4               |              | same ticks as R1?                                                                                                                                                                                                                                                                       |
| R3      |      | 30 BPM, 1/16               |              | same ms as R1?                                                                                                                                                                                                                                                                          |
| R4      |      | 30 BPM, swing sweep        |              |                                                                                                                                                                                                                                                                                         |
| R5      |      | swing + shift together     |              | additive?                                                                                                                                                                                                                                                                               |
| R6      |      | repeat of R1               |              | reproduced?                                                                                                                                                                                                                                                                             |

## Effort summary

Remaining work only. B0, tiers 1–5 and the two write tiers are complete and are not listed.

| Tier | Captures left       | Resolves                                | Milestone |
| ---- | ------------------- | --------------------------------------- | --------- |
| 6    | 1                   | standing caveats (T6.2 done)            | M3        |
| 7    | ~13                 | Time Shift range, swing semantics       | M7, M5    |
| 8    | ~6 recordings       | what a Time Shift unit is worth in time | M2, M5    |
|      | **~20 left** of ~59 |                                         |           |

Each tier is independently useful — stopping after any one leaves a coherent result rather than a
half-finished one.

**Remaining ranking: T7.1 → rest of Tier 7 → Tier 6 → Tier 8.**

- **T7.1 leads** and is two captures, because it is a go/no-go: if the Time Shift range is
  only ±4, the rest of Tier 7's shift work and most of Tier 8 are not worth running at all.
- **T7.5 is now the one place the shipped code may be wrong** — `reader._swing` and MCC's own field label
  disagree about whether per-pattern swing is absolute or a signed offset, and no existing test can
  tell, because every sample file is swing-neutral.
- **Tier 8 is last** because it is the only tier needing a recording rig rather than just the device
  and MCC, and because Tier 7 supplies the range it sweeps.

This ordering has a track record. The previous version put D1 and Tier 3 first as "the two places
where the current code is arguably wrong", and both were: D1 found the export emitting silent
notes, and Tier 3 confirmed the mode flag. D2 then overturned the polyphony-slot model, which
nothing had flagged as doubtful — so the ranking is a guide, not a guarantee, and a capture that
merely confirms is still worth its five minutes.
