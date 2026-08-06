# Time shift and swing

**Spec section:** §6 (excluding §6.1) — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The two encodings that displace a note in time — time shift and swing — what each stores and what one unit of it is worth in time.
**Related:** Gate length, the third encoding, is measured: see [the gate ladder](./Gate_Length_Ladder.md) for §6.1.

---

## 6. The timing encodings

Three encodings move a note, and all three are now measured. Gate length is in [the gate
ladder](./Gate_Length_Ladder.md); the stored form of the other two came from protocol tier 7 on
2026-08-05, and the one quantity no export can carry — what a shift unit is worth **in time** —
from tier 8's recordings on 2026-08-04. See [`Timing_Calibration.md`](../Timing_Calibration.md) for
the model and the raw readings.

| Encoding | Parameters | State |
|---|---|---|
| Gate length | `110` / `118` | **measured** — 128-entry ladder, one derived entry |
| Time shift range and linearity | `112` / `120` | **measured** — centre 49, stored 0–99, linear throughout |
| Swing value and scope | `74`, `97` / `114` | **measured** — absolute percentage, 50–75 %, per pattern |
| Time shift unit | `112` / `120` | **measured** — 1/400 of a beat, fixed; see §6.4 |
| How global and per-pattern swing combine | `74` with `97` / `114` | **measured** — per-pattern wins; see §6.3 |

### 6.2 Time shift is a plain offset, and the drum field shares it

`stored = 49 + displayed`, exactly, across the whole encoder travel. Tier 7 confirmed it at twelve
points:

| Displayed | −49 | −25 | −1 | 0 | +1 | +25 | +50 |
|---|---|---|---|---|---|---|---|
| Stored (`112`) | 0 | 24 | 48 | 49 | 50 | 74 | 99 |

- **Range:** displayed **−49 … +50**, in steps of 1, so stored spans **0–99**. Asymmetric by one:
  there is no displayed −50, and the field's remaining 100–127 is unreachable from the front panel.
- **Linear throughout.** No compression at the extremes — the trap gate fell into. This is an
  offset, not a ladder, so it needs no lookup table.
- **`120` is identical to `112`** (T7.3), same centre and same range, so one decoder serves both.

Captures `T7-shift`, `T7-shift-linearity`, `T7-drumshift`. The earlier worry that the range might
be only ±4 — all `project_5` ever showed — is settled: it is ±49-ish, so shift covers essentially
the whole gap to the neighbouring step and **is** a usable quantization target for M5.

> `T7-shift` was taken on Track 1 in sequencer mode rather than Track 2 as its procedure said.
> `112` behaves identically on any item, and `T7-shift-linearity` covers Track 2 properly, so the
> reading stands; noted because the capture name implies otherwise.

### 6.3 Swing is an absolute percentage, stored per pattern

MCC's dictionary labels `97` / `114` *"swing (%) (an offset of 25 is applied to be send by MIDI)
(−25 % to +25 %)"* — a **signed offset**. The hardware disagrees: the display reads an absolute
50–75 %, and at the encoder's maximum `124_97_1` stores **50**. So `stored + 25` is the percentage
and `ksp.reader._swing` was right; **MCC's own field label is wrong.** This is the second time the
dictionary has misdescribed a field it names (see [corrections and prior art](./Corrections_And_Prior_Art.md)).

| Parameter | Scope | Stored | Displayed |
|---|---|---|---|
| `74` | project | the percentage directly | 50–75 % |
| `97` / `114` | **one pattern of one track** | percentage − 25, so 25 → 50 % | 50–75 % |

- **50 % is straight, and is both the default and the minimum.** The encoder will not go below it,
  so swing only ever delays; there is no negative-shuffle end to represent.
- **Only the even-numbered steps move** (steps 2, 4, … as the device counts them). Odd steps stay
  exactly on the beat. Confirmed by ear in T7.6, and it is what `midi_export._swing_delay` already
  does — `Note.step` is 1-based, so its `step % 2` test lands on the right half of each pair.
