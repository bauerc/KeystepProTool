# Time shift and swing — still unmeasured

**Spec section:** §6 (excluding §6.1) — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The two timing encodings that remain unmeasured — time shift range and unit, and swing semantics — and why guessing either produces files that load fine and play wrong.
**Related:** Gate length, the third encoding, is measured: see [the gate ladder](./Gate_Length_Ladder.md) for §6.1.

---

## 6. Open questions: the timing encodings

Two encodings remain unmeasured, and both displace a note in time. They are collected here
because one hardware session resolves them — see
[`Timing_Calibration.md`](../Timing_Calibration.md) for the model and
[`Hardware_Test_Protocol.md`](../Hardware_Test_Protocol.md) tiers 7 and 8 for the captures. Gate
length is **resolved** (see [the gate ladder](./Gate_Length_Ladder.md)) and kept in the table for contrast.

| Encoding | Parameters | State | Captures |
|---|---|---|---|
| Gate length | `110` / `118` | **measured** — 128-entry ladder, one derived entry | Tier 2 ✔ |
| Time shift range and linearity | `112` / `120` | centre 49 confirmed; range unknown | T7.1–T7.3 |
| Time shift unit (ticks? ms?) | `112` / `120` | wholly unknown | Tier 8 |
| Swing semantics | `74`, `97` / `114` | **never exercised** in any sample file | T7.4–T7.7 |

**Swing deserves particular caution.** `74` reads 50 and `97` / `114` read 25 in all 16 patterns of
all four tracks of all five sample projects, so there is almost no observational data on it. MCC
labels `97` / `114` a signed offset (−25 %…+25 %) while `ksp.reader._swing` reads them as an
absolute percentage; the two agree only because the global is always 50 here.

Tier 5 supplied the one data point there is, incidentally: `T5-99-swingoffset` moves `124_97_1`
25 → **50**, which is the top of the parameter's range under either reading. It settles that swing
lives in `97` rather than in the `99` bitfield (see [per-pattern scalars](./Parameters_Pattern_Scalars.md)) and nothing more — T7.5 still owns the
semantics.

### Unresolved: how long one time-shift unit is

The *centre* of `112` / `120` is confirmed, so a stored value decodes to a signed shift. What a
shift of ±1 is worth **in time** is not known — presumably a fraction of a step, but nothing
measures it. M2's MIDI export therefore places every note on the flat grid and warns rather than
picking a scale. Protocol tiers 7 and 8: place one note per shift value across a pattern, export
once — the batched method that made tier 2 a single capture — and time the result against an
unshifted note.
