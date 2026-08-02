# KeyStep Pro hardware capture protocol

**Purpose:** resolve the format questions that cannot be answered from files already on disk, by
setting known values on the device, exporting them, and diffing — and, for tier M4 alone, by
running that loop backwards: writing a known value into a file, loading it, and reading the
device's own export back out.

**Audience:** a human at the device, and an agent re-reading this later to interpret the captures.

**Companion documents:**
[`Format_Corrections_Issue.md`](./Format_Corrections_Issue.md) — read its summary table before
starting.

> **This document contains only unfinished work.** B0 and tiers 1, 2, 3 and 4 have been run (19
> captures, in `project_files/captures/`, which is gitignored). Their procedures have been
> **deleted** from this file so that everything still here is something to do. What they found is
> in [`KeyStepPro_Format_Spec.md`](./KeyStepPro_Format_Spec.md), which is the authoritative
> record — not here.
>
> Briefly, so nobody re-runs them: drum mode is `86` bit 6 and `100` never moves; a pooled note
> whose step-active bit is clear does not sound; `idx2` is a 64-entry pool chunk rather than a
> polyphony voice, with a hardware-enforced 192-event ceiling; `52` is a lane-major 7-bit array;
> `40` and `39` latch; two untouched exports are byte-identical; and **gate is an index** —
> `stored = detent − 1`, 128 entries, 0.0625–64 steps, drum identical (spec §6.1).
>
> **Also settled, opportunistically rather than by a planned capture:** notes past a pattern's
> declared last step are **disabled, not stale** — see the O1 ledger row below and spec §4
> ("Why a note might not play"). This does **not** answer T5.8, which is about the
> 16 / 32 / 48 / 64 skip *mask*; that capture is still needed.

**The baseline every test below starts from** is `B0-baseline.KeyStepPro` — an initialised,
untouched project, already captured. Where a test says "from the baseline", start by loading or
re-initialising to that state; do not re-derive it.

**What is genuinely unknown and needs the device:**

| Question | Blocks | Tier |
|---|---|---|
| Whether a file we wrote loads, reaches the device, and lands its values where we addressed them | M4, and every write after it | M4 |
| Whether melodic step-off behaves like drum step-off | M5/M6 export correctness | 4 |
| Whether a melodic pool spills into slot 2 like a drum pool | M6 | 4 |
| The `99` / `116` bitfield layout | M6 | 5 |
| Pattern chaining beyond 64 steps (`84`) | M6 | 5 |
| Time Shift range and linearity (`112` / `120`) | M7; whether shift is usable at all | 7 |
| Which parameter governs effective swing (`74` / `97` / `114`) | M7, and `reader._swing` may be wrong | 7 |
| Whether `113` randomness is probability or timing jitter | the validity of every timing measurement | 7 |
| What one Time Shift unit is worth in time | M2's grid-quantise warning, M5's quantiser | 8 |

The last four are the subject of [`Timing_Calibration.md`](./Timing_Calibration.md), which carries
the model and the arithmetic; tiers 7 and 8 below are the captures that feed it.

---

## How to run a capture

Every test below is one capture. A capture is:

1. **Start from a known state.** Either a freshly initialised project, or the immediately
   preceding capture in the same tier — each test says which. Never start from an unknown state.
2. **Change exactly one thing.** One parameter, one note, one setting.
3. **Read the device display and write down what it says.** The stored value is what we are
   trying to learn, so the *displayed* value is the ground truth and only exists in your notes.
   This is the step that cannot be recovered later.
4. **Export**, by the route below. It is fixed — every capture in the corpus used it.
5. **Save it as** `project_files/captures/<test-id>.KeyStepPro`, using the test ID verbatim.
6. **Log it** in the ledger at the bottom of this file: test ID, displayed value, date, anything
   that felt off.
7. **Tick the test's checkbox** at the top of its section. That is the signal the capture exists and
   is ready to be read.

### The export route

Recorded once so the captures are reproducible; this is the route behind every file in
`project_files/captures/`.

1. **On the device:** hold **SAVE** and press **PROJECT**, then click the encoder next to the
   display to confirm. The corpus uses the **Project 2** slot throughout.
2. **In MIDI Control Center:** select that project and click **Recall From**, which pulls it off
   the device and writes it into MCC's template directory as
   `…/Arturia/MIDI Control Center/Templates/KeyStepPro/<name>.KeyStepPro`.
3. **Move it into the repo** under the test ID — `project_files/captures/<test-id>.KeyStepPro`.
   `project_files/captures/move_template.sh` does this step.

MCC's own Save As is not part of the route. Note that `project_files/captures/` is **gitignored**:
the captures are local evidence, and the finding has to reach the spec to survive.

### Device operating notes

Things that are not on the display and are easy to lose between sessions. Each is needed to
*perform* one of the tests below.

- **Step Edit** (a physical button) is required to add notes to an existing step — that is how a
  chord gets built. It is off by default and switches itself off when you change project and come
  back.
- **Drum Mono/Poly:** SHIFT + D#2 selects Mono, SHIFT + E2 selects Poly. Poly is what gives drum
  lanes independent step counts, and it moves `116` bit 2 (spec §5).
- **ARP octave** has no display readout at all. It is SHIFT plus one of five silkscreened keys on
  the second physical octave, −1 / 0 / +1 / +2 / +3, with 0 at C#3.
- **Erasing a note** is ERASE + the step button. Toggling a step off only mutes it; the note stays
  in the pool and playing a new pitch onto the dark step re-lights the *old* note rather than
  replacing it.
- **The device names middle C as C3** (C2 = MIDI 48). Write displayed note names down as the
  device shows them and convert later — do not pre-convert in your notes.

### Rules

- **One change per capture.** A capture containing more than one deliberate change is discarded,
  not interpreted. Two changes make the diff ambiguous and there is no way to tell afterwards.
- **Do not touch anything else** — not the tempo, not the transport, not another track. Every
  key that moves is a signal, and unrelated changes bury the one you want.
- **If you lose track of what you changed, discard and redo.** A wrong entry in the table is worse
  than a missing one, because it will be believed.
- **Use untouched patterns** for new tests, the way `project_9` does. A pattern with history in it
  carries stale pool entries that make diffs noisier.
- Captures are data, not source. Once written they get the same treatment as
  `project_files/*.KeyStepPro` — never reformatted, re-indented, or given a final newline.

### Batched sweep captures