- **The scope is per pattern, not per track.** The device's display groups swing under a "Track"
  heading, which reads as per-track, but the file says otherwise: setting it on one pattern moved
  `124_97_1` alone and left patterns 2–16 and every other track untouched. The bytes decide the
  format question; the display grouping is a UI convention. Same result on the drum side (T7.7).
- **`99` / `116` carries no swing-override flag.** `124_99_1` held its value while swing moved, so
  the dictionary's "swing offset state" is not a bit there — consistent with what tier 5 found (see [per-pattern scalars](./Parameters_Pattern_Scalars.md)).

Captures `T7-swing-global-63`, `T7-swing-global-75`, `T7-swing-pattern-max`, `T7-swing-drum`.

**How the two combine: the per-pattern value wins.** `74` and `97` are independent stored values,
and the device gives `97` precedence. Established at the device (T7.6): with a track set to 75 % the
pattern plays at 75 % whether the global sits at its default 50 % or is raised to 75 % as well. The
global does not add to it and does not override it.

They are **not** independent on the display, which shows the global and Track figures together as
one linked readout — which is what makes this easy to mis-read as a single value. The file settles
the format question: they are two keys and each moves alone.

So `ksp2midi` applies the per-pattern value and **reports a non-default global rather than folding
it in** (`global-swing-not-applied`), which matches what the hardware plays rather than merely
being cautious.

> Not exercised: a non-default global with the track left at its 50 % default. Precedence as stated
> makes that straight, and since 50 % is also the track minimum there is no "unset" track value for
> the global to fall through to.

`T7-swing-both`, the capture meant to hold both values, is byte-identical to `T7-swing-global-75` —
the per-pattern value never made it in. The question was answered by ear instead, so the capture is
no longer owed.

### 6.4 One time-shift unit is 1/400 of a beat

Measured by protocol tier 8 on 2026-08-04, recordings R1–R3 and R6. This is the quantity no export
can carry, so it came from recording the device's MIDI output against a reference track on a second
channel — every figure is a difference between the two, which cancels interface latency and clock
drift.

```
one unit  = 1/400 of a quarter note = 1.2 ticks at 480 PPQN
max (+50) = 60 ticks = a 1/32 note
```

**Positive shift delays.** The measured sweep, at 480 ticks per beat:

| Displayed | −49 | −25 | −1 | 0 | +1 | +25 | +50 |
|---|---|---|---|---|---|---|---|
| Offset (ticks) | −58 | −30 | −1 | 0 | +1 | +30 | +60 |

The two negative extremes came back a tick short of their mirror, which is inside the ±1-tick
jitter the reference track itself shows.

**It is a fraction of the beat, not of the step.** That is the whole finding, and it took two step
sizes to see: a displayed +50 moved a note 60 ticks at a 1/4 step (R1) and 60 ticks again at a 1/16
step (R3). A tempo change leaves the tick count alone too (R2, 120 BPM, +59), so it is not an
absolute duration either. R6 reproduced R1 exactly.

> **The trap.** At the device's default 1/16 grid the maximum shift is exactly half a step, so a
> step-relative reading fits every sample project in this repository and is still wrong. It
> diverges at every other step size — at 1/4 the maximum is an eighth of a step, and **at 1/32 it
> is a whole step**, enough to land a note on top of its neighbour. Any code clamping shift must
> account for that rather than assuming half a step.

`ksp.constants.TIME_SHIFT_UNITS_PER_BEAT` holds the 400 and `time_shift_ticks` applies it; 480 is
not divisible by 400, so each note's displacement rounds, by under half a tick and without
accumulating. `ksp2midi` applies the shift by default and `--no-time-shift` returns the flat grid.

**Swing was confirmed in the same session.** At a 1/16 step, 63 % delayed the even steps by 31
ticks and 75 % by 60 — exactly what the standard formula gives (`t_step × (2S/100 − 1)`), so
`midi_export._swing_delay` is measured rather than assumed. R5 set swing and shift together and got
their exact sum, so **the two are additive**. Both were measured at one step size only; whether the
swing displacement is step-relative is untested.
