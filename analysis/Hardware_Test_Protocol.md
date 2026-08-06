# KeyStep Pro hardware capture protocol

**Purpose:** resolve the format questions that cannot be answered from files already on disk, by
setting known values on the device, exporting them, and diffing — or, for a write test, by running
that loop backwards: writing a known value into a file, loading it, and reading the device's own
export back out.

**Audience:** a human at the device, and an agent re-reading this later to interpret the captures.

> **This document contains only unfinished work.** What is found is in
> [`KeyStepPro_Format_Spec.md`](./KeyStepPro_Format_Spec.md), which is the authoritative record —
> not here.

**The baseline every test below starts from** is `B0-baseline.KeyStepPro` — an initialised,
untouched project, already captured. Where a test says "from the baseline", start by loading or
re-initialising to that state; do not re-derive it.

**What is genuinely unknown and needs the device:**

| Question                                                | Blocks                                     | Tier |
| ------------------------------------------------------- | ------------------------------------------ | ---- |
| What one Time Shift unit is worth in time               | M2's grid-quantise warning, M5's quantiser | 8    |
| How global `74` and per-pattern `97` swing combine      | whether `ksp2midi` may apply the global    | 8    |

Both are the subject of [`Timing_Calibration.md`](./Timing_Calibration.md), which carries the model
and the arithmetic; tier 8 below is the recordings that feed it.

**Tier 7 is complete** (2026-08-05) and has been removed. It measured the Time Shift range and
linearity, the swing encoding and scope, and the meaning of randomness; the findings are in
[the spec](./format/Time_Shift_And_Swing.md). Two of its captures need redoing — see the note under
tier 8.

---

## How to run a capture

Every test below is one capture. A capture is:

1. **Start from a known state.** Either a freshly initialised project, or the immediately
   preceding capture in the same tier — each test says which. Never start from an unknown state.
2. **Change exactly one thing.** One parameter, one note, one setting.
3. **Read the device display and write down what it says.** The stored value is what we are
   trying to learn, so the _displayed_ value is the ground truth and only exists in your notes.
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

### The import route

Its mirror, for any test that puts a file we generated _onto_ the device. Tiers M4 and M5 used it;
so does every future write test.

1. **Generate the candidates at the desk**, before the session:

   ```sh
   uv run pytest -m hardware
   ```

   The marker-gated tests write their candidates into `project_files/captures/` and assert on the
   way out that each differs from its source by the expected key count. Readback assertions skip
   until the matching capture exists.

2. **Copy into MCC's library**, which is world-writable and needs no `sudo`:

   ```sh
   cp project_files/captures/<name>.KeyStepPro \
      "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/"
   ```

3. **Restart MCC**, find the project in the Project Browser, load it, and send it to the device.

4. **Read the device, then export back** by the route above, saving as `<name>-readback`.

A readback diff is **empty** when the file is right (M4.1), which makes it the cheapest regression
net available — anything in it is the answer.

### Device operating notes

Things that are not on the display and are easy to lose between sessions. Each is needed to
_perform_ one of the tests below.

- **Step Edit** (a physical button) is required to add notes to an existing step — that is how a
  chord gets built. It is off by default and switches itself off when you change project and come
  back.
- **Drum Mono/Poly:** SHIFT + D#2 selects Mono, SHIFT + E2 selects Poly. Poly is what gives drum
  lanes independent step counts, and it moves `116` bit 2 (spec §5).
- **ARP octave** has no display readout at all. It is SHIFT plus one of five silkscreened keys on
  the second physical octave, −1 / 0 / +1 / +2 / +3, with 0 at C#3.
- **Erasing a note** is ERASE + the step button. Toggling a step off only mutes it; the note stays
  in the pool and playing a new pitch onto the dark step re-lights the _old_ note rather than
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

**The one-change rule above applies to captures that are read by diffing.** A _sweep_ capture is
not read that way, and holding it to the same rule is what made the gate sweep — the former Tier 2,
now complete (spec §6.1) — unrunnable for months: one export per encoder detent is ~128
sync-and-save cycles through MCC. Batching collapsed it to a single capture, and Tier 7's shift
linearity sweep was read the same way: seven values on seven steps in one export.

One export contains every pattern of every track, and every note's parameter has its own key —
`124_110_<pattern>_1_<ordinal>`. So one export can carry hundreds of independent readings, read
directly by key rather than by diff. That is allowed when:

- **one parameter** is swept, and nothing else on the device is touched;
- **each value sits on a distinct note**, so no two changes share a key;
- a **note map** — which step carries which intended value — is written down _at capture time_,
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
CAP  = "project_files/captures/T7-swing-both.KeyStepPro"

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

