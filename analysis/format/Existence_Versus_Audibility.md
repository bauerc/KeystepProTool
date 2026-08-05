# Existence versus audibility

**Spec section:** §4 (3 of 3) — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** Why a note that exists in the pool may still not sound, and the complete list of the six reasons a note might not play.
**Related:** §4 begins in [the two index spaces](./Index_Spaces_And_Note_Placement.md) and [the note pool](./Note_Pool_Sentinels_And_Capacity.md).

---

### Pooled does not mean audible

A note can sit in the pool, fully formed, and still not play. **"Why a note might not play" below
lists every reason;** this section is the evidence for the commonest one, row 2.

`D1-two-hits` / `D1-step-off` toggle a drum step off **without deleting its note**: the pooled
entry survives byte-for-byte and only the step-active bit clears — and the step does not sound on
the device.

> **Existence and audibility are different tests.** `50` / `54` `!= 127` says a note *exists*.
> Whether it *plays* additionally requires its **step-active bit** (`48` melodic, `52` drum) to
> be set. A reader that reports pooled notes is correct; an exporter that renders them without
> checking the flag emits audio the hardware never makes.

This is not hypothetical. In `initial_project`, pattern 3 lanes 0 and 19 hold 20 pooled drum
notes with no flags at all, and pattern 1 lane 17 holds 8 of which only 4 are flagged.

**The device itself cannot show you the difference**, which is why the corpus is full of these.
Asked directly whether the UI distinguished "step off, note still stored" from "step empty" after
the D1 toggle, the operator reports it showed **nothing** — the step button's lamp *is* the
step-active bit and there is no second indicator behind it. Two consequences worth stating
because they are not guessable from the file:

- **A stored note cannot be overwritten by playing over it.** Entering a new pitch and pressing
  an unlit step re-lights the *old* note; the new pitch does not replace it.
- **ERASE + the step button is the only way to actually clear one.** Toggling a step off is a
  mute, not a delete, in the UI exactly as in the file.

So a pooled-but-unflagged note is the normal residue of ordinary playing, not a sign of a damaged
file — and a converter that silently drops them is discarding material the owner can still hear
by tapping one button.

### Why a note might not play

Existence and audibility are different tests, and there is more than one way to fail the second.
**This table is the complete list.** Everything below it is the evidence.

| # | Why it does not play | Key in the file | Example, from a committed file | Undo on the device | Confidence |
|---|---|---|---|---|---|
| 1 | The pool entry is empty — there is no note | `<item>_50_<pat>_<slot>_<ord>`, `54` for drums | `123_54_9_1_22` = `127` — a **hole**, not the end: ordinals 21 and 25 hold steps 42 and 44 | n/a, nothing is stored | Certain |
| 2 | **Disabled: step turned off** | drum `123_52_<pat>_<slot>_<idx>`, one **bit**; melodic `<item>_48_<pat>_1_<step>`, one entry | `123_52_9_1_1` = `0` → lane 0 step 5 is off. Contrast `123_52_9_1_2` = `2` = `0b0000010` → lane 0 step 9 is on. **No melodic example in a committed file** — see below | Re-light the step; the note returns intact | **Hardware** — drums D1, melodic T4.5 |
| 3 | **Disabled: past the last step** | `<item>_98_<pat>` melodic, `123_115_<pat>` drum, 0-based | `123_115_9` = `47` → 48 steps, while `123_54_9_1_45` = `56` → step 57 | Raise Last Step | **Hardware** (O1) |
| 4 | Velocity 0 | `<item>_111_<pat>_<slot>_<ord>`, `119` for drums | **None in the corpus** — no note in any committed file has velocity 0 | Raise the velocity | Inferred, never tested |
| 5 | Skipped on this pass | melodic `<item>_49_<pat>_<slot>_<step>` (**step**-indexed), drum `123_53_...` (**note**-indexed) | `125_49_1_1_5` = `5` = `0b0101` → plays on 16 and 48 only; `15` is the default "always" | Set the mask to all four | **Hardware** (T5.8) — the four sequences are **repeats** |
| 6 | Lost to randomness | `<item>_113_<pat>_<slot>_<ord>`, `121` for drums | `125_113_1_1_1` = `10`, against a fresh note's default of `100` | Set randomness to always | ⚠ **Unresolved** — probability or timing jitter? **T7.8** |