**The one-change rule above applies to captures that are read by diffing.** A *sweep* capture is
not read that way, and holding it to the same rule is what made the gate sweep — the former Tier 2,
now complete (spec §6.1) — unrunnable for months: one export per encoder detent is ~128
sync-and-save cycles through MCC. Batching collapsed it to a single capture, and **Tier 7's shift
sweep should be run the same way.**

One export contains every pattern of every track, and every note's parameter has its own key —
`124_110_<pattern>_1_<ordinal>`. So one export can carry hundreds of independent readings, read
directly by key rather than by diff. That is allowed when:

- **one parameter** is swept, and nothing else on the device is touched;
- **each value sits on a distinct note**, so no two changes share a key;
- a **note map** — which step carries which intended value — is written down *at capture time*,
  in the ledger or a companion data file. Without it the capture is unreadable afterwards.

Three rules that are not optional:

- **Pair by `50` (or `54` for drums), never by note ordinal.** Note ordinal and step number are
  different index spaces (spec §4) and the pool is in creation order. Read
  `124_50_<p>_1_<k>` to learn which step note `k` sits on, and sort by that. Getting this wrong
  silently permutes the whole table into something that still looks plausible.
- **Sweep a contiguous run of detents, not scattered samples.** Tier 2's six scattered gate points
  looked like a non-linear curve for months; a run of 64 consecutive ones showed in minutes that
  the encoding was a plain index. A sparse sample of a monotonic encoder tells you almost nothing.
- **Export after each pattern is filled** (`-wip1`, `-wip2`, …). A sweep capture is an hour of
  device work; a mishap should cost one pattern, not the session.

Two things to design against, both of which bit Tier 2:

- **A note you forget to set keeps its fresh-note default**, which is indistinguishable from a
  deliberate value. Build in a check that catches it — for a ramp, that the stored values are a
  gapless run.
- **Over-turning the encoder by one detent** produces a gap plus an adjacent duplicate. The repair
  is one extra note at the missing value, not a redo.

### Diffing

No tooling needs to exist first. This is enough:

```python
# uv run python - <<'EOF'
from ksp import lenient_json

BASE = "project_files/captures/B0-baseline.KeyStepPro"
CAP  = "project_files/captures/T7-shift-min.KeyStepPro"

a = lenient_json.load_path(BASE)
b = lenient_json.load_path(CAP)

for k in sorted(a.keys() | b.keys(), key=lambda s: [int(p) if p.isdigit() else p
                                                    for p in s.split("_")]):
    va, vb = a.get(k), b.get(k)
    if va != vb:
        print(f"{k:24s} {va!r:>8} -> {vb!r}")
# EOF
```

A clean single-parameter capture should print a handful of lines. If it prints hundreds, either
more changed than you intended or you are diffing against the wrong baseline.

A `ksp-diff` command would be a natural by-product of M4 and would make tiers 3–5 much faster to
read, but nothing here waits on it.

### Per-test format

Each test states: **what it resolves · device steps · capture name · keys to diff · what confirms
the current assumption · what falsifies it · what to do if falsified.**

---

## Tier M4 — the first write to the device

**2 captures, one session.** Every other tier reads what the device stores. This one writes, and
it is the only place our key addressing is checked against the firmware rather than against
itself. It runs the loop backwards — file → MCC → device → display and ear, then back out through
Recall From so the result is something a test can assert on.

Milestone M4. PR #47 already showed MCC accepts a file this writer produced and transfers it to
the device, so what is left is narrower: **does a value we wrote at an address we computed land on
the note we meant, and does a note we created from nothing actually play?**

### The import route

The mirror of the export route above, and the only route these two tests use.

1. **Generate the candidates at the desk**, before the session:

   ```sh
   uv run pytest -m hardware
   ```

   This writes `project_files/captures/M4-place.KeyStepPro` and `M4-pitch.KeyStepPro`, asserting
   on the way out that they differ from their sources by exactly 14 and 1 keys. The readback
   assertions skip until the captures below exist.

2. **Copy into MCC's library**, which is world-writable and needs no `sudo`:

   ```sh
   cp project_files/captures/M4-*.KeyStepPro \
      "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/"
   ```

3. **Restart MCC**, find the project in the Project Browser, load it, and send it to the device.
   The KeyStep Pro has 16 project slots and any of them will do.

4. **Read the device, then export back** by the standard route, saving as the readback capture
   named in each test.

### M4.1 — A note we created from nothing plays

- [x] run 2026-08-01 — **confirmed**

- **Resolves:** whether the 8-key placement recipe is complete. It is what the device wrote when a
  human placed a note (`B0-baseline` → `T1-note-place`), and `ksp.mutate.place_note` reproduces
  that file byte for byte at the desk — but nothing establishes that the firmware needs no *more*
  than those keys when it **loads** a file rather than builds one itself.
- **Also resolves, on the side that matters:** T4.5 showed the device honours a step-active flag
  **it** cleared. The second note here is identical to the first but for that one bit, so this
  asks whether it honours a flag **we** cleared in a file it loaded — which is what `ksp2midi`'s
  `include_disabled` and every M5/M6 write actually rely on.
