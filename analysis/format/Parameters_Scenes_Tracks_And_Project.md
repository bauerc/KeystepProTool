# Scenes, tracks and project parameters

**Spec section:** §3.3.1, §3.4 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** Scenes and pattern chaining (item `121`), per-track state, and the project globals including the tempo decode.

---

### 3.3.1 Scenes and pattern chaining — item `121`

**Measured 2026-08-04, capture `T5-chain-3`.** A scene holds a **pattern chain per track**, which is
the mechanism M6 needs for source material longer than 64 steps.

```
121_84_<scene>_<track>_<slot>    pattern number, 0-based, in chain order
121_83_<scene>_<track>           moves with the chain; not decoded
```

Chaining patterns 1 → 2 → 3 on **Track 2** in scene 1 stores `121_84_1_2_1..3` = **0, 1, 2** and
leaves slots 4–16 at the `127` sentinel. So a chain is **contiguous, 0-based and
sentinel-terminated**, and `84` reads 127 across all 16 slots of all 5 tracks of all 16 scenes in
every sample project — nobody had used a chain before this capture.

**The track index in the key is the track number.** Track 2 → index 2, which confirms the
descriptors' claim; index 5 is the Control track. This was worth checking because it is the one
place the item ordering is not the obvious one.

**`121_83_1_2` moves 0 → 32 at the same time, and one capture cannot say why.** Both
`(last << 4) | first` and `((len − 1) << 4)` give 32 for a chain of patterns 1–3, and nothing
separates them without a chain that starts somewhere other than pattern 1. The observation is
recorded; nothing reads it.

### 3.4 Per-track and project

`39` track data state · `85` / `86` transposition & octave bitfields · `122` track transposition ·
`87` chord (16 per track) · `59` / `60` track seq / drum colour · `123` track MIDI channel ·
`70`–`72` project tempo · `73` global BPM + metronome bitfield ·
`74` global swing · `75` current scene (0-based) · `68` / `69` ARP groups.

**Tempo is decoded.** `70`–`72` are a little-endian value in 7-bit chunks holding **BPM × 100**:

```
bpm = (p70 + p71 * 128 + p72 * 16384) / 100
```

`project_5` stores 96, 93, 0 → 12000 → **120.00 BPM**. `initial_project` stores 16, 103, 0 →
13200 → **132.00 BPM**. Both empty baselines store 96, 93, 0 and the hardware readout shows
120 BPM, which confirms the decode against the device rather than against another file.
Note the ordering: `70` is the **least** significant chunk.

**The device's range is 30–240 BPM.** The three chunks hold far more than that — a 21-bit field
scaled by 100 reaches about 20,971 BPM — so the field's width is no guide to what the hardware
will take. A converter must hold itself to 30–240 and say when it does; the file will store 5,000
BPM without complaint.

Global *device* settings — CV/gate outputs, MIDI channel routing, sync, drum map, knob
assignments, velocity/aftertouch curves — are **not** in the project file. They live under
`deviceGlobalParametersId: 65` and are addressed by `globalParamId`.
