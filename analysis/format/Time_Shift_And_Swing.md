# Time shift and swing

**Spec section:** §6 (excluding §6.1) — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The two encodings that displace a note in time — time shift and swing — what tier 7 measured about each, and the one quantity still missing.
**Related:** Gate length, the third encoding, is measured: see [the gate ladder](./Gate_Length_Ladder.md) for §6.1.

---

## 6. The timing encodings

Three encodings move a note. Gate length is **resolved** (see [the gate ladder](./Gate_Length_Ladder.md)); the other two were
measured by protocol tier 7 on 2026-08-05, except for one quantity that no export can carry —
what a shift unit is worth **in time** — which needs a recording of the device rather than a file.
See [`Timing_Calibration.md`](../Timing_Calibration.md) for the model.

| Encoding | Parameters | State |
|---|---|---|
| Gate length | `110` / `118` | **measured** — 128-entry ladder, one derived entry |
| Time shift range and linearity | `112` / `120` | **measured** — centre 49, stored 0–99, linear throughout |
| Swing value and scope | `74`, `97` / `114` | **measured** — absolute percentage, 50–75 %, per pattern |
| Time shift unit (ticks? ms?) | `112` / `120` | **open** — tier 8, needs a recording |
| How global and per-pattern swing combine | `74` with `97` / `114` | **open** — see §6.3 |

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

**Still open: how the two combine.** `74` and `97` are independent stored values, and nothing yet
says whether the device adds them, lets the pattern override the project, or ignores one. The
capture meant to settle it (`T7-swing-both`) is byte-identical to `T7-swing-global-75` — the
per-pattern value was never carried into it — so T7.6's stated question went unanswered. Until a
capture that really holds both non-default values exists, `ksp2midi` applies the per-pattern value
and **reports the global rather than folding it in** (`global-swing-not-applied`).

### 6.4 Unresolved: how long one time-shift unit is

The centre, range and linearity of `112` / `120` are measured, so a stored value decodes to a
signed shift. What that shift is worth **in time** is not in the file at all — it may be a fraction
of a step, a fixed tick count, or an absolute duration, and only recording the device's MIDI output
separates the three. `ksp.constants.TIME_SHIFT_UNIT` stays `None` until then, M2 places every note
on the flat grid and warns, and **no formula is fitted to a plausible-looking pattern**: a wrong
timing constant produces files that load cleanly and play wrong, with nothing to signal the error.