- **Device:** load `M4-place`, send it to the device, select Track 2, pattern 1, and **play it**.
- **Candidate:** `M4-place.KeyStepPro` — generated, not exported. Two notes on Track 2 pattern 1,
  both pitch 60 (**C3** on the device's naming), both at fresh-note defaults:

  | | step | `48` | expected |
  |---|---|---|---|
  | ordinal 1 | 1 | set | **lit, and sounds** |
  | ordinal 2 | 5 | clear | **dark, and silent — but still holds a note** |

- **Capture:** `M4-place-readback.KeyStepPro`
- **Keys:** `124_50_1_1_<1..2>` = 0, 4 · `124_109_1_1_<1..2>` = 60, 60 · `124_48_1_1_1` = 1 ·
  `124_48_1_1_5` = 0 · `124_40_1` = 3
- **Confirms if:** step 1 is lit and sounds, step 5 is dark and does not sound, pressing step 5
  still shows a note at C3, and the readback carries both pool entries.
- **Falsified if:** the project loads but Track 2 pattern 1 is empty (the recipe is missing a key
  the firmware needs on load — diff the readback against the candidate to see what); or step 5
  **sounds anyway**, which would mean the firmware treats a flag we wrote differently from one it
  wrote, and `ExportOptions.include_disabled` is wrong on the melodic side.
- **If falsified:** do not guess at the missing key. The readback diff names it.
- **Record what the Project Browser calls it.** Unknown whether MCC lists the filename stem or the
  project's own stored name, which is an integer-encoded parameter still holding whatever the
  source project was called. Clear the T6.2 leftovers out of the Templates folder first so there is
  only one plausible candidate. M5 needs this answer regardless.

### M4.2 — A pitch we changed lands on the note we meant

- [x] run 2026-08-01 — **confirmed**

- **Resolves:** key addressing, end to end, in a busy real project rather than a one-note baseline.
  A reader and a writer that share the same wrong idea of what `125_109_1_1_5` means round-trip
  perfectly and still put the note in the wrong place; only the device can tell them apart.
- **Device:** load `M4-pitch`, send it to the device, select Track 3, pattern 1, and read the note on
  **step 5** off the display.
- **Candidate:** `M4-pitch.KeyStepPro` — `project_5` with `125_109_1_1_5` changed **49 → 61**, one
  key and one line. Ordinal 5 is chosen because its randomness is 100 (it always fires), its skip
  mask plays it on the first pass, and **ordinals 6–8 share its old pitch** as a control.
- **Capture:** `M4-pitch-readback.KeyStepPro`
- **Keys:** `125_109_1_1_5` = 61, with `125_109_1_1_<6..8>` still 49
- **Confirms if:** the display reads **C#3** on step 5, where `analysis/project_5_description.txt`
  documents C#2, and steps 6–8 still read C#2. Root note and scale are both 0 in this project, so
  nothing can quantise the reading.
- **Falsified if:** step 5 still reads C#2 (the edit did not land), or a *different* step changed
  (we addressed the wrong ordinal — note that ordinal and step are different index spaces, spec
  §4), or the pitch is some third value.
- **If falsified:** diff the candidate against `project_files/project_5.KeyStepPro` first. If that
  is one line, the writer is fine and the fault is in addressing; repeat on `T1-note-place`, a
  one-note project where the display reading cannot be ambiguous.
- **Check the firmware version** before blaming the addressing: the sources carry
  `"version": "2.5.20"`, and a device updated since may have been migrated by MCC on load.

---

## Tier M5 — a converted MIDI clip on the device

**1 capture, and it can share a session with anything else.** M4 already proved that a file this
writer produces loads, transfers and plays back with zero keys changed, so the format question is
closed. What is open is narrower and is the milestone itself: **is the pattern the device plays the
clip we handed it?**

Everything between the two is desk-testable and tested — the conversion is held to M4's own 8-key
recipe in `tests/test_midi_import.py`, and the clip round-trips out again through `ksp2midi`. This
capture exists because none of that can hear the device.

### The import route

As tier M4, with one command in front of it:

```sh
uv run pytest -m hardware      # writes project_files/captures/M5-convert.KeyStepPro
cp project_files/captures/M5-convert.KeyStepPro \
   "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/"
```

### M5.1 — The clip plays back as the clip

- [ ] not yet run

- **Resolves:** whether `midi2ksp` produces a playable pattern, which is M5's whole claim.
- **Device:** load `M5-convert`, send it to the device, select Track 1, pattern 1, and **play it**.
- **Candidate:** `M5-convert.KeyStepPro` — `project_files/test_file_simple.mid` converted onto
  Track 1, pattern 1 of the factory default. Sixteen steps, every one lit, all at fresh-note
  defaults (gate 7, velocity 100, time shift 49, randomness 100). The clip is a C major run with a
  chromatic wobble, so a transposition or an off-by-one is audible rather than merely visible:

      C3 D3 E3 C3  C3 C#3 B2 C3  C3 C4 B3 A3  C3 D3 E3 C3

- **Capture:** `M5-convert-readback.KeyStepPro`
- **Confirms if:** all 16 steps are lit, the display reads that sequence starting at step 1, and
  the readback's note list matches what the converter wrote.
- **Falsified if:** the pattern is empty (the recipe is incomplete on load — but M4.1 says it is
  not, so suspect the `version` injection or the key order instead); the notes are there but start
  at some step other than 1 (the clip anchoring is wrong); or the pitches are transposed (`109` is
  not the raw MIDI note we assume).
- **If falsified:** diff the readback against the candidate. M4.1 established that this diff is
  empty when the file is right, so anything in it is the answer.
- **Record what the Project Browser calls it**, still open from M4.1. The project's own name is an
  integer-encoded parameter we do not decode, so a converted project inherits the factory
  template's — if MCC lists that rather than the filename, every conversion looks alike in the
  browser and M6 should decode the name parameter.

---

## Tier 4 — M6, step-active semantics on the melodic side

**3 captures.** D1–D4 are done and removed; what they established is in spec §4. Both tests here
extend those drum results to the melodic parameter set, which nothing has measured.

**T4.5 is the highest-value remaining capture in this document** — not because it is likely to
surprise, but because shipped code already assumes its answer.

### T4.5 — Melodic step-off

- [ ] not yet run

**3 captures.** The melodic counterpart to D1, which tested drums only.

- **Resolves:** whether `48` behaves like `52` — i.e. whether a melodic note left in the pool
  with its step-active flag clear is silent. The reader and MIDI export now drop such notes on
  *both* parameter sets, but only the drum half is measured. The melodic half rests on D1 plus
  the fact that `48` and the note list agree in every file we have, which is suggestive, not
  proof.
- **Device:** from the baseline. Track 2, pattern 1. Place notes at **beat 1** and **beat 5**, export.
  Then **toggle step 5 off without deleting the note** — the same control D1 used, not a clear —
  export. **Then listen: play the pattern and note whether beat 5 sounds.**
- **Captures:** `T4-melodic-two-notes.KeyStepPro`, `T4-melodic-step-off.KeyStepPro`
- **Keys:** `124_48_1_1_5`, and `124_50_1_1_<1..2>` plus `124_109_1_1_<1..2>` to show the pool
  is untouched
- **Confirms if:** `124_48_1_1_5` goes 1 → 0, the pool entry survives unchanged, and beat 5
  does not sound — exactly D1's shape.
- **Falsified if:** the pool entry is cleared alongside the flag (then melodic deletion and
  deactivation are the same operation), or the note still sounds with its flag clear.
- **If falsified:** `ExportOptions.include_inactive` must stop applying to melodic notes, and
  the reader's melodic `active` decode becomes informational only.

### T4.6 — Melodic pool overflow

- [ ] not yet run

**1 capture.** D3 established that a *drum* pool spills into chunk 2 at 64 events. Nothing shows
that a melodic one does, and no sample file has more than 64 melodic notes in a pattern.

- **Resolves:** whether melodic notes chunk the way drum notes do, and — the part that matters
  for code — **whether `48` stays wholly in slot 1 or follows the chunking**. The reader
  currently reads melodic step-active from slot 1 only and treats it as pattern-wide; that is
  the one assumption in the change with no capture behind it.
- **Device:** from the baseline. Track 2, pattern 1, 64 steps. Enter **more than 64 notes** — chords on
  every step is the fastest route. Export. Note whether the device refuses any, and at what count.
- **Capture:** `T4-melodic-overflow.KeyStepPro`
- **Keys:** `124_50_1_2_*` and `124_109_1_2_*` (did the pool spill?), `124_48_1_1_*` and
  `124_48_1_2_*` (did the flags spill?)
- **Confirms if:** events past 64 appear in slot 2, and `124_48_1_2_*` stays all-zero with every
  flag still in slot 1.
- **Falsified if:** `48` slot 2 is populated — then step-active is chunked alongside the pool and
  the reader must read all chunks, not just the first.
- **Also record the ceiling.** If the device errors, note the number and whether it matches the
  192 that D3 produced for drums.

---

## Tier 5 — M6, pattern scalars

**~12 captures.** Lower value per capture than tiers 2–4, but these are the settings that make a
converted pattern *sound* like the source material rather than merely contain the right notes.

### T5.1–T5.5 — The `99` bitfield

- [x] T5.1 step size — one capture, one pattern per setting, Track 2, pattern 1 1/4, pattern 2 1/8, pattern 3 1/16, pattern 4 1/32
- [x] T5.2 triplet on
- [x] T5.3 monorhythm on
- [x] T5.4 swing offset on
- [x] T5.5 playback direction — one capture , one pattern per setting, Track 2 pattern 1 Fwd, pattern 2 Rand, pattern 3 Walk
- [x] drum-side repeat on `116`

`99` is "Pattern Seq triplet state, swing offset state, polyrythm state, step size, playback
direction in a bitfield", with the dictionary's own comment placing **playback direction at bits
5–6**. Everything else is unallocated guesswork.

Known values: `Default.KeyStepPro` holds `99` = **20** (`0b0010100`) on every pattern, and
`116` (the drum equivalent) holds **16** (`0b0010000`). `initial_project` has `99` = 16 on Track 1
pattern 1 and Track 3 pattern 1, and 20 elsewhere — so bit 2 (value 4) is the one that varies in
real material. Note the seq and drum defaults already differ by exactly that bit.

**One bit is already measured, on the drum side.** `D4-lane-steplength` moves `123_116_1`
16 → 20 — bit 2 — at the moment Track 1's drum mode went Mono → Poly, which is what lets lanes
hold different step counts. So **`116` bit 2 = Mono/Poly**, and the drum half of this test only
needs to confirm the *remaining* fields. See spec §5 for the limits of that reading.

**The bit 2 asymmetry is now the sharpest question here**, not a footnote: `99` = 20 has bit 2
set by default while `116` = 16 has it clear. Polyrhythm is set to on by default for Sequence tracks. A
capture that toggles polyrhythm off on **Track 2** and watches `124_99_1` settles whether the two
halves share a layout at all — run it early, because the rest of the sweep's interpretation
depends on the answer. If setting Monorhythm to on on Track 2 swaps to the same measured value for Drums, definitively 16 means Mono and 20 mean Poly

- **Device:** from the baseline, Track 2 pattern 1. Change **one field at a time** (except for step size), returning to default
  between captures: step size, triplet on, polyrhythm on, swing offset on, playback direction, last step
  through each of its settings.
- **Captures:** `T5-99-stepsize`, `T5-99-triplet`, `T5-99-monorhythm`,
  `T5-99-swingoffset`, `T5-99-direction`
- **Keys:** `124_99_1`
- **Confirms if:** playback direction occupies bits 5–6, and each other field maps to a
  contiguous bit range that accounts for the observed defaults of 20 and 16.
- **Falsified if:** direction is elsewhere, or two fields share a bit.
- **Record the displayed setting name for every capture** — the mapping from stored bits to the
  device's own labels is the deliverable, and it cannot be reconstructed from the file.
- **Step size needs one capture**, since patterns appear to have distinct settings for this bit this saves time and exports
- **Then repeat one capture on the drum side** (`116`, `123_116_<pattern>`) to check the layout is
  shared — bit 2 aside, which `D4` already settled. If seq and drum differ, both need sweeping.

### T5.6 — Root note and scale

- [x] not yet run

- **Resolves:** `107` (root note) and `108` (scale), which are 0 in every sample file, and the
  user-scale parameters `101`–`106`.
- **Device:** from the baseline. Set a non-default root note, export. Set a non-default scale, export.
- **Captures:** `T5-rootnote`, `T5-scale`
- **Keys:** `124_107_1`, `124_108_1`
- **Confirms if:** each moves independently and the scale value indexes the device's scale list in
  display order.
- **Record the full scale list in display order** if you can page through it — that turns `108`
  into pure lookup data, like the gate table.

### T5.7 — Pattern chaining

- [ ] not yet run

- **Resolves:** how patterns chain, which is the mechanism M6 needs for source material longer
  than 64 steps. Scene parameter `84` is documented as "16 pattern in a chain (value between 0 and
  15 if defined, otherwise 127)" and reads **127 across all 16 entries of all 5 tracks in every
  sample file** — so no sample has ever used a chain.
