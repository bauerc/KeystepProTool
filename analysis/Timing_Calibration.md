# Timing Calibration: Time Shift and Swing

**Status:** investigation complete, encodings **unmeasured**. This document defines the model and
the experiments; it does not claim a calibration constant.
**Companion:** [`Hardware_Test_Protocol.md`](./Hardware_Test_Protocol.md) — **tiers 7 and 8** are
the captures that produce the missing numbers.
**Prerequisite:** [`KeyStepPro_Format_Spec.md`](./KeyStepPro_Format_Spec.md).

---

## 0. Why this exists

The KeyStep Pro places notes on a step grid, and then offers exactly two ways to move a note
*off* that grid:

| | Parameter | Scope |
|---|---|---|
| **Time Shift** | `112` (Seq) / `120` (DRUM) | **per note** |
| **Swing** | `74` (global), `97` (Seq) / `114` (DRUM) per pattern | **per pattern / project** |

Both displace note onsets in time. Neither is calibrated — we do not know how many ticks or
milliseconds one unit of either is worth. Until that is measured:

- **M2 (`ksp2midi`)** can only write notes hard on the grid, discarding the groove.
- **M5 (`midi2ksp`)** can only quantize hard to the grid, discarding it in the other direction.

This was the same class of problem as the gate length table (spec §6.1) and is governed by the same
rule: **a wrong timing constant produces files that load cleanly and play wrong**, with nothing
to signal the error. So this document measures rather than infers, and the code refuses to
interpolate until the measurements exist.

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

### 1.2 Swing is present but completely unexercised

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

So the centre is 49 and the display maps 1:1 to the stored value **over this window**. That is
the entire evidence base. `initial_project` — real user material — stores `49` for all 405
melodic notes and all 412 drum notes; the encoder was never touched.

**Unknown:** the range (`D_min` / `D_max`), the unit (what one step of the encoder is worth in
time), and whether the mapping stays 1:1 beyond ±4.

### 1.4 Step size and triplet are unexplored

`99` reads `20` in every pattern of every file except two patterns of `initial_project`, which
read `16`. One differing bit across the whole corpus is not enough to decode a five-field
bitfield (triplet, swing offset state, polyrhythm, step size, playback direction — of which only
*"playback direction: bit 5–6"* is documented).

This matters here because the Time Shift unit may be defined *relative to the step*, and the step
duration depends on the step size and the triplet flag. Decoding this bitfield is a prerequisite
for the timing model, and it comes free with the same hardware session.

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

### 2.1 The two unknowns

**`S` — which parameter actually governs swing.** Three candidates, and the capture decides:

1. `74` alone (global only, per-pattern `97` inert),
2. `74 + (97 − 25)` — global plus a signed per-pattern offset,
3. `97 − 25` applied only when the `99` "swing offset state" bit is set, else `74`.

Candidate 3 is the most likely reading of the parameter names, but naming is not evidence.

**`U` — what one Time Shift unit is worth.** Three candidate encodings:

| Model | `U` | Tempo-invariant? | Distinguished by |
|---|---|---|---|
| **A** — fraction of a step | `t_step / N` | yes | changing **step size** |
| **B** — fixed clock ticks | `k` ticks, independent of step size | yes | changing **step size** |
| **C** — absolute time | `k` milliseconds | **no** | changing **BPM** |

**A and B are both tempo-invariant**, so BPM alone cannot separate them; the step-size lever does
that. BPM separates C from the other two. **Both levers are required.** This is the central
analytical point of the investigation.

### 2.2 A falsifiable prediction

`112` is a 7-bit field centred on 49. If the range is symmetric — `D` ∈ [−49, +49] — and model A
holds with `N` = 98, then `D_max * U` is *exactly* half a step: Time Shift would cover the entire
gap between adjacent steps with no unreachable band, which is a coherent thing for a designer to
choose (a full step of shift would be ambiguous with the neighbouring step).

The opposite outcome matters more. If the range is only ±4, as `project_5` weakly hints, Time
Shift spans roughly ±4 % of a step and is **useless as a quantization target** — M5 would snap to
the grid and report the timing loss rather than pretend to represent it. **Measuring the range is
therefore the first experiment and the cheapest**, because it decides whether the rest is worth
doing.

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
  melodic parameters must be swept separately. This also resolves, as a byproduct, the recorded
  discrepancy where `project_5_description.txt` gives Time Shift −1 for both kicks while the file
  stores −1 and +1 (spec §5).

