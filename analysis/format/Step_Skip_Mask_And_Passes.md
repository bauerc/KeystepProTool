# The step-skip mask and passes

**Spec section:** §5 (2 of 3) — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** `49` / `53` as a 4-bit mask over four passes of the pattern — repeats, not pages.
**Related:** §5 begins in [the worked example](./Worked_Example_Project_5.md) and continues in [resolved mode flags](./Resolved_Mode_Flags_And_Bitmasks.md).

---

### Step skip is a 4-bit mask, and the four sequences are **repeats**

The KeyStep Pro runs a pattern as four sequences (16 / 32 / 48 / 64). `49` / `53` is a bitmask of
which of those a note plays in:

| Bit | Value | Sequence |
|---|---|---|
| 0 | 1 | 16 |
| 1 | 2 | 32 |
| 2 | 4 | 48 |
| 3 | 8 | 64 |

`15` = plays always (the default). `5` = {16, 48}. `12` = {48, 64}.

**Repeats, not pages — measured 2026-08-04, capture `T5-skip-16step`, protocol T5.8.** The pattern
**loops four times** and the mask picks which loops a note plays in. A pass is the pattern's own
declared length at *any* length, so every mask is meaningful even on a pattern far shorter than 64
steps, and the 16 / 32 / 48 / 64 labels name passes rather than step ranges.

The capture puts four notes in a **16-step** pattern, at steps 1, 5, 9 and 13, with `49` at those
steps = **1, 2, 4, 8**. Played through eight loops, the operator heard beat 1 on pass 1, beat 5 on
pass 2, beat 9 on pass 3, beat 13 on pass 4, and then the same cycle again. Extending the pattern to
64 steps makes a pass 64 steps; the cycle is still four of them.

This is the reading `project_5` already implied — pattern 1 is 16 steps and carries notes masked to
48 and 64, which under a *pages* reading could never sound. The device has no vocabulary of its own
for the setting: it is reached by holding a step and pressing one of the four **Lst Step/Extend**
buttons, where a lit button means the note plays on that pass.

`ksp2midi --passes` renders the cycle: four repeats when any note carries a partial mask, one when
none does, and `--passes 1` to flatten it deliberately.