- **Device:** from the baseline. Build a chain of **3 patterns** on Track 2 within scene 1. Export.
- **Capture:** `T5-chain-3.KeyStepPro`
- **Keys:** `121_84_1_2_<1..16>` (scene 1, track 2), and `121_83_*` (current pattern per track)
- **Confirms if:** the first three entries hold 0-based pattern numbers and the rest stay 127.
- **Falsified if:** the chain lands somewhere else, or the ordering is not what the display shows.
- **Note the track index mapping.** `121_84_<scene>_<track>_*` uses track index 5 for the Control
  track and 1–4 for the sequencer tracks, per the descriptors — worth confirming, since it is the
  one place the item ordering is not the obvious one.

### T5.8 — What the four step-skip sequences are

- [ ] not yet run

> **Not answered by ledger row O1.** O1 found that notes past the *declared last step* (`98` /
> `115`) are retained and become audible when the pattern is lengthened. That is the pattern
> length, a different mechanism from the per-note skip mask `49` / `53` this test is about. The
> two are easy to conflate at the device because both change which steps light up.

- **Resolves:** whether 16 / 32 / 48 / 64 are four **repeats** of a pattern shorter than 64 steps
  or four **pages** of a 64-step one. This blocks `ksp2midi --passes` (issue #22), which cannot be
  written until it is known, and it is the same question for `midi2ksp` in reverse.
- **Why it is open:** spec §5 calls them "four consecutive 16-step sequences", which reads like
  pages — but `project_5` pattern 1 is 16 steps long and carries notes masked to 48 and 64
  (`49` = 5 and 12). Under the pages reading those notes could never sound, which contradicts a
  hardware-confirmed description. Under the repeats reading every mask is meaningful at any
  pattern length. The file cannot settle it; only the device can.
- **Device:** from the baseline. Track 2, pattern 1, length **16 steps**. Four notes at beats 1, 5, 9, 13
  on four different pitches. Set their skip masks to 16-only, 32-only, 48-only and 64-only
  respectively. Export, then **play the pattern and listen through at least eight loops**.
- **Capture:** `T5-skip-16step.KeyStepPro`
- **Keys:** `124_49_1_1_<1..16>` (step-indexed, unlike the drum `53`)
- **Confirms repeats if:** the four notes sound on successive loops in turn — beat 1 only on
  loop 1, beat 5 only on loop 2, and so on, cycling every four loops.
- **Confirms pages if:** only the 16-masked note ever sounds and the other three are silent, or
  the device refuses to set a mask above 16 on a 16-step pattern at all.
- **Then repeat at 64 steps.** Set the pattern to 64 steps with one note per 16-step quarter, each
  masked to a *different* sequence than the quarter it sits in. Under repeats it plays all four
  over four loops; under pages three of them never sound. This is the case that separates the
  readings when the pattern is long enough for both to be coherent.
- **Also note the display.** Whatever the device calls the setting is worth transcribing verbatim —
  the vocabulary usually gives the model away.

---

## Tier 6 — Re-checks

**1 capture left** of 2. Cheap, and each removes a standing caveat. T6.2 is done.

### T6.1 — The `project_5` drum time-shift conflict

- [ ] not yet run

- **Resolves:** the one documented discrepancy in the corpus.
  `analysis/project_5_description.txt` states Time Shift **−1 for both kick hits**;
  `project_5.KeyStepPro` stores `120` = 48 and 50, which decode to **−1 and +1** against the
  centre of 49. The melodic ramp in the same project independently confirms the centre is 49, so
  a transcription slip is the likelier explanation — but nobody has looked at the device since.
- **Device:** load `project_5` on the KeyStep Pro. Read the Time Shift of both kick hits off the
  display. **This is a read, not a capture** — no export needed unless the values disagree with
  the file.
- **Confirms if:** the display shows −1 and +1, i.e. the description has a typo.
- **Falsified if:** the display shows −1 and −1, i.e. time shift does not decode the way we think
  on the drum track specifically.
- **If falsified:** drum time shift (`120`) needs its own sweep — it may not share the melodic
  centre of 49. **T7.3 is that sweep**, and it covers the full range rather than assuming ±4 is it;
  run T7.3 rather than improvising captures here.
- Either way, update `tests/fixtures/project_5.expected.json`, which currently asserts the
  conflict deliberately so it cannot quietly disappear.

### T6.2 — Is the trailing comma required? ✅ **done** (2026-08-01)

- [x] run 2026-08-01 — **the comma is not required.**

- **Resolved:** a standing write-fidelity requirement. `.KeyStepPro` files have a trailing comma
  before the closing brace, which is why `json.loads` rejects them. MCC parses with
  Boost.PropertyTree, which tolerates it — nothing established that it *required* it, and it does
  not.
- **Device:** the candidate was written as `B0baseline-commaless.KeyStepPro` into
  `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/`. It appeared in the Project
  Browser, loaded, **and transferred to the KeyStep Pro** — one step further than this test
  needed.
- **Provenance of the candidate.** Derived from `B0-baseline.KeyStepPro`
  (md5 `64b34737c68da9375ec7e1324e98936a`), so it differs from a known-good hardware export by
  **one byte**: 3,517,714 against 3,517,715, `diff` showing the single line `"126_99_9": 20,` →
  `"126_99_9": 20`. That is what makes this a clean result — nothing else varied.
- **Consequence, applied.** The writer emits strict JSON unconditionally; there is no flag.
  `ksp.lenient_json.dumps` no longer writes the comma, and `tests/test_round_trip.py` compares
  against MCC's bytes minus that one byte via the `sample_bytes_strict` fixture.
  `test_output_differs_from_mcc_by_exactly_the_trailing_comma` pins the deviation at one byte so
  nothing else can drift in behind it.
- **Scope — do not over-claim.** This tested the comma and nothing else. Tab indentation, MCC's
  key order, the absent final newline, the fixed key set and the `version` key are all still
  untested and remain mandatory. The **reader** must also still accept the comma: every
  `.KeyStepPro` file that exists has one, and `tests/test_format_invariants.py` asserts that of
  the checked-in exports.

---

## Tier 7 — Time Shift and Swing encodings

**~13 captures.** Ordinary export-and-diff captures, same workflow as every tier above. These
resolve what the *stored* values mean; Tier 8 resolves what they are worth in time. Background and
the model are in [`Timing_Calibration.md`](./Timing_Calibration.md).

Two things make this tier necessary. **Time Shift has never been swept** — the only non-default
values in the whole corpus are `project_5`'s ±1…±4 ramp, so the range is unknown and T6.1's
fallback branch merely *assumes* ±4. And **swing has never been set at all**: `74` reads 50 and
`97` / `114` read 25 in all 16 patterns of all four tracks of all five sample files, so there is
zero observational data on it.

> **Set swing to 0 for the whole of T7.1–T7.3, and place shift test notes on odd-numbered steps
> (1, 3, 5 …).** Swing displaces even-numbered steps, so a stray swing setting cannot contaminate
> the shift captures if the notes sit where swing does not reach.

### T7.1 — Time Shift range

- [ ] not yet run

- **Resolves:** `D_min` and `D_max`. **Run this first** — it decides whether the rest of the tier is
  worth doing. If the range is only ±4, Time Shift spans roughly ±4 % of a step and is useless as a
  quantization target, so M5 would snap to the grid and report the loss instead of pretending to
  represent it. If it is ±49, shift covers the entire gap between steps.
- **Device:** from the baseline. Track 2, pattern 1. Place one note at beat 1. Turn Time Shift **all the way
  down** until the display stops moving, export. Then **all the way up**, export.
- **Captures:** `T7-shift-min.KeyStepPro`, `T7-shift-max.KeyStepPro`
- **Diff against:** `T1-note-place.KeyStepPro` (or the baseline plus the note)
- **Keys:** `124_112_1_1_1` only
- **Confirms if:** exactly one key moves per capture, and the two stored values sit symmetrically
  about 49.
- **Falsified if:** the range is asymmetric about 49, or the stored value leaves 0–127.
- **Record the displayed value at both extremes.** That is the deliverable — the stored number is
  in the file, the displayed one exists only in your notes.

### T7.2 — Time Shift linearity

- [ ] not yet run

- **Resolves:** whether display → stored stays 1:1 across the whole range, which is only known
  today over `project_5`'s ±4 window.
- **Device:** from the baseline. Track 2, pattern 1. Place notes on **steps 1, 3, 5, 7, 9, 11, 13** and set
  each to a different Time Shift spread across the range found in T7.1 — both extremes, both
  half-way points, ±1, and 0. One capture holds the whole curve.
- **Capture:** `T7-shift-linearity.KeyStepPro`
- **Keys:** `124_112_1_1_<1..7>`, and `124_50_1_1_<1..7>` to confirm which note is on which step
- **Confirms if:** stored = 49 + displayed at every point.
- **Falsified if:** the mapping compresses at the extremes, the way gate does above 3.0.
- **If falsified:** it becomes lookup data like the gate table. Sweep every detent and record the
  full mapping — **do not fit a formula to it.**
- **Write down each note's displayed shift against its step number.** Note ordinal and step number
  are different index spaces (spec §4) and the mapping is not recoverable afterwards.

### T7.3 — Drum Time Shift

- [ ] not yet run

- **Resolves:** whether `120` shares the melodic centre of 49 and the same range. Also supersedes
  T6.1's fallback branch.
- **Device:** from the baseline. Track 1 in drum mode, an untouched pattern. Place a Kick at beat 1. Set
  Time Shift to **minimum, −1, 0, +1, maximum**, exporting at each. Five captures.
- **Captures:** `T7-drumshift-<display>.KeyStepPro` — `min`, `m1`, `0`, `p1`, `max`
- **Keys:** `123_120_<pattern>_1_1`
- **Confirms if:** the stored values match the melodic mapping from T7.1/T7.2 at the same displayed
  values.
- **Falsified if:** they differ at any point.
- **If falsified:** drum shift needs its own full sweep, and `project_5`'s −1/+1 reading is a real
  encoding difference rather than the transcription slip T6.1 assumes.

### T7.4 — Global swing alone

- [ ] not yet run

- **Resolves:** what `74` stores, and how the device displays it. The KeyStep Pro manual gives the
  swing range as 50 %–75 %, and `74` reads 50 in every sample file, so it is probably the percentage
  directly — but nothing has ever tested it.
- **Device:** from the baseline. Change **only** the global Swing encoder. Export at three settings: the
  minimum, something near the middle, and the maximum. Touch no per-pattern swing.
- **Captures:** `T7-swing-global-<display>.KeyStepPro`
- **Keys:** `120_74`, and **watch whether `97` / `114` move too** — they should not.
- **Confirms if:** `120_74` alone tracks the displayed percentage.
- **Falsified if:** per-pattern keys move as well, or the stored value is not the displayed one.
- **Record the minimum and maximum the encoder will reach.** If the minimum is below 50, swing is
  signed in both directions and the −25 % end of MCC's label is real.

### T7.5 — Per-pattern swing alone

- [ ] not yet run

- **Resolves:** the single most consequential question in this tier. MCC labels `97` / `114`
  *"swing (%) (an offset of 25 is applied to be send by MIDI) (−25 % to +25 %)"* — a **signed
  offset**. But `src/ksp/reader.py::_swing` reads it as an **absolute percentage** (`stored + 25`,
  so the default 25 → 50 %). Both readings agree when the global is 50, which is why every sample
  file hides the difference and no test catches it.
- **Device:** from the baseline, global swing left at its default. On **Track 2, pattern 1 only**, set the
  per-pattern swing (SHIFT + Swing encoder) to its maximum. Export. Then its minimum. Export.
- **Captures:** `T7-swing-pattern-max.KeyStepPro`, `T7-swing-pattern-min.KeyStepPro`
- **Keys:** `124_97_1`; also check `124_97_2` and `125_97_1` are untouched, so the scope really is
  one pattern of one track, and check `124_99_1` for the "swing offset state" bit.
- **Confirms if:** only pattern 1 of track 2 moves, and `99` bit changes when a non-default
  per-pattern swing exists — which would mean the flag marks "this pattern overrides the global".
- **Falsified if:** `99` does not move, or other patterns follow.
- **Record the displayed percentage.** If the display reads an absolute 50–75 %, the reader is
  right; if it reads a signed ±N %, the reader is wrong and `_swing` needs fixing.

### T7.6 — Global and per-pattern together

- [ ] not yet run

- **Resolves:** which of the three candidates governs the effective swing: `74` alone,
  `74 + (97 − 25)`, or `97 − 25` overriding `74` when the `99` flag is set.
- **Device:** from T7.5's max capture, now **also** move the global Swing to a non-default value
  distinct from the per-pattern one. Export.
- **Capture:** `T7-swing-both.KeyStepPro`
- **Keys:** `120_74`, `124_97_1`, `124_99_1`
- **Confirms if:** both keys hold their own value independently.
- **Then listen.** Play the pattern and judge whether its shuffle matches the global setting, the
  per-pattern setting, or something between. **This listening note is the actual result** — the
  stored values cannot distinguish the three candidates on their own, only the audible behaviour
  can. Tier 8 measures it precisely; this is the cheap version.

### T7.7 — Drum swing spot-check

- [ ] not yet run

- **Resolves:** whether `114` behaves like `97`.
- **Device:** from the baseline. Track 1 in drum mode. Set per-pattern swing to maximum. Export.
- **Capture:** `T7-swing-drum.KeyStepPro`
- **Keys:** `123_114_<pattern>`, `123_116_<pattern>`
- **Confirms if:** it mirrors T7.5 with the drum parameter pair.
- **Falsified if:** it does not — then drum swing needs its own sweep.

### T7.8 — Randomness control

- [ ] not yet run

- **Resolves:** whether `113` is play-probability or timing jitter. **This gates Tier 8 entirely.**
  A fresh note defaults to randomness 100, and if that means "randomise timing by 100" then every
  timing measurement in this document is measuring noise.
- **Device:** from the baseline. Track 2, pattern 1, four notes at beats 1, 5, 9, 13, all at default
  randomness. Play the pattern for a minute and **listen**: do notes ever fail to sound, and does
  the timing wander? Then set randomness to its **minimum** on all four and listen again. Export
  both.
- **Captures:** `T7-random-default.KeyStepPro`, `T7-random-min.KeyStepPro`
- **Keys:** `124_113_1_1_<1..4>`
- **Confirms if:** at 100 every note sounds every pass with steady timing — i.e. 100 means "always
  plays" and randomness is probability.
- **Falsified if:** notes drop out at 100, or onsets wander audibly.
- **If it is timing jitter:** set randomness to its minimum for **every** Tier 8 capture and say so
  in the ledger. If it is probability, minimum randomness may mean "never plays" — check which end
  is safe before relying on it.

---

## Tier 8 — Live timing capture

**~6 recordings.** The only tier that does not work by exporting files. Everything above reads what
the device *stores*; this measures what the device *does*, because the quantity we need — what one
Time Shift unit is worth in time — does not appear in the file at all.

Run this **after Tier 7**, which supplies the range to sweep, and **after T7.8**, which says whether
the measurement is meaningful.

### How to run a recording

Different from a capture. A recording is:

1. **Rig:** KeyStep Pro MIDI out → interface → DAW. Set the DAW's tempo to the value under test and
   **lock it**; do not let it chase incoming clock.
2. **Reference track.** Track 3, pattern 1: four notes at beats 1, 5, 9, 13, everything at default —
   swing 0, shift 0. Put it on its own MIDI channel. **Every measurement is a difference between a
   test note and its reference note**, which cancels interface latency and clock drift exactly.
   Never measure an absolute onset.
3. **Test track.** Track 2, pattern 1, carrying whatever shift or swing the row calls for, on a
   different channel.
4. **Record at least 8 bars** so per-cell variance is visible rather than averaged away.
5. **Export the recording** as `analysis/captures/<recording-id>.mid` and reduce it with
   `uv run python tools/reduce_timing.py`, which pairs the two channels and prints offsets in both
   ticks and milliseconds.
6. **Log the row** in the ledger: recording ID, BPM, step size, displayed shift/swing, measured
   offset, observed spread.

### The matrix

| ID | BPM | Step size | Varying | Resolves |
|---|---|---|---|---|
| R1 | 30 | 1/4 | shift = 0, ±1, ±half, ±max | the unit `U` at maximum resolution |
| R2 | 120 | 1/4 | same shift values | is `U` tempo-invariant? |
| R3 | 30 | 1/16 | same shift values | is `U` a fraction of a step or a fixed tick count? |
| R4 | 30 | 1/4 | swing at min / mid / max, shift 0 | the swing formula, and which parameter governs it |
| R5 | 30 | 1/4 | swing max **and** shift max together | do they add, or interact? |
| R6 | 30 | 1/4 | repeat of R1, fresh session | reproducibility |

- [ ] R1 — 30 BPM, 1/4, shift sweep
- [ ] R2 — 120 BPM, 1/4
- [ ] R3 — 30 BPM, 1/16
- [ ] R4 — 30 BPM, swing sweep
- [ ] R5 — swing and shift together
- [ ] R6 — repeat of R1

**Start at 30 BPM with 1/4-note steps.** That makes a step 2000 ms, so even a very fine shift unit
is tens of milliseconds — comfortably above MIDI jitter. At 120 BPM with 1/16 steps a step is
125 ms and a fine unit would be around a millisecond, which is at or below the noise floor. **The
slow, coarse setting is what makes this measurable at all.**

### Reading the result

Three candidate encodings, and the matrix separates all three:

| Model | What one unit is | Signature in the data |
|---|---|---|
| **A** — fraction of a step | `t_step / N` | R1 ≡ R2 in *ticks*; R3 differs from R1 in ms by exactly the step-size ratio |
| **B** — fixed clock ticks | a constant tick count | R1 ≡ R2 in ticks; **R3 ≡ R1 in ms** |
| **C** — absolute time | a constant in ms | **R1 ≡ R2 in ms**, not in ticks |

- **R1 vs R2 separates C** from the other two: only under C does a tempo change leave the
  millisecond offset unchanged.
- **R1 vs R3 separates A from B.** This is why BPM alone is not enough — A and B are both
  tempo-invariant, and only changing the step size tells them apart.
- **If R6 does not reproduce R1**, stop. Something in the rig is drifting and no result from this
  tier can be trusted until it is found.

Record the outcome in [`Timing_Calibration.md`](./Timing_Calibration.md) §6 and put the constant in
`ksp.constants.TIME_SHIFT_UNIT`, which is `None` until this tier produces a number. **Do not fill it
in from a plausible-looking pattern in one recording** — the failure mode is a file that loads
cleanly and plays with wrong timing, and nothing errors.

---

## Capture ledger

Fill in as you go. This table is the record; the `.KeyStepPro` files are the evidence.

Rows for the completed tiers have been removed along with their procedures. The values those
captures owed were collected in a separate gaps ledger, which is now **closed** — every row was
answered and folded into the spec on 2026-08-01.

| Test ID | Date | Displayed value / setting | Stored value | Notes |
|---|---|---|---|---|
| M4.1 | 2026-08-01 | Tr2 pat1: step 1 lit, step 5 placed and dark | `124_48_1_1_1` = 1, `124_48_1_1_5` = 0 | ✅ **done.** Loaded, transferred, and the device showed exactly what was written — one note on, one note placed. **The readback differs from the candidate by zero keys**: a full file → MCC → device → MCC → file round trip introduced no drift at all. So the 8-key placement recipe is complete on *load*, not just on save, and a cleared `48` we wrote is honoured the same as one the device cleared. |
| M4.2 | 2026-08-01 | Tr3 pat1 step 5 displays **C#3** | `125_109_1_1_5` = 61 | ✅ **done.** Track 3 loaded with its notes intact and step 5 read C#3, against C#2 in `project_5_description.txt`. Key addressing is confirmed end to end. Readback differs from the candidate by **5 keys, none of them ours**: `122/124/125/126_39` latch 2 → 3, and `123_117_1` is normalised 247 → 60 (see spec §3.3). |
| O1 | 2026-07-31 | `initial_project` Tr1 pat 9, Last Step 48 → 64 → 48 | `123_115_9` = 47 | ✅ **done.** Step-active pooled notes out to step 63. **In the saved project they are disabled and do not play** — that is the file's own state. Raising Last Step to 64 enables them (they appear and sound); lowering it back to 48 disables them again. So **notes past the last step are disabled, not stale.** The toggle was a diagnostic action, not the file's configuration. Not a planned capture — observed while investigating a `ksp2midi` warning. Does **not** answer T5.8. |
| D25 | 2026-08-01 | one note, Gate display **5.25** | `124_110_1_1_1` = 36 | ✅ **done.** Closes the gate ladder's one derived rung. Diffs to eight keys against `B0-baseline`; predicted and observed agree. Folded into spec §6.1 and `gate_ladder.txt` provenance. |
| T4.5 | | melodic step 5 toggled off | | No |
| T4.6 | | >64 melodic notes | | did `48` spill to slot 2? ceiling reached at: 192 notes. 4 chords per note until step 48. Filling step 49 was refused by the device (light would not turn on). Device displayed message of "16 notes limit in a step reached". I then tested more deeply on Track 2 Pattern 2 by setting 16 notes per step. 17th notes were refused with the 16 note limit message. I filled in 12 steps. Trying to fill in the 13th step (this was in step edit mode with overdub button on) produced the 192 limit message per pattern previously seen. The export file is T4-melodic-overflow-v2 |
| T5.* | | `99` field = | | one row per setting. For the triplet, I added more data to the export. On Track 3 Pattern 1 through 4, I changed the step size/time division number. There are 4 entires all with triplet set, 1/4 1/8 1/16 and 1/32 in that order. I figured this was worth investigating independent of the triplet being set on just Track 2 Pattern one in case there was other stacking concerns. Swing offset on the device defaults to 50% and increments by 1% each turn of the knob and finishes at 75%. The value in the export is 75%. For the drum truck, I avoided completely your suggestion because it fucking sucks. Its clear patterns dictate these values. Not tracks. For the drum track I created 11 patterns as follows: 1 - setting defaults, 2 - Seq Pattern Direction Rand, 3 - Seq Pattern direction Walk, 4 - Time Division 1/4, 5 - Time Division 1/8, 6 - Time Divison 1/16, 7 - Time Division 1/32, 8 - Time Division 1/4 Triplet,9 - Time Division 1/8 Triplet,10 - Time Division 1/16 Triplet,11 - Time Division 1/32 Triplet.|
| T5.6 | | root note / scale | | For scale, display is Chrom, Major, Minor, Dorian, Mixo, H.Min, Blues, Root, User 1, User 2. I set up the track so Track 1 in Drum mode and Track 2 have 10 patterns following that order. Of note, the Root option didn't seem to take or store anything by just pressing it. On the Rootnote export, the option is stored on Track 3 Pattern 1 and the selection was Scale Pattern Minor and the Root Note selected was D2|
| T5.7 | | 3-pattern chain | | |
| T5.8 | | 16-step pattern, one note per skip mask | | **repeats or pages?** which notes sounded: |
| T6.1 | | project_5 kick time shifts | | −1/+1 or −1/−1? |
| T6.2 | 2026-08-01 | `B0baseline-commaless.KeyStepPro`, one byte off `B0-baseline` | n/a — file-level test | ✅ **done. The comma is not required.** Loaded in MCC *and* transferred to the device. The candidate differed from a known-good export by exactly the final `,` (3,517,714 B vs 3,517,715 B), so nothing else was in play. Writer now emits strict JSON with no flag; M3's round-trip target is MCC's bytes minus that byte. Tests the comma **only** — indentation, key order, absent final newline and the fixed key set are untouched by this result. |
| T7.1 | | shift min / max displayed | | **the range — run first** |
| T7.2 | | shift per step: | | one row per note |
| T7.3 | | drum shift = | | matches melodic? |
| T7.4 | | global swing = | | min/max the encoder reaches: |
| T7.5 | | pattern swing = | | absolute % or signed ±%? |
| T7.6 | | global + pattern swing | | **which one did you hear?** |
| T7.7 | | drum swing = | | |
| T7.8 | | randomness 100 then min | | **notes drop? timing wander?** |
| R1 | | 30 BPM, 1/4, shift sweep | | measured offset per unit: |
| R2 | | 120 BPM, 1/4 | | same ticks as R1? |
| R3 | | 30 BPM, 1/16 | | same ms as R1? |
| R4 | | 30 BPM, swing sweep | | |
| R5 | | swing + shift together | | additive? |
| R6 | | repeat of R1 | | reproduced? |

## Effort summary

Remaining work only. B0 and tiers 1, 2, 3 and 4 are complete and are not listed.

| Tier | Captures left | Resolves | Milestone |
|---|---|---|---|
| 4 | 3 | melodic step-active and pool chunking | M6, M5 |
| 5 | ~13 | pattern scalars, chaining, step-skip semantics | M6, M2 |
| 6 | 1 | standing caveats (T6.2 done) | M3 |
| 7 | ~13 | Time Shift range, swing semantics | M7, M5 |
| 8 | ~6 recordings | what a Time Shift unit is worth in time | M2, M5 |
| | **~36 left** of ~57 | | |

Each tier is independently useful — stopping after any one leaves a coherent result rather than a
half-finished one.

**Remaining ranking: T4.5 → T7.1 → rest of Tier 7 → T4.6 → Tier 6 → Tier 5 → Tier 8.**

- **Tier M4 is done** and is left in this file as the record of the only file → device test there
  is. It also settled T4.5 from the writer's side: the control note in M4.1 was one *we* cleared
  in a file the device loaded, and it stayed silent.

- **T4.5 leads** because it is the one open question that the *shipped* code already depends on:
  the export drops inactive melodic notes on the strength of D1's drum result plus a corpus where
  `48` never disagrees with the pool. Three captures make that measured instead of inferred.
- **T7.1 is two captures and jumps the queue** because it is a go/no-go: if the Time Shift range is
  only ±4, the rest of Tier 7's shift work and most of Tier 8 are not worth running at all.
- **T7.5 is the other place the code may be wrong** — `reader._swing` and MCC's own field label
  disagree about whether per-pattern swing is absolute or a signed offset, and no existing test can
  tell, because every sample file is swing-neutral.
- **Tier 8 is last** because it is the only tier needing a recording rig rather than just the device
  and MCC, and because Tier 7 supplies the range it sweeps.

This ordering has a track record. The previous version put D1 and Tier 3 first as "the two places
where the current code is arguably wrong", and both were: D1 found the export emitting silent
notes, and Tier 3 confirmed the mode flag. D2 then overturned the polyphony-slot model, which
nothing had flagged as doubtful — so the ranking is a guide, not a guarantee, and a capture that
merely confirms is still worth its five minutes.
