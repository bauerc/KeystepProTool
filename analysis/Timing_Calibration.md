# Timing Calibration: Time Shift and Swing

**Status:** **complete.** The stored encodings were measured by tier 7 (2026-08-05) and the unit —
what one time-shift step is worth in time — by tier 8 (2026-08-04). This document carries the model,
the experiments and the raw readings; the findings themselves are in
[the spec](./format/Time_Shift_And_Swing.md).
**Companion:** [`Hardware_Test_Protocol.md`](./Hardware_Test_Protocol.md), which now holds no
timing work: both tiers are closed and removed.
**Prerequisite:** [`KeyStepPro_Format_Spec.md`](./KeyStepPro_Format_Spec.md).

---

## 0. Why this exists

The KeyStep Pro places notes on a step grid, and then offers exactly two ways to move a note
*off* that grid:

| | Parameter | Scope |
|---|---|---|
| **Time Shift** | `112` (Seq) / `120` (DRUM) | **per note** |
| **Swing** | `74` (global), `97` (Seq) / `114` (DRUM) per pattern | **per pattern / project** |

Both displace note onsets in time, and for a long while neither was calibrated: nothing said how
many ticks or milliseconds one unit of either was worth. While that held, **M2 (`ksp2midi`)** could
only write notes hard on the grid and **M5 (`midi2ksp`)** could only quantize hard to it.

Both are now measured — tier 7 for what the file stores, tier 8 for what it is worth in time — and
`ksp2midi` applies the shift. M5's inverse, fitting a residual back onto per-note shift, is the
piece still to be built (§3.2).

This was the same class of problem as the gate length table (spec §6.1) and was governed by the same
rule: **a wrong timing constant produces files that load cleanly and play wrong**, with nothing
to signal the error. So this document measures rather than infers, and the code refused to
interpolate until the measurements existed.

Gate has since been resolved, and how is worth carrying over: the six scattered points looked like
a non-linear curve and invited a formula, but they were really six samples of an **index** —
`stored = detent − 1`. The lesson for shift and swing is that a sparse sample of a monotonic
encoder tells you almost nothing about the encoding until you have a *consecutive* run of it.

---

## 1. What the files already tell us

Everything in this section is re-derivable from `project_files/` and MCC's
`KeyStepPro.json`; see §7.

### 1.1 There is no Glide

For the record, since it comes up: **the KeyStep Pro has no glide, slide, or portamento
parameter.** It does not appear in any of the 205 entries of `fields[]` in MCC's
`KeyStepPro.json`, nor in `globalFields` (the device-global set — CV outputs, knob assignments,
velocity/aftertouch curves), nor anywhere under
`/Library/Arturia/MIDI Control Center/Resources/` except MatrixBrute's own GUI resources.
Arturia's own forum confirms the hardware has no per-step slide.

The closest available behaviour is a **gate of one step or longer**, which overlaps the next
note so that an *external* monophonic synth applies its own portamento. That is gate length
(`110` / `118`), now measured (spec §6.1), not a separate parameter.

### 1.2 Swing was completely unexercised — until tier 7 exercised it

> **Measured 2026-08-05.** Everything in this subsection describes the state of the *corpus*, which
> is still swing-neutral and still useful as a baseline. The questions it raises are answered in
> [the spec](./format/Time_Shift_And_Swing.md): `97` / `114` hold an **absolute** percentage
> (50–75 %, stored +25 offset) **per pattern**, MCC's "signed offset" label is wrong, and only the
> even-numbered steps are displaced. What remains open is how `74` combines with `97`.


| Parameter | Meaning | Observed |
|---|---|---|
| `74` | Global swing % | `50` in **all five** sample projects |
| `97` / `114` | Per-pattern Seq / DRUM swing, stored with a **+25 offset** | `25` (= zero offset) in **all** 16 patterns of **all** four tracks of **all five** projects |
| `99` / `116` bit | "Swing offset state" — named by MCC, bit position undocumented | unvaried |

MCC labels `97` / `114` as *"Pattern Seq swing (%) (an offset of 25 is applied to be send by
MIDI) (−25% to +25%)"*. The KeyStep Pro manual gives the swing range as **50 %–75 %**, where
50 % is straight, which fits `74` holding the percentage directly.

> **Every sample project in this repository is swing-neutral**, verified exhaustively — no
> exceptions across 320 per-pattern values plus the global. There is *zero* observational data on
> swing here. Unlike most of this format, swing **cannot be decoded from the files we have.** It
> requires new hardware exports.

