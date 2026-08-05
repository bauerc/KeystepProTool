# Resolved — mode flags and bitmasks

**Spec section:** §5 (3 of 3) — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** Three findings that overturned earlier readings: the drum step-active bitmask layout, drum mode as `86` bit 6 rather than `100` (with the ARP octave), and `116` / `99` bit 2 as Mono/Poly.
**Related:** §5 begins in [the worked example](./Worked_Example_Project_5.md) and [the step-skip mask](./Step_Skip_Mask_And_Passes.md).

---

### Resolved: the drum step-active bitmask (`52`)

The layout is **7 bits per entry, lane-major, 10 entries per lane**, given in [the two index spaces](./Index_Spaces_And_Note_Placement.md). Under it
`initial_project` pattern 1's `17, 34` decodes to lane 0 → steps {0, 4, 8, 12}, matching that
lane's pool exactly, while lane 17's flags sit at a different offset entirely. It reproduces on
every file and capture checked. (An 8-steps-per-index reading also fits the two single-lane
hardware-confirmed projects, which is why a multi-lane file was needed to tell them apart.)

The melodic step-active array (`48`) is simpler — one entry per step, slot 1 only, measured at
the pool ceiling (T4.6) — and it agrees with the note list in every committed file. Where it
disagrees the note is disabled, not absent: T4.5 is the capture that shows the device doing it.
Both arrays are cross-checked by the reader, which warns rather than reconciling.

### Resolved: drum mode is parameter `86` bit 6, not `100`

`100` is documented as the ARP/Drum mode bitfield, but it reads **26 in every pattern of every
sample project** — including patterns that are unambiguously melodic and ones that are
unambiguously drum. It cannot be used to tell which parameter set is live.

The flag that *can* is **`86` bit 6**, and two independent lines of evidence agree:

- `KeyStepPro.json` names it — field id 17, `paramId 86`, `"name": "Track keyboard octave,
  chord mode state, Arp/Drum mode state in a bitfield"`, `"comment": "Arp/Drum mode state :
  bit 6"`.
- The data matches exactly. `123_86` is **66** (`0b1000010`, bit 6 set) in `project_5`,
  `project_9` and `initial_project` — every sample holding drum notes — and **2** in both empty
  baselines. Tracks 2–4 never set it.

**Confirmed on hardware.** Capture `T3-track1-drum` switches Track 1 from sequencer to drum mode
and produces a **one-key diff**: `123_86` 2 → 66. `100` does not move at all, in that capture or
any other.

It is **track-level, not per-pattern**, which matches the device's Drum button. The field is
named *Arp*/Drum, and on tracks 2–4 bit 6 does indeed mean ARP: `T3-arp-on` engages the
arpeggiator on Track 2 and sets `124_86` to 66. There is no ambiguity on Track 1, because Track 1
has no arpeggiator — drum mode replaces it entirely — so bit 6 there is unconditionally the drum
flag.

What `100` *does* carry is the **ARP octave, at bits 4–6**, matching the dictionary's own
comment: `T3-arp-octave` moves `124_100_1` from 26 to 42, i.e. that field from 1 to 2. Toggling
the arpeggiator on and off leaves `100` untouched, so ARP on/off is not stored there either.
Note the scope difference: `86` is per-track, `100` is per-pattern.

**The ARP octave has no display, and that is the whole encoding.** It is chosen by holding SHIFT
and striking one of five keys on the second physical octave, which are silkscreened with the
values — there is no screen readout to reconcile against. The range is five detents and the
default is 0, at C#3:

| Displayed / silkscreened | −1 | 0 | +1 | +2 | +3 |
|---|---|---|---|---|---|
| Stored in `100` bits 4–6 | 0 | **1** | 2 | 3 | 4 |

`T3-arp-octave` is the +1 move: default 0 → +1, stored 1 → 2. **`stored = octave + 1`**, so the
field is a plain unsigned offset with 0 as the floor rather than a signed value. Two of the five
rungs are measured and the remaining three follow from the range and the constant step; a
converter reporting ARP octave must state the offset it applied, since it cannot echo a screen.

This resolves the ambiguity that made the reader report `PatternMode.BOTH`. **`initial_project`
Track 1 pattern 1 holds both** a real 64-step melody and a real 12-note drum pattern; bit 6 is
set, so the drums are live and the melody is leftovers. The reader still reports every note and
warns — it resolves the *mode*, it does not discard data.

### Resolved: `116` bit 2 is Mono/Poly, and so is `99` bit 2

`D4-lane-steplength` was taken to pin `51` and moved a second scalar nobody diffed for:
**`123_116_1` 16 → 20**, bit 2, set at the moment the operator switched Track 1's drum mode from
Mono to Poly to give lanes independent lengths. So on the **drum** side: **bit 2 clear = Mono, all
24 lanes share one length; bit 2 set = Poly, `51` is honoured per lane.** [the drum note parameters](./Parameters_Note_Melodic_And_Drum.md) states the writer's
obligation.

That reading used to stop there, because `Default` holds `99` = 20 with bit 2 **already set** while
`116` = 16 has it clear, and the two halves could not both mean "polyrhythm off by default".
**T5.3 settles it**: toggling Monorhythm on Track 2 moves `124_99_1` 20 → 16, the same bit, in the
same sense. The defaults simply differ — sequencer patterns ship polyrhythm on, drum patterns ship
it off — and the layouts are identical (see [per-pattern scalars](./Parameters_Pattern_Scalars.md)).