**If it prints nothing at all, the capture is a duplicate** — the change never reached the file, or
the export never happened. **Run this before leaving the device**, while the setting can still be
redone in seconds. Two tier 7 captures failed this way and were only caught at decode time, months
of elapsed session away from the hardware: `T7-swing-both` turned out byte-identical to
`T7-swing-global-75`, which cost the tier its one question about how global and per-pattern swing
combine. A capture that silently matches its baseline is the most expensive kind of bad capture,
because nothing about the file looks wrong.

A `ksp-diff` command would be a natural by-product of M4 and would make tiers 3–5 much faster to
read, but nothing here waits on it.

### Per-test format

Each test states: **what it resolves · device steps · capture name · keys to diff · what confirms
the current assumption · what falsifies it · what to do if falsified.**

---

## Tier 8 — Live timing capture

**~6 recordings.** The only tier that does not work by exporting files. Everything above reads what
the device _stores_; this measures what the device _does_, because the quantity we need — what one
Time Shift unit is worth in time — does not appear in the file at all.

**Tier 7 cleared the way for this.** It supplies the range to sweep — displayed −49…+50, stored
0–99 — and it established that randomness is a play probability rather than timing jitter, so a
recording taken at the default randomness of 100 measures the device and not noise. Had that gone
the other way, every number below would have been meaningless.

**Two captures are still owed from tier 7**, and they belong in whatever session runs this:

- `T7-swing-both` — must hold a non-default global **and** a non-default per-pattern swing at once.
  The file of that name is byte-identical to `T7-swing-global-75`, so the per-pattern value never
  made it in and the question of how the two combine is still open. Start from
  `T7-swing-pattern-max`, then move the global encoder, then export.
- `T7-swing-pattern-min` — byte-identical to the baseline. The displayed minimum is 50 %, which is
  also the default, so a genuine export may well be a no-op; recapture only to confirm that, and if
  it comes back identical again, record that as the finding rather than a failure.

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

| ID  | BPM | Step size | Varying                              | Resolves                                           |
| --- | --- | --------- | ------------------------------------ | -------------------------------------------------- |
| R1  | 30  | 1/4       | shift = 0, ±1, ±half, ±max           | the unit `U` at maximum resolution                 |
| R2  | 120 | 1/4       | same shift values                    | is `U` tempo-invariant?                            |
| R3  | 30  | 1/16      | same shift values                    | is `U` a fraction of a step or a fixed tick count? |
| R4  | 30  | 1/4       | swing at min / mid / max, shift 0    | the swing formula, and which parameter governs it  |
| R5  | 30  | 1/4       | swing max **and** shift max together | do they add, or interact?                          |
| R6  | 30  | 1/4       | repeat of R1, fresh session          | reproducibility                                    |

- [x] R1 — 30 BPM, 1/4, shift sweep
- [x] R2 — 120 BPM, 1/4
- [x] R3 — 30 BPM, 1/16
- [x] R4 — 30 BPM, swing sweep
- [x] R5 — swing and shift together
- [x] R6 — repeat of R1

**Start at 30 BPM with 1/4-note steps.** That makes a step 2000 ms, so even a very fine shift unit
is tens of milliseconds — comfortably above MIDI jitter. At 120 BPM with 1/16 steps a step is
125 ms and a fine unit would be around a millisecond, which is at or below the noise floor. **The
slow, coarse setting is what makes this measurable at all.**

### Reading the result

Three candidate encodings, and the matrix separates all three:

| Model                      | What one unit is      | Signature in the data                                                       |
| -------------------------- | --------------------- | --------------------------------------------------------------------------- |
| **A** — fraction of a step | `t_step / N`          | R1 ≡ R2 in _ticks_; R3 differs from R1 in ms by exactly the step-size ratio |
| **B** — fixed clock ticks  | a constant tick count | R1 ≡ R2 in ticks; **R3 ≡ R1 in ms**                                         |
| **C** — absolute time      | a constant in ms      | **R1 ≡ R2 in ms**, not in ticks                                             |

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

## Phase 1 — USB read probes

**Not a tier and not part of M1–M9.** These do not go through MIDI Control Center and produce no
`.KeyStepPro` file: they talk to the device directly over raw USB and print what came back. The
protocol they exercise is read-only — nothing here writes to the device — so the one-change rule
and the export route above do not apply. Design and phase numbering live in
`docs/superpowers/specs/2026-08-05-usb-sysex-project-read-design.md`.

**Before you start.** Quit MIDI Control Center; it holds the device and the probes will not get
it. On macOS the system binds its own USB-MIDI driver to interface 2 and will not release it to an
unprivileged process, so every command below needs `sudo`. Each probe is a few seconds.