---

## 6. Open questions, in priority order

All test IDs refer to [`Hardware_Test_Protocol.md`](./Hardware_Test_Protocol.md).

| # | Question | Resolved by | Blocks |
|---|---|---|---|
| 1 | Time Shift range `D_min` / `D_max` | **T7.1** (2 captures) | whether shift is worth implementing at all |
| 2 | Is display→stored 1:1 across the whole range? | **T7.2** (1 capture) | shift encode/decode |
| 3 | Is `randomness` probability or timing jitter? | **T7.8** | the validity of every timing measurement |
| 4 | Which parameter governs effective swing (`S`) | **T7.4–T7.6** | swing encode/decode, and `reader._swing` |
| 5 | Does drum shift/swing match melodic? | **T7.3**, **T7.7** | the drum path in M5/M6 |
| 6 | `99` / `116` bit layout — step size, triplet, polyrhythm, direction | **T5.1–T5.5** (already planned) | `t_step`, hence everything here |
| 7 | Time Shift unit `U`, and which of models A/B/C | **Tier 8**, recordings R1–R3 | accurate placement both directions |
| 8 | Do swing and shift add, or interact? | **Tier 8**, recording R5 | the M5 fitting algorithm |

### 6.1 Tier 8 Recording Capture Ledger

R1 Results - Shift 0, 1, 25, 50, 0, -1, -25, -49
```
pairs            8
tempo            30 BPM, 480 ticks/beat (4.1667 ms/tick)
offset (ticks)   mean -0.38   sd 32.99   min -60   max +58
offset (ms)      mean -1.56   sd 137.45
```

R2 Results - Shift 50
```
pairs            8
tempo            120 BPM, 480 ticks/beat (1.0417 ms/tick)
offset (ticks)   mean -59.00   sd 0.00   min -59   max -59
offset (ms)      mean -61.46   sd 0.00
```

R3 Results - Shift 50
```
pairs            32
tempo            30 BPM, 480 ticks/beat (4.1667 ms/tick)
offset (ticks)   mean +56.25   sd 20.88   min -60   max +60
offset (ms)      mean +234.38   sd 87.00
```

R4 Results - Track Swing 50% (only used even notes 2, 6, etc).
```
pairs            8
tempo            30 BPM, 480 ticks/beat (4.1667 ms/tick)
offset (ticks)   mean +0.00   sd 0.00   min +0   max +0
offset (ms)      mean +0.00   sd 0.00
```

R4 Results - Track Swing 63% (only used even notes 2, 6, etc).
```
pairs            8
tempo            30 BPM, 480 ticks/beat (4.1667 ms/tick)
offset (ticks)   mean -31.00   sd 0.00   min -31   max -31
offset (ms)      mean -129.17   sd 0.00
```

R4 Results - Track Swing 75% (only used even notes 2, 6, etc).
```
pairs            8
tempo            30 BPM, 480 ticks/beat (4.1667 ms/tick)
offset (ticks)   mean -60.00   sd 0.00   min -60   max -60
offset (ms)      mean -250.00   sd 0.00
```

R5 Results - Track Swing 75% and Timeshift 50
```
pairs            8
tempo            30 BPM, 480 ticks/beat (4.1667 ms/tick)
offset (ticks)   mean -120.00   sd 0.50   min -121   max -119
offset (ms)      mean -500.00   sd 2.08
```

R6 Results
```
pairs            8
tempo            30 BPM, 480 ticks/beat (4.1667 ms/tick)
offset (ticks)   mean -0.38   sd 32.99   min -60   max +58
offset (ms)      mean -1.56   sd 137.45
```
### One loose end this investigation turned up

**`src/ksp/reader.py::_swing` may be wrong.** It computes `stored + 25`, treating `97` / `114` as an
absolute percentage (default 25 → 50 %). MCC's field label calls it a **signed offset**, −25 % to
+25 %. If it is an offset from the global `74`, `seq_swing_percent` is wrong whenever the global is
not 50. The two readings coincide at the defaults, which is exactly why no test catches it and why
every swing-neutral sample file hides it. **T7.5 decides this.**

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