Row 2's drum key needs the packing from “A third layout” in [the two index spaces](./Index_Spaces_And_Note_Placement.md), because one entry holds seven
steps of one lane. Worked through for the disabled kick at step 5 of `initial_project` pattern 9 —
lane 0, 0-based step 4:

```
flat = lane * 10 + step // 7   = 0 * 10 + 4 // 7 = 0
key  = 123_52_9_<flat//64 + 1>_<flat%64 + 1>     = 123_52_9_1_1   -> 0 = 0b0000000
bit  = step % 7 = 4                              -> (0 >> 4) & 1  = 0   step is OFF
```

**Two of these six have no example in any committed file**, and that is a finding rather than an
omission. No note anywhere has velocity 0, so row 4 is inference from MIDI convention alone.

Row 2's melodic half is **measured** but only in a capture, not in the corpus — no melodic note in
any committed file has its `48` bit clear. Capture T4.5 makes it: two identical notes at beats 1
and 5, then beat 5's step toggled off without deleting it. Exactly one key moves,
`124_48_1_1_5` from `1` to `0`; the pool entry — `50`, `109`–`113` — survives byte for byte, and
the operator confirms beat 5 did not sound. That is D1's shape on the melodic parameter set, and
it is what lets `ksp2midi` drop step-off notes on both sets rather than on drums alone. Because
the captures are gitignored, the check lives in `tests/test_hardware_tier4.py`, which skips where
the file is absent.

Rows **2 and 3 are what "disabled" means** — one state, two mechanisms, both toggled the same way
on the device, and the only two the tools report under that word. Say "disabled (step turned
off)" or "disabled (past the last step)"; never "silent", "inactive" or "lost".

Rows 5 and 6 differ in kind: they are properties of a *pass*, not of the note's stored state, so
the same note can sound on one loop and not the next. Row 5 is now measured — the four sequences
are four **repeats** of the pattern (T5.8), which `ksp2midi --passes` renders. Row 6 is not:
until T7.8 runs, randomness is reported and never applied.

Row 1 is not a disabled note at all — it is the absence of one. Note also that `127` marks an
empty *entry*, not the end of the list; see “The `127` sentinel” in [the note pool](./Note_Pool_Sentinels_And_Capacity.md), because reading it as a
terminator silently discards live notes.

#### Evidence for row 3 — the last step

**Hardware-observed** on `initial_project` Track 1 pattern 9. `123_115_9` = 47, i.e. a 48-step
drum pattern, and the pattern holds pooled, step-active notes out to step 63.

**In the project's saved state those notes are disabled and do not play** — that is the file's
own configuration and the correct behaviour. The observation was made by deliberately raising
Last Step to 64, at which point they appear and sound; lowering it back to 48 disables them
again, with the step-64 light going out. The toggle was a diagnostic action, not the file's state.

> **Notes past the last step are disabled, not stale.** Being past the last step is one of the
> two ways a note is disabled — the other is its step being turned off — and both are toggled the
> same way on the device. So shortening a pattern disables those notes without deleting anything,
> and lengthening it enables them again, intact. A writer must therefore preserve them, and a
> reader must not treat "past the declared length" as evidence that an entry is leftover junk.
> `ksp2midi` drops them by default, the same as any other disabled note, and says how many;
> `--include-disabled` exports them.

**This is not the step-skip question.** The 16 / 32 / 48 / 64 *mask* (`49` / `53`, see [the step-skip mask](./Step_Skip_Mask_And_Passes.md)) is a
separate mechanism, measured separately by **T5.8**; the two are easy to conflate at the device
because both change which steps light up. The observation above is about the pattern's declared
length only.