```sh
sudo uv run python tools/usb_probe.py <probe> [--save project_files/captures/H1-x.jsonl]
```

Nothing in the read protocol's address tuple identifies a project slot, so every probe reads
**whichever project is loaded on the panel**. Note which one that is in the ledger — H4.1 is what
settles whether a slot can be selected at all.

### H1.1 — Identity

- [x] **run 2026-08-06 — confirmed.** Reply byte-identical to the capture's frame 9.

- **Resolves:** whether the firmware version can be read at all. Nothing in the read protocol
  carries it, and a project file always has one, so without this `bulk_read` has to assume
  `2.5.20` from the capture.
- **Command:** `usb_probe.py identity`
- **Confirms if:** the decoded version is `2.5.20`.
- **Falsified if:** no reply arrives, or the version differs. A different version is not a bug —
  it means the firmware was updated, and `bulk_plan` should be regenerated from the new MCC
  descriptor before trusting a full dump.

### H1.2 — Single scalar read

- [x] **run 2026-08-06 — confirmed.** `120_37 = 3`, the same value the capture holds.

- **Resolves:** whether the whole stack works end to end — framing out, request, reply, ack,
  de-framing in — on one byte, before anything longer is attempted.
- **Command:** `usb_probe.py scalar`
- **Confirms if:** any value comes back for `120_37`. The capture holds `3`.
- **Falsified if:** the read times out, or the device answers a different address than it was
  asked for. A timeout here means the handshake, not the codec — run H1.4 next.

### H1.3 — Throughput

- [x] **run 2026-08-06 — confirmed, and it is free.** 3.994 ms at `count=16`, 3.998 ms at
  `count=64`, 64 values delivered. The period does not move with the payload, so a full dump goes
  from 38.3 s to 9.6 s for nothing but a different count byte. **Not yet acted on** — see the
  Phase 3 note below.

- **Resolves:** whether `count` may exceed the 16 MCC never goes above. At 16 a full dump is ~36 s;
  at 64 it would be ~10 s. **This is a re-confirmation, not a discovery** —
  `keysteppro_usb_investigation.md` already records a live `count=0x40` request answered with 64
  bytes. That note predates the protocol decode, which is why it is being run again.
- **Command:** `usb_probe.py throughput`
- **Confirms if:** the `count=64` row returns 64 values and its median period is close to the
  `count=16` row's — throughput is per-request, not per-byte.
- **Falsified if:** `count=64` returns short, errors, or takes four times as long. Then 16 is a
  device limit rather than an MCC convention and the plan stays as generated.

### H1.4 — Prologue minimisation

- [x] **run 2026-08-06 — settled: there is no handshake.** All four combinations returned
  `120_37 = 3`, including both frames skipped.

- **Resolved:** which of the two handshake frames a read actually needs. The answer is **neither**.
  MCC sends a universal identity request and then `f0 00 20 6b 7f 42 05 01 f7`, and the
  investigation notes guessed the latter was an "unlock or mode switch". It unlocks nothing: a
  cold read answers without it. `bulk_read` needs to send no prologue at all.
- The identity request is still required, but for the **version string** in a byte-identical file,
  not as a handshake. That distinction is the finding.
- **Command to re-run:** `usb_probe.py prologue` — it runs all four combinations itself.
- **Would have been falsified if:** only the both-sent row worked. It was not.

### H1.5 — The 0xFF sentinel

- [x] **run 2026-08-06 — confirmed.** Patterns 1–13 read `255` raw; patterns 14–16 read `60`.
  `0xFF` survives raw USB intact, so the `247` in every project file is MCC's corruption of it and
  a writer must never emit `247`.

- **Resolves:** whether `0xFF` reaches a raw-USB reader intact. It is a MIDI System Reset byte, so
  no conformant host parser passes it through inside a SysEx — that is why MCC writes `247` and why
  247 is the only number above 127 in any project file. If it survives here, the file's 247 is
  confirmed as host-side corruption of a real device value meaning *pattern default pitch unset*.
- **Command:** `usb_probe.py sentinel` — reads `123_117_1` through `123_117_16`.
- **Confirms if:** at least one pattern reads `255` raw. Which patterns are unset depends on the
  loaded project; `initial_project` had patterns 1–13 unset.
- **Falsified if:** every pattern reads `247`, or the reads that should be unset come back empty.
  Then the sentinel is being eaten below `deframe` and the transport, not MCC, is the lossy part.

### Probe ledger

**All five run 2026-08-06 and all five confirm.** The loaded project answered `120_37 = 3` with
patterns 1–13 unset, which is what `initial_project.KeyStepPro` holds — the same project the
Recall To capture was taken from. Raw output in `usb_probe_results.txt`.

