# Prior art

**Spec section:** §8 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** what prior art exists.

-

### Prior art

- Arturia's own FAQ states the KeyStep Pro's data structure is **incompatible with the BeatStep
  Pro**, so BSP tooling cannot be reused.
- The only documented community MIDI-import workflow is **real-time recording** from a DAW into the
  hardware — arm record, play the clip. It is bounded by pattern length and captures no per-step
  skip, randomness or time-shift data.
- `arturia2midi`, cited by the earlier analysis, could not be found.

A file-level converter is therefore new work rather than a reimplementation.
