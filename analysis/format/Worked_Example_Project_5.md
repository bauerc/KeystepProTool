# Worked example — `project_5`

**Spec section:** §5 (1 of 3) — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** `project_5` decoded step by step against its hardware-confirmed description, melodic and drum, including the drum time shift re-read on the device.
**Related:** §5 continues in [the step-skip mask](./Step_Skip_Mask_And_Passes.md) and [resolved mode flags](./Resolved_Mode_Flags_And_Bitmasks.md).

---

## 5. Worked example and validation

Verified against `project_5_description.txt`, whose values were confirmed on the hardware display.
**Track 3 = item `125`, pattern 1.** Slot 1 decodes as:

| Index | `48` (by step) | `49` (by step) | `50` (by note) | `109` pitch | `111` velo | `112` shift | `113` rand |
|---|---|---|---|---|---|---|---|
| 1 | 1 | 15 | 0 | 48 | 60 | 50 | 10 |
| 2 | 1 | 15 | 1 | 48 | 70 | 51 | 20 |
| 3 | 1 | 15 | 2 | 48 | 90 | 52 | 30 |
| 4 | 1 | 15 | 3 | 48 | 100 | 53 | 40 |
| 5 | 1 | 5 | 4 | 49 | 60 | 48 | 100 |
| 6 | 1 | 5 | 5 | 49 | 70 | 47 | 100 |
| 7 | 1 | 10 | 6 | 49 | 90 | 46 | 100 |
| 8 | 1 | 10 | 7 | 49 | 100 | 45 | 100 |
| 9 | 1 | 3 | 8 | 50 | 60 | 49 | 100 |
| 10 | 0 | 15 | **12** | 50 | 120 | 51 | 100 |
| 13 | **1** | **12** | 127 | 127 | 127 | 127 | 127 |

Reading that against the documented intent:

| Documented | Decoded | ✓ |
|---|---|---|
| Beats 1–4 note C2 | `109` = 48 | ✓ |
| Beats 5–8 note C#2 | `109` = 49 | ✓ |
| Beats 9+ note D | `109` = 50 | ✓ |
| Velocities 60, 70, 90, 100 | `111` = 60, 70, 90, 100 | ✓ |
| Time shift +1…+4 | `112` = 50, 51, 52, 53 → **centre 49** | ✓ |
| Time shift −1…−4 | `112` = 48, 47, 46, 45 | ✓ |
| Randomness 10, 20, 30, 40 | `113` = 10, 20, 30, 40 | ✓ |
| Plays on all of 16/32/48/64 | `49` = 15 = `0b1111` | ✓ |
| Notes 5–6 play on 16, 48 | `49` = 5 = `0b0101` | ✓ |
| Notes 7–8 play on 32, 64 | `49` = 10 = `0b1010` | ✓ |
| 2nd D note plays on 48, 64 | `49` **at step 13** = 12 = `0b1100` | ✓ |
| 16-step pattern | `98` = 15 (0-based) | ✓ |

Note rows 10 and 13 are what proves [the two index spaces](./Index_Spaces_And_Note_Placement.md). The tenth *note* sits at step 13 (`50` = 12, 0-based),
so its velocity 120 appears at **note** index 10 while its skip mask 12 appears at **step**
index 13. Read with a single index space, this looks like a data inconsistency; read correctly,
every value lines up.

### Drum validation

Track 1 (item `123`), pattern 1, documented as "kick on beats 1 and 5":

- `123_52_1_1_1` = **17** = `0b0001_0001` → bits 0 and 4 → **steps 1 and 5**.
  `52` appears to pack 8 steps per index, so 64 steps would occupy indices 1–8. See the caveat in [resolved mode flags](./Resolved_Mode_Flags_And_Bitmasks.md).
- `54` (note→step) = `0`, `4` → steps 1 and 5. ✓
- `119` velocity = 127, 50 ✓ · `121` randomness = 80, 90 ✓
- `120` time shift = 48, 50 → −1 and **+1** ✓ — re-read on the device, protocol T6.1. See
  "Drum time shift" below.
- `53` skip = 3 (`{16,32}`), 12 (`{48,64}`) ✓ — note-indexed here, unlike the melodic `49`.

> The melodic `49` is step-indexed while the drum `53` is note-indexed. This asymmetry is what
> the data shows consistently across files, but it is unusual enough to re-confirm before
> relying on it in a writer.

### Drum time shift in `project_5`

**Re-read on the device 2026-08-05, protocol T6.1** — a display read, not a capture. The display
shows −1 and **+1**, matching `120` = 48, 50 against the centre of 49. `project_5_description.txt`
originally transcribed −1 for both kick hits and has been corrected; the file was right all along.

Drum `120` therefore decodes against the melodic centre at these two points. The rest of its range
is untested — T7.3 sweeps it.