| Probe | Date       | Loaded project | Result |
| ----- | ---------- | -------------- | ------ |
| H1.1  | 2026-08-06 | initial_project | version = **2.5.20**. Reply `f07e7f060200206b0200090025140502f7`, byte-identical to capture frame 9 |
| H1.2  | 2026-08-06 | initial_project | `120_37` = **3**, matching the capture |
| H1.3  | 2026-08-06 | initial_project | count=64 **honoured**, 64 values. Median 3.994 ms at 16, 3.998 ms at 64 — flat. Full dump 38.3 s → 9.6 s |
| H1.4  | 2026-08-06 | initial_project | **all four rows succeeded.** No handshake is required — neither the identity request nor the `0x05` frame |
| H1.5  | 2026-08-06 | initial_project | patterns 1–13 read **255** raw; 14–16 read 60. The sentinel survives raw USB |

**Two findings change later phases.**

- **H1.4 removes the prologue.** `bulk_read` sends no handshake. The `0x05` frame is MCC's habit,
  not the device's requirement, and the "unlock or mode switch" guess in
  `usb_midi_investigation/keysteppro_usb_investigation.md` is wrong.
- **H1.3 offers a 4× dump, and it is deliberately not taken yet.** `bulk_plan.py` is generated to
  reproduce MCC's request stream byte-for-byte, and `test_bulk_plan.py` holds it there. Raising the
  count rewrites that stream, so it needs its own verification — the tail chunks of the 24-lane and
  240-entry parameters do not divide by 64 the way the 64-step ones do, and a count that overruns a
  parameter's extent has never been tested. **Phase 3 work, gated on H3.2's byte-diff**, not a
  drive-by change to a passing plan.

---

## Capture ledger

Fill in as you go. This table is the record; the `.KeyStepPro` files are the evidence.

Rows for the completed tiers have been removed along with their procedures. The values those
captures owed were collected in a separate gaps ledger, which is now **closed** — every row was
answered and folded into the spec on 2026-08-01. **Tier 7's rows went the same way on 2026-08-05**;
its findings are in [the spec](./format/Time_Shift_And_Swing.md).

| Test ID | Date | Displayed value / setting | Stored value | Notes                                                                    |
| ------- | ---- | ------------------------- | ------------ | ------------------------------------------------------------------------ |
| R1      |      | 30 BPM, 1/4, shift sweep  |              | measured offset per unit: See [`Timing_Calibration.md`](./Timing_Calibration.md) |
| R2      |      | 120 BPM, 1/4              |              | same ticks as R1? See [`Timing_Calibration.md`](./Timing_Calibration.md)  |
| R3      |      | 30 BPM, 1/16              |              | same ms as R1? See [`Timing_Calibration.md`](./Timing_Calibration.md)     |
| R4      |      | 30 BPM, swing sweep       |              | See [`Timing_Calibration.md`](./Timing_Calibration.md)                    |
| R5      |      | swing + shift together    |              | additive? See [`Timing_Calibration.md`](./Timing_Calibration.md)          |
| R6      |      | repeat of R1              |              | reproduced? See [`Timing_Calibration.md`](./Timing_Calibration.md)        |

## Effort summary

Remaining work only. B0, tiers 1–7 and the two write tiers are complete and are not listed.

| Tier | Captures left      | Resolves                                | Milestone |
| ---- | ------------------ | --------------------------------------- | --------- |
| 8    | ~6 recordings      | what a Time Shift unit is worth in time | M2, M5    |
|      | + 2 recaptures     | how global and per-pattern swing combine | M2       |
|      | **~8 left** of ~59 |                                         |           |

Each tier is independently useful — stopping after any one leaves a coherent result rather than a
half-finished one.

**Tier 8 is all that is left**, and it is last for the reason it always was: it is the only tier
needing a recording rig rather than just the device and MCC. The two owed swing recaptures are
ordinary exports and should be done in the same session, since the rig is irrelevant to them.

Tier 7 earned its place at the front of the queue. T7.1 was a two-capture go/no-go — had the Time
Shift range come back as ±4, most of tier 8 would not have been worth running — and it came back
±49-ish, so the range is usable and the rest is worth doing. T7.5 was called out as "the one place
the shipped code may be wrong", and it turned out the code was right and MCC's field label was
wrong, which is a result worth having either way.

This ordering has a track record. The previous version put D1 and Tier 3 first as "the two places
where the current code is arguably wrong", and both were: D1 found the export emitting silent
notes, and Tier 3 confirmed the mode flag. D2 then overturned the polyphony-slot model, which
nothing had flagged as doubtful — so the ranking is a guide, not a guarantee, and a capture that
merely confirms is still worth its five minutes.
