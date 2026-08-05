# The two index spaces and note placement

**Spec section:** §4 (1 of 3) — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** Step-indexed versus note-indexed parameters, the `52` packed bit array, and the eight keys that placing one melodic note costs.
**Related:** §4 continues in [the note pool](./Note_Pool_Sentinels_And_Capacity.md) and [existence versus audibility](./Existence_Versus_Audibility.md).

---

## 4. The two index spaces

**This is the part that breaks naive implementations.**

Within a single `(item, pattern, slot)`, the third index means two different things depending on
which parameter you are reading:

- **Step-indexed** — `48`, `49`: index is the physical step position, 1–64.
- **Note-indexed** — `50`, `109`–`113` (and drum `53`, `54`, `117`–`121`): index is the ordinal
  position in a **note list**, and `paramId 50` (or `54`) maps that note to its **0-based step**.

The KeyStep Pro therefore does **not** store a step grid of note data. It stores a **compact
event list** per slot, plus a separate per-step activity array.

### A third layout: the drum step-active bit array (`52`)

`52` is neither step-indexed nor note-indexed. It is a **flattened `[lane][part]` bit array**,
lane-major, packed **7 bits per entry** with **10 entries per lane** (10 × 7 = 70 ≥ 64 steps).
Its two trailing indices are storage geometry, not lane and step:

```
flat = lane * 10 + (step // 7)
key  = 123_52_<pattern>_<flat // 64 + 1>_<flat % 64 + 1>
bit  = step % 7
```

Hardware-confirmed on `D1-two-hits` / `D1-step-off` (lane 0 → steps {0, 4}, then {0} after the
toggle) and `D3-drum-overflow` (lanes 0–2 all 64 steps set, lane 3 clear — exactly the three
lanes that were filled). It also reproduces on real user material: `initial_project` pattern 1
lane 0 → {0, 4, 8, 12} and pattern 3 lane 7 → all 16 steps, each matching that lane's pool
exactly.

The melodic equivalent `48` is far simpler — one entry per step, value `1` or `0`, and the whole
pattern's flags sit in **slot 1**, with slots 2–3 unused.

**Hardware-confirmed at the one point where it could have gone wrong** (capture T4.6). A pattern
filled to the 192-event ceiling spills its pool into chunks 2 and 3 — 64 live entries in each —
while `124_48_1_2_*` and `124_48_1_3_*` stay **entirely zero**. So `48` does *not* chunk
alongside the pool, and a reader may take it from slot 1 and treat it as pattern-wide.

That is structural rather than lucky, which is why it can be relied on: `48` holds one entry per
step, a pattern has at most 64 steps, and a chunk is 64 entries — a full set of flags fills chunk
1 exactly and has nothing left to spill. The drum `52` chunks only because it is packed across
24 lanes and needs 220 entries for the same job.

**It is also vendor-declared, and it holds for `49` as well.** Arturia's `bulkOperation`
descriptor fixes the middle index of both `48` and `49` at `[1]`, so MCC itself never reads either
from any other slot — both are pattern-wide by the vendor's own account, not just by observation.
See [reproducing findings](./Reproducing_Findings_And_Index_Shapes.md) for the descriptor and
[the SysEx path](./SysEx_Direct_Transfer_Path.md) for the read plan built from it.

Consequences for writing files:

1. Notes should be packed **contiguously from index 1**, with no gaps. **This is a rule for
   writers only** — see “The `127` sentinel” in [the note pool](./Note_Pool_Sentinels_And_Capacity.md). A reader must not assume it.
2. Every written note needs its step recorded in `50` / `54`.
3. `48` / `52` (step active) must be kept consistent with the note list. They are **not**
   merely redundant with it: the firmware plays the flags, so a pooled note whose flag is clear
   is silent (see “Pooled does not mean audible” in [existence versus audibility](./Existence_Versus_Audibility.md)).
4. The tail of every array must be sentinel-filled.

### What placing one melodic note costs

**Measured, not derived.** `B0-baseline` → `T1-note-place` is the device's own diff after a human
placed a single note on Track 2, pattern 1, step 1 — **8 keys**, and no others:

| Key | Value | Indexed by |
|---|---|---|
| `<item>_50_<pat>_<slot>_<ord>` | step, **0-based** | note ordinal |
| `<item>_109_<pat>_<slot>_<ord>` | pitch | note ordinal |
| `<item>_110_<pat>_<slot>_<ord>` | gate — fresh **7** | note ordinal |
| `<item>_111_<pat>_<slot>_<ord>` | velocity — fresh **100** | note ordinal |
| `<item>_112_<pat>_<slot>_<ord>` | time shift — centre **49** | note ordinal |
| `<item>_113_<pat>_<slot>_<ord>` | randomness — fresh **100** | note ordinal |
| `<item>_48_<pat>_**1**_<step>` | **1** | **step**, slot 1 always |
| `<item>_40_<pat>` | **3** | pattern |

The four fresh-note defaults are confirmed by `T1-note-place`, `D25-gate-capture` and both D2
chord captures independently, and live in `ksp.constants`.

Two things a writer must not get wrong here:

- **`49` (step skip) is not written.** An initialised project already holds `15` — "plays on all
  four sequences" — at every step, which is why it never appears in the diff.
- **`48` is step-indexed while the pool is note-indexed**, so the two run on different counters.
  `D2-chord4-tr3` places four notes on step 1: ordinals 1–4 in the pool, and a **single** `48`
  entry. Setting `48` by ordinal instead would light steps 1–4 — a file that decodes plausibly and
  plays wrong.

`ksp.mutate.place_note` implements exactly this set, and `tests/test_mutate.py` holds it to
reproducing `T1-note-place` byte for byte from the committed `baseline.KeyStepPro`.

> **The recipe is confirmed on *load*, not merely on save** — protocol M4.1. A file built by
> `place_note` from the baseline was loaded in MCC, transferred to the device, and exported back:
> the readback differs from the candidate by **zero keys**. So these 8 are not just what the
> firmware writes when a human places a note, they are everything it needs to be handed one. The
> same capture placed a second note with `48` deliberately clear; it stayed silent. With T4.5 the
> two halves meet: the device honours a flag it cleared itself *and* one we wrote into a file it
> loaded.

**Deleting** a note sends the six note parameters back to `127` and clears `48`, but leaves `40`
at 3 — it latches, so an emptied pattern is not distinguishable from a full one by `40` alone.
The `T1-note-delete` diff shows only *six* keys moving rather than seven because the preceding
capture in that chain had already set velocity `111` to 127; nothing there says velocity is
exempt.

Both firmware ceilings are enforced on the device with an on-screen message: **192 events per
pattern** and **16 notes per step** (capture `T4-melodic-overflow-v2`).