### 1.3 Time Shift has one ramp and no scale

The only non-default Time Shift values anywhere in the corpus are `project_5`'s Track 3 ramp,
documented in `project_5_description.txt` and confirmed on the hardware display:

| Displayed | −4 | −3 | −2 | −1 | 0 | +1 | +2 | +3 | +4 |
|---|---|---|---|---|---|---|---|---|---|
| Stored (`112`) | 45 | 46 | 47 | 48 | 49 | 50 | 51 | 52 | 53 |

So the centre is 49 and the display maps 1:1 to the stored value **over this window**. That was
the entire evidence base until tier 7. `initial_project` — real user material — stores `49` for all
405 melodic notes and all 412 drum notes; the encoder was never touched.

**Measured 2026-08-05 (T7.1–T7.3):** the range is displayed **−49 … +50** (stored **0–99**) and the
1:1 mapping holds across all of it, with no compression at the extremes. Drum `120` is identical.
The ±4 window was not the limit — it was just all anyone had happened to set. See
[the spec](./format/Time_Shift_And_Swing.md).

**Measured 2026-08-04 (tier 8):** the unit `U` is **1/400 of a beat** — 1.2 ticks at 480 PPQN, so
the full +50 is 60 ticks, a 1/32 note. It is not recoverable from any export; it took a recording.

### 1.4 Step size and triplet are measured

**Resolved by tier 5**, 2026-08-04. `99` reads `20` in every pattern of every file except two
patterns of `initial_project`, which read `16` — one differing bit across the whole corpus, far
too little to decode at the desk. The captures decoded it: **step size at bits 3–4** (0 = 1/4,
1 = 1/8, 2 = 1/16, 3 = 1/32) and **triplet at bit 0**, with the drum field `116` sharing the
layout. Spec §3.3 carries the measurement; `ksp.model.PatternBits` carries the decode.

This mattered here because the Time Shift unit may be defined *relative to the step*, and the step
duration depends on both. `t_step` in §2 now has its inputs, and every sample project turns out to
sit at 1/16 with no triplet — so the corpus gives one step size and tier 8 must not assume it
generalises without checking the pattern it is recording.

### 1.5 There is no reference render to diff against

MCC has no MIDI export for the KeyStep Pro — confirmed in the UI, and the evidence is in spec §1.
So `ksp2midi` is the only MIDI writer that exists for this device, and the sole ground truth for
timing is the hardware's own MIDI output. That is why tier 8 has to *record* the device rather than
compare two files.

---

## 2. The model

For a note on 0-based step `n`, with `D` = time shift and `S` = effective swing percentage:

```
t_step  = ticks_per_beat * 4 / step_denominator * (2/3 if triplet)

onset   = n * t_step  +  d_swing(n)  +  d_shift(D)

d_swing(n) = 0                            if n is even
           = (S - 50) / 100 * 2 * t_step  if n is odd

d_shift(D) = D * U                        where D = stored - 49
```

Sanity check on the swing term: at `S` = 75 % the odd steps land half a step late, which is the
standard maximum shuffle. At `S` = 50 % the term vanishes.

### 2.1 The two unknowns, and how they came out

**`S` — which parameter actually governs swing.** Three candidates:

1. `74` alone (global only, per-pattern `97` inert),
2. `74 + (97 − 25)` — global plus a signed per-pattern offset,
3. `97 − 25` applied only when the `99` "swing offset state" bit is set, else `74`.

**Resolved: `S` is the per-pattern value.** Tier 7 knocked out **candidate 3** — there is no swing
bit in `99` / `116`; it does not move when swing does — and disproved candidate 2's premise by
showing `97` holds an absolute percentage rather than a signed offset. T7.6 knocked out
**candidate 1** at the device: a track set to 75 % plays at 75 % with the global at its default
50 %, so `97` is plainly not inert. Raising the global to 75 % as well changes nothing, so the two
do not add either.

**The per-pattern value takes precedence over the global, always.** `S = 97 + 25`, and `74` is not
consulted. `midi_export._swing_delay` already reads it that way.

The capture that was supposed to settle this (`T7-swing-both`) is byte-identical to
`T7-swing-global-75`, so it never held both values; the answer came from listening instead, which
is the ground truth this project runs on anyway.

**`U` — what one Time Shift unit is worth.** Three candidate encodings:

