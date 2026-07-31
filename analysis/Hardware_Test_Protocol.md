# KeyStep Pro hardware capture protocol

**Purpose:** resolve the format questions that cannot be answered from files already on disk, by
setting known values on the device, exporting them, and diffing.

**Audience:** a human at the device, and an agent re-reading this later to interpret the captures.

**Companion document:** [`Format_Corrections_Issue.md`](./Format_Corrections_Issue.md). Read its
summary table before starting. Several questions the format spec and `ROADMAP.md` still list as
open — the packing of `52`, the poly-slot count, the step-active warnings — were resolved at the
desk from MCC's parameter dictionary and are **not** in this document. Do not spend device time
on them.

**What is genuinely unknown and needs the device:**

| Question | Blocks | Tier |
|---|---|---|
| The gate length table (`110` / `118`) | M7, and correct note durations in M5/M6 | 2 |
| Which bit of `100` is drum mode | M6 | 3 |
| Whether an unflagged pooled drum note sounds | M6 correctness | 4 |
| Real poly and drum-lane limits | M6 | 4 |
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

## B0 — Baselines

**2 captures.** Everything downstream is a diff against these, so the noise floor has to be
measured before any signal is trusted.

### B0.1 — Fresh project

- **Resolves:** what an initialised, untouched project looks like from *this* device and *this*
  MCC version, as opposed to the checked-in `user_empty_project.KeyStepPro`.
- **Device:** initialise a new empty project. Change nothing at all.
- **Capture:** `B0-baseline.KeyStepPro`
- **Diff against:** `project_files/user_empty_project.KeyStepPro`
- **Expect:** no differences, or differences only in project-level keys (`120_*`).
- **If it differs elsewhere:** stop and record what moved. Something about the device state is
  not what the existing samples assume, and every later capture inherits that.

### B0.2 — Null capture

- **Resolves:** which keys drift on their own. This is the false-positive floor.
- **Device:** touch nothing. Export B0.1 a second time.
- **Capture:** `B0-baseline-repeat.KeyStepPro`
- **Diff against:** `B0-baseline.KeyStepPro`
- **Expect:** byte-identical, or a difference only in `version`.
- **If keys move:** those keys are noise. **Write them down here** and treat them as ignorable in
  every later diff. Skipping this test means mistaking that drift for a result later on.

> B0.2 also settles a small M3 question for free: if two untouched exports are byte-identical,
> MCC's writer is deterministic and the round-trip target is well defined.

---

## Tier 1 — M4, write-path sanity

