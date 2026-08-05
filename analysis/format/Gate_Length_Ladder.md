# The gate length ladder

**Spec section:** §6.1 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** Gate length as a 128-rung index ladder, `stored = detent − 1`, measured across 0.0625–64 steps and identical on the drum side.
**Related:** The unmeasured half of §6 is in [time shift and swing](./Time_Shift_And_Swing_Unmeasured.md).

---

### 6.1 Gate length

**Measured, 2026-07-31.** Capture `T2-gate-table.KeyStepPro`, protocol tier 2; the full ladder is
in `analysis/gate_ladder.txt`.

**The encoding is an index, not a curve.** `stored = detent index − 1` — the stored value is the
0-based position in the encoder's ladder. Every bit of the non-linearity lives in the *display*.
The earlier `stored = 8·g + 3` / `4·g` piecewise reading was an artefact of fitting six scattered
points as though they described the encoding; it is superseded.

The display ladder is five constant-increment runs, closing exactly on the 7-bit boundary:

| Increment | Display span | Stored | Count |
|---|---|---|---|
| 1/16 | 0.0625 → 0.5 | 0–7 | 8 |
| 1/8 | 0.625 → 3 | 8–27 | 20 |
| 1/4 | 3.25 → 8 | 28–47 | 20 |
| 1/2 | 8.5 → 32 | 48–95 | 48 |
| 1 | 33 → 64 | 96–127 | 32 |
| | | | **128** |

**128 detents, stored 0–127, gate 0.0625 → 64 steps.** `118` (drum) uses the identical ladder,
spot-checked at five points. The six previously known values (`0.5→7`, `1→11`, `2→19`, `3→27`,
`3.5→29`, `4→31`) all reproduce, and were the evidence that identified the index relation.

**Displayed values are exact binary fractions of a step, rendered to two decimals with
round-half-to-even** — `0.625` shows as `0.62`, `0.875` as `0.88`. A converter must use the exact
fraction; the two-decimal form is a display artefact and is wrong by up to 4 % at the bottom of
the range.

**The displayed gate is a length in steps.** `project_5_description.txt` documents a note placed
on beat 9 and tied through beat 12 — four steps — as gate 4, and the file stores `110` = 31 for
it. So a gate converts directly into a note duration; M2's MIDI export relies on this.

**Do not fit a curve to sparse points.** A converter using a plausible-but-wrong gate table
produces files that load fine and play with wrong note durations — the worst kind of bug, because
nothing errors. The ladder above is not that: 64 consecutive detents were transcribed directly, the
rest enumerated from an observed increment rule and count-verified by the exact closure at stored
127.

**Stored `36` (gate 5.25) is now measured too.** It was the sweep's one derived rung — that note
had been over-turned by a detent and stored 37 — and capture `D25-gate-capture.KeyStepPro` closes
it: a single note placed with the Gate display reading **5.25**, diffing against `B0-baseline` to
eight keys on Track 2, with `124_110_1_1_1` = **36**. Predicted and observed agree, so no
transcribed rung of the ladder rests on interpolation any more.

(The stored 65–78, 80–94 and 97–125 spans remain *enumerated* from the increment rule rather than
transcribed. That is a different and weaker provenance class, count-verified only by the exact
closure at 127, and it is not upgraded by this capture.)

This also resolves the long-standing `?(2)`: `initial_project`'s drum gate stored `2` is detent 3,
gate **0.1875**.

**Default gate is `7` (0.5).** A freshly placed note stores `7`, confirmed by `project_9`'s
untouched notes and by `initial_project`. Alongside it, a fresh note's other defaults are
velocity `100`, time shift `49` (0), randomness `100` and step skip `15` (all four sequences).

**The complete key set a note-creating writer must produce** was measured directly by capture
`T1-note-place`, which placed one note in an untouched pattern and moved exactly eight keys —
no more:

| Key | Value | Meaning |
|---|---|---|
| `50` | `0` | note→step, 0-based |
| `109` | pitch | the MIDI note |
| `110` | `7` | gate (0.5) |
| `111` | `100` | velocity |
| `112` | `49` | time shift, centred |
| `113` | `100` | randomness |
| `48` | `1` | step active |
| `40` | `3` | pattern holds data |

Deleting that note returns all of them to sentinel **except `40`**, which latches at 3 (see [per-pattern scalars](./Parameters_Pattern_Scalars.md)).
That capture's display read `0.5`, which confirms the ladder's `7 → 0.5` entry from a second
direction and a separate session.

**Implemented.** `ksp.constants.GATE_TABLE` now enumerates all 128 rungs from the five runs above,
and `decode_gate` reserves `?(raw)` for a value outside 0–127. The measured/derived provenance is
carried in the code comment, and `tests/test_gate_ladder.py` checks the enumeration against every
line of `analysis/gate_ladder.txt` — so the table cannot drift from the transcription
without a test failing.