| Model | `U` | Tempo-invariant? | Distinguished by |
|---|---|---|---|
| **A** — fraction of a step | `t_step / N` | yes | changing **step size** |
| **B** — fixed clock ticks | `k` ticks, independent of step size | yes | changing **step size** |
| **C** — absolute time | `k` milliseconds | **no** | changing **BPM** |

**A and B are both tempo-invariant**, so BPM alone cannot separate them; the step-size lever does
that. BPM separates C from the other two. **Both levers are required.** This is the central
analytical point of the investigation, and pulling both is what tier 8 did:

**`U` came out as model B — a fixed `k` = 1/400 of a beat**, 1.2 ticks at 480 PPQN. R2 pulled the
tempo lever and the tick count held, killing C; R1 against R3 pulled the step-size lever and the
tick count held again, killing A. Had only the tempo lever been pulled, A would have survived and
fitted every file in the corpus (§2.2).

### 2.2 A falsifiable prediction — and how it came out

`112` is a 7-bit field centred on 49. The prediction was that if the range came out near-symmetric
and model A held with `N` ≈ 98, then `D_max * U` would be *exactly* half a step: Time Shift would
cover the whole gap between adjacent steps with no unreachable band, which is a coherent thing for
a designer to choose (a full step of shift would be ambiguous with the neighbouring step).

**The range came out −49 … +50** (T7.1), which is that shape, off-centre by one detent — so the
half-step reading survived T7 and model A looked like the natural candidate.

**Tier 8 falsified it.** The prediction was half right in the most misleading way available: at the
device's default 1/16 step the maximum shift really is exactly half a step, which is why model A
fits every sample project in the corpus. But R1 at a 1/4 step and R3 at a 1/16 step both displaced
a +50 note by the same **60 ticks**, so the unit does not scale with the step at all. **Model B**:
a fixed 1/400 of a beat. At 1/4 the maximum is an eighth of a step, and at 1/32 it is a whole one.

The lesson is the same one gate taught (§0): a quantity sampled at a single setting of the lever
that matters will fit whatever curve you had in mind.

The outcome that would have mattered more did not happen: had the range been only ±4, as
`project_5` weakly hinted, Time Shift would span roughly ±4 % of a step and be **useless as a
quantization target**, and M5 would have had to snap to the grid and report the loss. Measuring the
range first was the cheap way to find that out, and it came back saying the rest is worth doing.

---

## 3. Using the model in both directions

### 3.1 Forward — `ksp2midi` (M2)

Apply the equation directly. Two decisions worth recording:

- **Bake swing into note positions.** MIDI has no portable representation of swing; a DAW that
  reopens the file must see the groove in the note times or not at all.
- **Preserve the source swing % in a text or track-name meta event**, so the information survives
  a round trip even though it is no longer structural.

### 3.2 Inverse — `midi2ksp` (M5)

This is the "quantize an arbitrary MIDI file" algorithm. What makes it tractable is that the two
parameters have **different scopes**: swing is one value for a whole pattern, shift is per note.
So fit them in that order.

1. Snap each onset to its nearest step; keep the residual `r_n`.
2. **Estimate swing once, from the aggregate:** median residual over *odd* steps minus median
   over *even* steps, then invert the swing term. Clamp to the device range and round to a
   storable value.
3. **Give the leftover to Time Shift, per note:**
   `D = clamp(round((r_n − d_swing(n)) / U), D_min, D_max)`.
4. **Report every residual that could not be represented.** Never silently absorb timing error —
   the user should be told which notes moved and by how much.

Fitting swing first is what stops the converter from spending scarce per-note shift budget on a
systematic groove that one pattern-level value expresses for free.

---

## 4. Does BPM come into it?

The question that prompted this document, answered directly.

**As a mechanism for encoding these values — no, with one caveat.**

- **Swing is a ratio** of a subdivision, tempo-invariant by construction. Supplying a BPM changes
  nothing about how swing is stored or applied.
- **Time Shift is unknown**, and that is exactly what the two-BPM experiment settles. Under models
  A and B, BPM is equally irrelevant to the encoding. Only under model C — absolute milliseconds
  — would a BPM be required to interpret a stored shift, and in that case conversion becomes
  tempo-locked and lossy whenever the tempo changes.

**As converter input — needed, but for a different reason than timing.** MIDI tick positions are
tempo-free, so BPM is not needed to *place* notes. It is needed to write the tempo meta event,
and the project already stores it in `70`–`72` (decoded in M1, BPM × 100 little-endian). The one
place BPM genuinely bites is the reverse direction:

