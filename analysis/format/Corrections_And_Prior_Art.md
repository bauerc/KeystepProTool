# Corrections to the earlier analysis, and prior art

**Spec section:** §8 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The field mappings an earlier analysis got wrong — kept so a fresh reverse-engineering attempt recognises them rather than re-deriving them — and what prior art exists.

---

## 8. Corrections to the earlier analysis

The repository's first pass at this format was written from the project files alone, on the
conclusion that MCC ships nothing readable. That conclusion was wrong and so were several of its
field mappings. The document itself is gone; what it got wrong is kept here, because these are
the readings a fresh reverse-engineering attempt would plausibly arrive at again.

| Prior claim | Reality |
|---|---|
| "MCC ships no readable KeyStep resource file" | `/Library/Arturia/.../Resources/KeyStepPro.json` is the full dictionary |
| `48` = tie, `49` = velocity, `50` = pitch | `48` = step active, `49` = step skip, `50` = note→step. Pitch is `109` |
| Velocity stored as 16 discrete levels | Full 0–127, stored directly |
| Item `121` = arpeggiator / chord memory | Scenes |
| Track 1's extra params are a modulation lane | A complete DRUM-mode parameter set |
| All indices are `pattern_slot_step` | Two index spaces: step-indexed vs note-indexed |
| `idx2` is a polyphony voice, capped at 3 (4 on Track 1) | A 64-entry pool chunk. Chords share a chunk as consecutive ordinals; capacity is 192 events |
| Risk of omitting keys the firmware needs | Key set is fixed and identical across all files |
| `arturia2midi` is doing this on GitHub | Could not be found. Treat as unverified |

Its *high-level* observations — flat JSON, trailing comma, structure in the key names, 16 patterns
× 64 steps, template-and-overwrite as the practical strategy — were sound. Its **field-level
mappings** were not.

### Prior art

- Arturia's own FAQ states the KeyStep Pro's data structure is **incompatible with the BeatStep
  Pro**, so BSP tooling cannot be reused.
- The only documented community MIDI-import workflow is **real-time recording** from a DAW into the
  hardware — arm record, play the clip. It is bounded by pattern length and captures no per-step
  skip, randomness or time-shift data.
- `arturia2midi`, cited by the earlier analysis, could not be found.

A file-level converter is therefore new work rather than a reimplementation.
