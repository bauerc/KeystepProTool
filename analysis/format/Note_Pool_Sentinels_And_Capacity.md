# The note pool — sentinels and capacity

**Spec section:** §4 (2 of 3) — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The `127` sentinel and why it marks an empty entry rather than the end of the list; `idx2` as a pool chunk, the zero-fill trap, and the 192-event ceiling.
**Related:** §4 begins in [the two index spaces](./Index_Spaces_And_Note_Placement.md) and continues in [existence versus audibility](./Existence_Versus_Audibility.md).

---

### The `127` sentinel

`127` marks "empty". But `127` is also a **legal velocity** (and a legal pitch), so
velocity `127` is genuinely ambiguous in isolation.

> **The authoritative existence test is `paramId 50` (or `54` for drums) `!= 127`.**
> Never infer note presence from velocity.

**`127` marks an empty *entry*, not the end of the list — and the two parameter sets differ.**
The drum array is a pool with holes: deleting a note empties its entry and leaves the later ones
where they are. The melodic array is genuinely compacted — verified across all five sample files,
no slot holds a non-`127` value after an interior `127`.

So the scan rules are asymmetric, and a reader that applies rule 1 to the drum set destroys data.
`initial_project` Track 1 pattern 5 slot 1 has holes at entries 28–29 and 35, with five lane-12
notes at entries 30–34 and four lane-17 notes at 36–39 behind them; pattern 9 has holes at
entries 22–24 and 28. Stopping at the first sentinel drops **43 live notes** across the two
patterns, and then reports their step-active flags as orphans.

> **The check that settles it:** scanning the whole pool takes flags-without-a-note to **exactly
> zero** on every pattern of every sample file, while leaving the pooled-but-unflagged notes
> (capture D1) untouched. Every flagged step having a pooled note is an invariant, so a violation
> means the pool was decoded wrongly — not that the file is damaged.

**The invariant holds across the sample files, but the device can break it.** `T4-melodic-overflow-v2`
carries `124_48_1_1_49` set with no pooled note behind it: the operator lit step 49 and the
firmware then refused the note, having already reached the 192-event ceiling. So a flag with
nothing behind it is a real state the hardware can produce, not proof of a decode bug — the
reader is pool-driven, invents nothing from it, and reports it. Read the warning as "this file is
odd", not "this reader is wrong", and check the pattern's event count before suspecting the pool
scan.

### `idx2` is a pool chunk, not a voice — and the zero-fill trap

`idx2` runs **1–4 on Track 1** and **1–3 on Tracks 2–4**, and it is tempting to read it as a
poly/chord voice. It is not. It **chunks one flat note pool into blocks of 64 entries**, giving
a real capacity of **192 events per pattern** (3 × 64) on every track.

Polyphony is expressed inside a chunk, as **consecutive note ordinals sharing the same `50`
(or `54`) value**. Hardware-confirmed by capture `D2-chord4-tr3` / `D2-chord4-tr1`: a four-note
chord is accepted on both Track 3 and Track 1, and lands in **slot 1, ordinals 1–4**, all with
`50` = 0, while slots 2 and 3 stay entirely sentinel-filled. There is no three-voice ceiling,
and Track 1 has no extra voice. The device gave **no feedback at all** on the fourth voice — it
simply took it, which is what settles that the ceiling was never there. (Building a chord on the
device needs **Step Edit** mode; that is data entry, not format — see the test protocol.)

Notes reach slot 2 only when slot 1's 64 entries are full. `D3-drum-overflow` fills a drum
pattern past capacity: the events land 64 in slot 1, 64 in slot 2, 64 in slot 3, and the device
then displays a **192-note limit** error. So the ceiling is real and the firmware enforces it.

**The melodic side does the same** (capture `T4-melodic-overflow-v2`), which matters because no
sample file has more than 64 melodic notes in a pattern and the behaviour had never been seen:
64 events in each of chunks 1–3, the same 192 error, and the step-active array left behind in
chunk 1 as described in [the two index spaces](./Index_Spaces_And_Note_Placement.md). The two parameter sets chunk alike.

Note the asymmetry in what is *allocated* versus what is *allowed*. Melodic items address
`idx2` = 1–3, so 192 is exactly the key space. Track 1 addresses a fourth chunk — 256 slots — and
still stops at 192, so the ceiling is a firmware limit rather than a storage one.

**At the ceiling the device refuses the next hit — it does not overwrite.** The operator confirms
the 193rd hit was rejected outright, with the error shown immediately and no existing event
disturbed. So there is no "oldest note wins" recycling to emulate: a writer handed more than 192
events per pattern must either **reject the source** or **drop the overflow and warn**, and
either way the file it emits stays a faithful prefix rather than a scrambled pool.

> **Track 1's fourth slot is zero-filled, not sentinel-filled.** In all 16 patterns of all five
> sample projects — including both empty baselines and real user material — `123_50_*_4_*` and
> `123_54_*_4_*` are entirely `0`, as are the matching pitch and velocity arrays. The firmware
> appears never to initialise it.

This is the one place where the `!= 127` existence rule is not sufficient on its own. Read
literally, a zero-filled slot is 64 notes at step 0 with velocity 0, in both parameter sets, in
every pattern — so a completely empty project decodes as 2,048 phantom notes.

The reliable test is narrow: treat a slot as uninitialised only when **note→step, pitch and
velocity are all uniformly zero**. That cannot be confused with real data, because a note with
velocity 0 is silent and 64 notes cannot all sit on step 0. `project_5`'s kick is note→step `0`
with pitch (lane) `0` and is correctly kept, because its velocity is 127.

Slot 4 is now measured, and it is a phantom: `D2-chord4-tr1` adds a fourth chord voice on
Track 1 and `123_*_1_4_*` does not move at all — the note goes to slot 1 ordinal 4 like every
other track. A writer must never place events there.