**4 captures.** Cheap, fast, and they give M4 ("change one note in a real project, load it in MCC,
push to the device") the ground truth it needs. Each is a single edit on **Track 2, pattern 1**,
which no sample file uses — so the diff is against a genuinely blank slate.

Run them cumulatively: each starts from the previous capture.

### T1.1 — Place a note

- **Resolves:** every key the device writes when a note comes into existence. This is the complete
  set a writer must produce, and there is currently no capture that isolates it.
- **Device:** from B0.1. Track 2, pattern 1. Place one note, pitch **C3 (60)**, at **beat 1**.
  Leave Velocity, Gate, Time Shift, Randomness and Step Skip at whatever they default to.
- **Capture:** `T1-note-place.KeyStepPro`
- **Diff against:** `B0-baseline.KeyStepPro`
- **Keys:** `124_50_1_1_1`, `124_109_1_1_1`, `124_110_1_1_1`, `124_111_1_1_1`, `124_112_1_1_1`,
  `124_113_1_1_1`, `124_48_1_1_1`, `124_40_1`, `124_39`
- **Confirms if:** `50` → 0, `109` → 60, `110` → 7, `111` → 100, `112` → 49, `113` → 100,
  `48` → 1, `40` → 3. These are the documented fresh-note defaults (spec §6) and the
  `Default.KeyStepPro` per-pattern defaults, so they should agree.
- **Falsified if:** any other key moves, or `40` does not go to 3.
- **If falsified:** the extra keys are part of note creation and a writer must set them too.
  Record them — this is exactly the kind of omission that produces a file MCC loads and the
  device plays wrong.

### T1.2 — Change its pitch

- **Resolves:** that pitch is `109` alone and nothing shadows it.
- **Device:** from T1.1. Change that note's pitch to **E3 (64)**. Nothing else.
- **Capture:** `T1-note-pitch.KeyStepPro`
- **Diff against:** `T1-note-place.KeyStepPro`
- **Confirms if:** exactly one key moves, `124_109_1_1_1`: 60 → 64.
- **Falsified if:** more than one key moves.

### T1.3 — Change its velocity

- **Resolves:** that velocity is stored directly, 0–127, with no scaling (spec §8 corrects an
  earlier claim of 16 discrete levels — this confirms the correction on the device).
- **Device:** from T1.2. Set Velocity to **127**, the value that is ambiguous with the sentinel.
- **Capture:** `T1-note-velocity.KeyStepPro`
- **Diff against:** `T1-note-pitch.KeyStepPro`
- **Confirms if:** exactly one key moves, `124_111_1_1_1` → 127, and the note still reads as
  present (`124_50_1_1_1` unchanged at 0).
- **Falsified if:** the note vanishes from the file, or `111` lands on something other than 127.
- **Why 127 specifically:** it is the one velocity that a reader inferring existence from velocity
  would get wrong. Spec §4 says never do that; this capture is the evidence.

### T1.4 — Delete it

- **Resolves:** what deletion leaves behind — whether the pool entry is cleared to `127` or the
  parameters linger.
- **Device:** from T1.3. Delete the note. Leave the pattern otherwise untouched.
- **Capture:** `T1-note-delete.KeyStepPro`
- **Diff against:** `T1-note-place.KeyStepPro` **and** `B0-baseline.KeyStepPro`
- **Confirms if:** the diff against B0 is empty — deletion fully reverses creation.
- **Falsified if:** residue remains (e.g. `109` keeps 64 while `50` returns to 127, or `40`
  stays 3).
- **Either way this is a finding.** Residue tells us what a writer may safely leave behind, and
  whether `40` alone can mark a pattern empty. Both matter for M5's template-and-overwrite.

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
- **Device:** from B0.1. Track 2, pattern 1. Place one note at beat 1, any pitch. Then step Gate
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
- **Device:** from B0.1. Track 1 in drum mode, an untouched pattern. Place a Kick at beat 1. Set
  Gate to each of **0.5, 1, 2, 4** and the minimum, exporting at each. Five captures.
- **Capture:** `T2-drumgate-<display>.KeyStepPro`
- **Keys:** `123_118_<pattern>_1_1`
- **Confirms if:** the stored values match the melodic table at the same displayed values.
- **Falsified if:** they differ at any point.
- **If falsified:** the drum table needs its own full sweep — repeat T2.1–T2.n on the drum track.
  Budget another ~20 captures. Better to discover this from five captures than after writing the
  converter.

---

## Tier 3 — M6, the drum-mode bit

**4 captures.** The only remaining blocker on M6. Parameter `100` is documented as
"Pattern Seq ARP/Drum mode, ARP type, ARP octave in a bitfield" with the dictionary's own comment
placing ARP octave at bits 4–6. It reads **26** (`0b0011010`) in every pattern of all five sample
files — including patterns that are unambiguously melodic and ones that are unambiguously drum —
so nothing in the current corpus distinguishes the modes.

This matters because `initial_project` Track 1 pattern 1 holds a real 64-note melody *and* a real
12-note drum pattern. A reader cannot tell which plays; a writer cannot set the flag.

### T3.1 — Track 1 in sequencer mode

- **Device:** from B0.1. Put Track 1 in its **sequencer** mode. Place one note at beat 1 so the
  pattern is non-empty. Nothing else.
- **Capture:** `T3-track1-seq.KeyStepPro`
- **Diff against:** `B0-baseline.KeyStepPro`
- **Keys:** `123_100_<pattern>`, and anything else that moves.

### T3.2 — Track 1 in drum mode

- **Device:** from T3.1. Switch Track 1 to **drum** mode. Change nothing else — in particular do
  not place a drum hit yet.
- **Capture:** `T3-track1-drum.KeyStepPro`
- **Diff against:** `T3-track1-seq.KeyStepPro`
- **Confirms if:** `123_100_<pattern>` changes, and the changed bit is consistent across patterns.
- **Falsified if:** `100` does not move.
- **If `100` does not move:** the mode is stored somewhere else entirely. Widen the diff to every
  key that changed and look first at the per-track scalars (`123_39`, `85`, `86`, `59`, `60`), then
  at the project item `120_*`, then at the scene item `121_*`. It is also possible the mode is a
  *global* device setting rather than a project one, in which case it lives under
  `deviceGlobalParametersId: 65` and is **not in the project file at all** — which would be a
  significant finding, because it would mean a converter cannot set it and must document that the
  user has to switch the track by hand.

### T3.3 / T3.4 — Separate the mode bit from the ARP bits

- **Resolves:** which bit is mode, given that `100` also carries ARP type and ARP octave and a
  single-capture diff cannot separate fields that move together.
- **Device:** from T3.1 (sequencer mode). Engage the **arpeggiator** mode on Track 2, export. Then change the
  **ARP octave** by one, export.
- **Captures:** `T3-arp-on.KeyStepPro`, `T3-arp-octave.KeyStepPro`
- **Confirms if:** the ARP captures move bits 4–6 (octave, per the dictionary's comment) and
  the ARP-type bits, leaving the bit that T3.2 moved untouched.
- **Falsified if:** the ARP captures move the same bit as the mode change.
- **If falsified:** `100` is more entangled than a simple bitfield and needs a truth table — run
  the four combinations of {seq, drum} × {ARP off, ARP on} and solve. Four more captures.

---

## Tier 4 — M6, step-active semantics and real limits

**8 captures.** D1 is the highest-value single test in this document.

### D1 — Does an unflagged pooled drum note sound?

- **Resolves:** whether `52` (step active) or the note pool is authoritative — finding 5 of the
  companion issue. The file evidence is one-directional and strong: across all five sample files,
  every step flagged in `52` has a matching pooled note, and never the reverse. But that is device
  behaviour inferred from file state, and this test observes the behaviour directly.
- **Device:** from B0.1. Track 1 in drum mode, untouched pattern. Place a Kick at beat 1 and one
  at beat 5. Export (`D1-two-hits`). Then **toggle step 5 off without deleting the note** — use
  whatever control deactivates a step rather than clears it. Export (`D1-step-off`).
  **Then listen: play the pattern and note whether beat 5 sounds.** Write the answer in the ledger.
- **Captures:** `D1-two-hits.KeyStepPro`, `D1-step-off.KeyStepPro`
- **Keys:** `123_52_<pattern>_1_1` (lane 0, part 0 — steps 1–7), `123_54_<pattern>_1_1` and
  `_1_2`, `123_117/118/119/120/121_<pattern>_1_*`
- **Confirms if:** `52` goes from 17 (`0b0010001`, steps 1 and 5) to 1 (step 1 only), the pool
  entry for the beat-5 note **survives unchanged**, and beat 5 **does not sound**.
- **Falsified if:** the pool entry is cleared alongside the flag (then the two are equivalent and
  either can be read), or the note still sounds with its flag clear (then `52` is not what we
  think and the whole decode needs revisiting).
- **Why it matters:** if confirmed, `ksp-dump` and the M2 MIDI export are currently reporting
  notes that do not play — `initial_project` pattern 3 lane 19 has 16 pooled notes with no flags
  at all. Exporting those to MIDI would produce audio the device never makes.
- **Also record:** whether the device UI shows the step as containing anything after toggling.

### D2 — Poly slot ceiling

- **Resolves:** what happens to a 4-note chord. MCC's descriptors address note parameters at slots
  `[1, 2, 3]` only, on every track including Track 1 — so the answer should be that the fourth
  note has nowhere to go. `ROADMAP.md` M6 currently says "poly slots cap at 3 (4 on Track 1)",
  which the dictionary contradicts.
- **Device:** from B0.1. Track 3, pattern 1. Place a **3-note chord** at beat 1, export. Then add
  a **4th note** to the same beat, export. Repeat both on **Track 1** in sequencer mode.
- **Captures:** `D2-chord3-tr3`, `D2-chord4-tr3`, `D2-chord3-tr1`, `D2-chord4-tr1`
- **Keys:** `125_50_1_<1..4>_1`, `125_109_1_<1..4>_1`, and the `123_*` equivalents
- **Confirms if:** the 3-note chord fills slots 1–3, and the 4th note is refused — the device
  declines the input, or replaces an existing voice. Slot 4 keys stay zero.
- **Falsified if:** anything lands in slot 4.
- **If falsified:** slot 4 *is* addressable and the dictionary's descriptor list is incomplete.
  That would be worth knowing precisely — capture what slot 4 holds and whether it survives a
  round trip back to the device.
- **Note whether the two tracks behave the same.** Track 1 is structurally different and the
  existing spec assumed it had an extra voice.

### D3 — Drum polyphony

- **Resolves:** whether the drum note pool ever uses slots 2 and 3. It never does in any sample
  file — all drum notes across all five files sit in slot 1 — but the descriptors say slots 1–3
  are addressable, and 64 pool entries is not many for a 24-lane, 64-step pattern.
- **Device:** from B0.1. Track 1 in drum mode. Fill one pattern with **more than 64 drum hits**
  spread across several lanes — the fastest route is several lanes at every step. Export.
- **Capture:** `D3-drum-overflow.KeyStepPro`
- **Keys:** `123_54_<pattern>_2_*` and `123_54_<pattern>_3_*`
- **Confirms if:** hits beyond 64 appear in slot 2, giving a 192-entry pool as the descriptors
  imply.
- **Falsified if:** the device refuses hits past 64, or overwrites.
- **Why it matters:** M6 must know the real per-pattern drum capacity before it can decide what
  to do with a dense MIDI file.

### D4 — Per-lane step count

- **Resolves:** that `51` is a *per-lane* step count (finding 6). Every sample file holds a uniform
  15 across all 24 lanes, so nothing yet demonstrates lanes can differ.
- **Device:** from B0.1. Track 1 in drum mode. Set **one lane** to a step count different from the
  rest — e.g. lane 1 (kick) to 12 steps while the others stay at 16. Export.
- **Capture:** `D4-lane-steplength.KeyStepPro`
- **Keys:** `123_51_<pattern>_1_<1..24>`
- **Confirms if:** entry 1 goes to 11 (0-based) and entries 2–24 stay 15.
- **Falsified if:** all 24 entries move together, or a different key changes.
- **If all move together:** it is a per-pattern value stored redundantly, and the "poly step count"
  name means something else. Either way this is one capture and it settles it.

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

- **Device:** from B0.1, Track 2 pattern 1. Change **one field at a time**, returning to default
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
- **Device:** from B0.1. Set a non-default root note, export. Set a non-default scale, export.
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
- **Device:** from B0.1. Build a chain of **3 patterns** on Track 2 within scene 1. Export.
- **Capture:** `T5-chain-3.KeyStepPro`
- **Keys:** `121_84_1_2_<1..16>` (scene 1, track 2), and `121_83_*` (current pattern per track)
- **Confirms if:** the first three entries hold 0-based pattern numbers and the rest stay 127.
- **Falsified if:** the chain lands somewhere else, or the ordering is not what the display shows.
- **Note the track index mapping.** `121_84_<scene>_<track>_*` uses track index 5 for the Control
  track and 1–4 for the sequencer tracks, per the descriptors — worth confirming, since it is the
  one place the item ordering is not the obvious one.

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
- **Device:** from B0.1. Track 2, pattern 1. Place one note at beat 1. Turn Time Shift **all the way
  down** until the display stops moving, export. Then **all the way up**, export.
- **Captures:** `T7-shift-min.KeyStepPro`, `T7-shift-max.KeyStepPro`
- **Diff against:** `T1-note-place.KeyStepPro` (or B0.1 plus the note)
- **Keys:** `124_112_1_1_1` only
- **Confirms if:** exactly one key moves per capture, and the two stored values sit symmetrically
  about 49.
- **Falsified if:** the range is asymmetric about 49, or the stored value leaves 0–127.
- **Record the displayed value at both extremes.** That is the deliverable — the stored number is
  in the file, the displayed one exists only in your notes.

### T7.2 — Time Shift linearity

- **Resolves:** whether display → stored stays 1:1 across the whole range, which is only known
  today over `project_5`'s ±4 window.
- **Device:** from B0.1. Track 2, pattern 1. Place notes on **steps 1, 3, 5, 7, 9, 11, 13** and set
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
- **Device:** from B0.1. Track 1 in drum mode, an untouched pattern. Place a Kick at beat 1. Set
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
- **Device:** from B0.1. Change **only** the global Swing encoder. Export at three settings: the
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
- **Device:** from B0.1, global swing left at its default. On **Track 2, pattern 1 only**, set the
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
- **Device:** from B0.1. Track 1 in drum mode. Set per-pattern swing to maximum. Export.
- **Capture:** `T7-swing-drum.KeyStepPro`
- **Keys:** `123_114_<pattern>`, `123_116_<pattern>`
- **Confirms if:** it mirrors T7.5 with the drum parameter pair.
- **Falsified if:** it does not — then drum swing needs its own sweep.

### T7.8 — Randomness control

- **Resolves:** whether `113` is play-probability or timing jitter. **This gates Tier 8 entirely.**
  A fresh note defaults to randomness 100, and if that means "randomise timing by 100" then every
  timing measurement in this document is measuring noise.
- **Device:** from B0.1. Track 2, pattern 1, four notes at beats 1, 5, 9, 13, all at default
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

| Test ID | Date | Displayed value / setting | Stored value | Notes |
|---|---|---|---|---|
| B0.1 | | — | | |
| B0.2 | | — | | keys that drift on their own: |
| T1.1 | | fresh note, C3 @ beat 1 | | |
| T1.2 | | pitch E3 | | |
| T1.3 | | velocity 127 | | |
| T1.4 | | deleted | | residue? |
| T2.* | | gate = | | one row per detent |
| T2.y | | drum gate = | | same table as melodic? |
| T3.1 | | track 1 seq mode | | |
| T3.2 | | track 1 drum mode | | bit that moved: |
| T3.3 | | ARP on | | |
| T3.4 | | ARP octave +1 | | |
| D1 | | step 5 toggled off | | **did beat 5 sound?** No |
| D2 | | 3- then 4-note chord | | 4th note went where? |
| D3 | | >64 drum hits | | slot 2 used? Error message on keyboard showed up saying 192 note limit hit when 3 lanes were filled with 64 notes in a single pattern |
| D4 | | lane 1 = 12 steps | | |
| T5.* | | `99` field = | | one row per setting |
| T5.6 | | root note / scale | | |
| T5.7 | | 3-pattern chain | | |
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

| Tier | Captures | Resolves | Milestone |
|---|---|---|---|
| B0 | 2 | noise floor | all |
| 1 | 4 | write-path key set | M4 |
| 2 | ~20 | gate table | M7 |
| 3 | 4 | drum-mode bit | M6 |
| 4 | 8 | step-active semantics, real limits | M6 |
| 5 | ~12 | pattern scalars, chaining | M6 |
| 6 | 2 | standing caveats | M3 |
| 7 | ~13 | Time Shift range, swing semantics | M7, M5 |
| 8 | ~6 recordings | what a Time Shift unit is worth in time | M2, M5 |
| | **~71** | | |

Tiers are ordered by value per capture and each is independently useful — stopping after any tier
leaves a coherent result rather than a half-finished one. B0 is not optional; everything else is.

If time is short, the ranking is **B0 → D1 → Tier 3 → T7.1 → Tier 2 → Tier 1 → rest of Tier 7 →
Tier 4 rest → Tier 6 → Tier 5 → Tier 8**.

- **D1 and Tier 3** are the two places where the current code is arguably *wrong* rather than merely
  incomplete.
- **T7.1 is two captures and jumps the queue** because it is a go/no-go: if the Time Shift range is
  only ±4, the rest of Tier 7's shift work and most of Tier 8 are not worth running at all.
- **T7.5 is the third place the code may be wrong** — `reader._swing` and MCC's own field label
  disagree about whether per-pattern swing is absolute or a signed offset, and no existing test can
  tell, because every sample file is swing-neutral.
- **Tier 8 is last** because it is the only tier needing a recording rig rather than just the device
  and MCC, and because Tier 7 supplies the range it sweeps.