> **The KeyStep Pro has a single project tempo and cannot follow a tempo map.** `midi2ksp` should
> adopt the source MIDI's initial tempo, accept a `--bpm` override, and warn loudly when the input
> contains tempo changes, because those cannot be represented at all.

**As an experimental lever — essential.** The measurement is only possible at a slow tempo:

| Tempo | Step size | Step duration | One unit if model A, `N` = 98 |
|---|---|---|---|
| 120 BPM | 1/16 | 125 ms | **≈ 1.3 ms** — at or below USB-MIDI jitter |
| 30 BPM | 1/4 | 2000 ms | **≈ 20 ms** — trivially resolvable |

**Slow tempo plus a large step size is what makes this measurable at all**, and is the strongest
argument for building test projects specifically for it rather than reusing existing material.

**Do new test projects with specific BPM help?** Yes, with one structural caveat: **BPM is
project-level** (`70`–`72`), so the BPM axis needs either separate project files or a live tempo
change on the device. Live is fine — the project file is the *stimulus*, the capture is the
*measurement*, so one project can be played at several tempi. Everything else — swing, shift,
step size, triplet — is per-pattern, so the whole remaining matrix fits inside one project's 16
patterns. **Budget: about 13 export captures (Tier 7) plus 6 recordings (Tier 8).**

Note the test projects must be **built by hand on the device and exported through MCC**, exactly
as `project_9` was. The writer is proven now, but using it to produce the stimulus for a hardware
measurement would confound the experiment with our own bugs: the point of a capture is that the
device, not this tool, decided what the file says.

---

## 5. How this measurement goes quietly wrong

Controls the protocol must apply:

- **Swing and Time Shift both displace onsets and are indistinguishable in a single capture.**
  Vary one at a time. Place every shift sweep on **0-based even steps**, which swing does not
  touch, so a stray swing setting cannot contaminate the shift numbers.
- **Randomness defaults to 100 and its semantics are unverified.** If it is play-probability, 100
  is safe. If it randomises timing, it destroys every measurement here. **The first capture is a
  control**: record the same bar eight times at defaults and check onset variance. Do not proceed
  until this is settled.
- **Never measure absolute onsets.** Interface latency and clock drift are unknown and drift
  between takes. Run a **reference track** — all defaults, swing 0, shift 0 — on its own MIDI
  channel alongside the test track, and take every measurement as a *difference* between the two.
  Latency and drift cancel exactly.
- **Gate affects note-off only**, so it cannot contaminate onset measurements. That is why the
  gate table was captured in the same session for free (spec §6.1, tier 2 — now done).
- **Track 1 in DRUM mode uses the parallel parameter set** (`120` shift, `114` swing), so drum and
  melodic parameters must be swept separately.

---

## 6. Questions this milestone opened, and what answered them

**All nine are closed.** The table is kept as the record of what was asked and what settled it —
the "resolved by" column is the evidence, not a status board. All test IDs refer to
[`Hardware_Test_Protocol.md`](./Hardware_Test_Protocol.md).

| # | Question | Resolved by | Blocks |
|---|---|---|---|
| 1 | Time Shift range `D_min` / `D_max` | **T7.1** ✅ −49…+50 (stored 0–99) | whether shift is worth implementing at all |
| 2 | Is display→stored 1:1 across the whole range? | **T7.2** ✅ yes, exactly | shift encode/decode |
| 3 | Is `randomness` probability or timing jitter? | **T7.8** ✅ probability; no jitter | the validity of every timing measurement |
| 4 | Is per-pattern swing absolute or a signed offset? | **T7.5** ✅ absolute 50–75 %, per pattern | `reader._swing` — confirmed right |
| 5 | Does drum shift/swing match melodic? | **T7.3**, **T7.7** ✅ identical | the drum path in M5/M6 |
| 6 | `99` / `116` bit layout — step size, triplet, polyrhythm, direction | **T5.1–T5.5** ✅ **measured** (spec §3.3) | `t_step`, hence everything here |
| 7 | Time Shift unit `U`, and which of models A/B/C | **Tier 8** ✅ model **B**, 1/400 beat | accurate placement both directions |
| 8 | Do swing and shift add, or interact? | **Tier 8** ✅ they add, exactly (R5) | the M5 fitting algorithm |
| 9 | How do global `74` and per-pattern `97` combine? | **T7.6** ✅ per-pattern takes precedence | whether `ksp2midi` may apply the global at all |

Question 9 was the last of the old "which parameter governs `S`", and it closes the list: the
per-pattern value wins outright, so `ksp2midi` applies it and reports a non-default global rather
than folding it in. **Every question in this table is now answered.**

### 6.1 Tier 8 recording ledger

Six recordings, 2026-08-04, all at 480 ticks per beat. Reference track on channel 2 (Track 3, every
parameter at its default), test track on channel 1 (Track 2). **Offsets are test − reference, so a
positive number means the note played late.**

| ID | BPM | Step | Varying | Measured offset (ticks) |
|---|---|---|---|---|
| R1 | 30 | 1/4 | shift 0, +1, +25, +50, 0, −1, −25, −49 | 0, +1, +30, +60, 0, −1, −30, −58 |
| R2 | 120 | 1/4 | shift +50 | +59 on all 8, sd 0 |
| R3 | 30 | 1/16 | shift +50 | +60 on all 32, sd 0 |
| R4 | 30 | 1/16 | track swing 50 % / 63 % / 75 %, even steps | 0 / +31 / +60, sd 0 |
| R5 | 30 | 1/16 | swing 75 % **and** shift +50 | +120, sd 0 |
| R6 | 30 | 1/4 | repeat of R1 | identical to R1 |

**What each one settles.** R1 against R3 is the whole result: the same +50 displaces a note by 60
ticks at both a 1/4 and a 1/16 step, so the unit is a fixed count and not a fraction of the step.
R2 holds the tick count across a fourfold tempo change, ruling out an absolute duration — 60 ticks
is 250 ms at 30 BPM and 61 ms at 120. R6 reproduces R1 exactly, so the rig was not drifting. R4
matches `t_step × (2S/100 − 1)` at both non-default settings (75 % → 60, 63 % → 31.2 → 31). R5 is
the sum of its two parts to the tick, so swing and shift are additive.

The one-tick shortfalls — R2's +59 where R1 gives +60, and R1's −58 and −30 against a mirror of −59
and −30 — sit inside the ±1-tick jitter the reference track shows on its own onsets.

#### Two defects in the first reduction, both fixed

Recorded because the numbers they produced were written down and believed for a while.

- **`tools/reduce_timing.py` mis-paired at half a step.** It matched each test note to the *nearest*
  reference, and at R3's 120-tick step a 60-tick displacement is exactly equidistant between two of
  them. R3's true reading is +60 on all 32 notes; the tool reported mean +56.25, sd 20.88, min −60,
  and its own "spread exceeds one tick" warning was read as jitter rather than as a pairing
  failure. It now refuses an equidistant match and says why.
- **Every sign was inverted.** The tool computes `test − reference`, but the run passed the
  reference channel as `--test-channel`. That is what made the first ledger read "+50 shift → −60
  ticks", i.e. a positive shift playing a note *early*. The `--ref-channel` help now says which
  track is which.

### One loose end this investigation turned up — now closed

**`src/ksp/reader.py::_swing` was right.** It computes `stored + 25`, treating `97` / `114` as an
absolute percentage (default 25 → 50 %), while MCC's field label calls it a **signed offset**,
−25 % to +25 %. The two readings coincide at the defaults, which is why no test caught it and every
swing-neutral sample file hid it. T7.5 settled it: the device displays an absolute 50–75 % and
stores 50 at the maximum, so the reader's arithmetic holds and **the dictionary label is wrong.**

(A `--time-shift approx` flag was considered for M2 and deliberately not shipped: there is no
documented guess to opt into until tier 8 measures the unit.)

---

## 7. Reproducing the findings in this document

```python
from ksp.lenient_json import load_path

proj = load_path("project_files/project_5.KeyStepPro")

# The Time Shift ramp: Track 3 (item 125), pattern 1, slot 1, notes 1-9.
print([proj[f"125_112_1_1_{i}"] for i in range(1, 10)])   # 50 51 52 53 48 47 46 45 49

# Swing neutrality, across every pattern of every track of every file.
print(proj["120_74"])                                      # 50  (global, straight)
print({proj[f"{it}_97_{p}"] for it in (123, 124, 125, 126) for p in range(1, 17)})  # {25}
```

Or run the tool, which does this across a whole directory and diffs two files:

```sh
uv run python tools/timing_diff.py project_files/*.KeyStepPro
uv run python tools/timing_diff.py --diff project_files/Default.KeyStepPro \
                                          project_files/project_5.KeyStepPro
```
