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

| Question                                           | Blocks                                  |
| -------------------------------------------------- | --------------------------------------- |
| How global `74` and per-pattern `97` swing combine | whether `ksp2midi` may apply the global |

That is the whole of it. The background is in
[`Timing_Calibration.md`](./Timing_Calibration.md) §2.1, and the two captures that would settle it
are below.

**Tiers 7 and 8 are complete and have been removed.** Tier 7 (2026-08-05) measured the Time Shift
range and linearity, the swing encoding and scope, and the meaning of randomness. Tier 8
(2026-08-04) measured the one quantity no export can carry — what a Time Shift unit is worth in
time, which is **1/400 of a beat**, fixed, independent of both step size and tempo. The findings
are in [the spec](./format/Time_Shift_And_Swing.md) and the recordings are reduced in
[`Timing_Calibration.md`](./Timing_Calibration.md) §6.1. Two of tier 7's captures need redoing;
that is the row above.

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

## Owed swing recaptures

**2 captures.** Ordinary export-and-diff captures, not recordings. They are what is left of tier 7:
both files of these names exist but neither holds what its procedure asked for, so the question
they were meant to answer — **how the global `74` and per-pattern `97` swing combine** — is still
open. Background is in [`Timing_Calibration.md`](./Timing_Calibration.md) §2.1.

- [ ] `T7-swing-both` — must hold a non-default global **and** a non-default per-pattern swing at
  once. The file of that name is byte-identical to `T7-swing-global-75`, so the per-pattern value
  never made it in. Start from `T7-swing-pattern-max`, then move the global encoder, then export.
  **Keys:** `120_74`, `124_97_1`. Then play the pattern and note whether the shuffle you hear
  follows the global, the per-pattern value, or something between — the stored values alone cannot
  tell the three apart.
- [ ] `T7-swing-pattern-min` — byte-identical to the baseline. The displayed minimum is 50 %, which
  is also the default, so a genuine export may well be a no-op; recapture only to confirm that, and
  if it comes back identical again, **record that as the finding rather than a failure.**

Until one of these exists, `ksp2midi` applies the per-pattern value and reports the global rather
than folding it in (`global-swing-not-applied`).

---


## Capture ledger

Fill in as you go. This table is the record; the `.KeyStepPro` files are the evidence.

Rows for the completed tiers have been removed along with their procedures. The values those
captures owed were collected in a separate gaps ledger, which is now **closed** — every row was
answered and folded into the spec on 2026-08-01. **Tier 7's rows went the same way on 2026-08-05,
and tier 8's on 2026-08-06**; the findings are in [the spec](./format/Time_Shift_And_Swing.md), and
tier 8's six recordings stay reduced in
[`Timing_Calibration.md`](./Timing_Calibration.md) §6.1 because that is where the arithmetic lives.

| Test ID              | Date | Displayed value / setting | Stored value | Notes                                              |
| -------------------- | ---- | ------------------------- | ------------ | -------------------------------------------------- |
| T7-swing-both        |      | global + pattern swing    |              | **which one did you hear?** Both must be non-default |
| T7-swing-pattern-min |      | pattern swing = minimum   |              | a no-op export is a finding, not a failure          |

## Effort summary

Remaining work only. B0, tiers 1–8 and the two write tiers are complete and are not listed.

| Captures left      | Resolves                                 | Milestone |
| ------------------ | ---------------------------------------- | --------- |
| 2 recaptures       | how global and per-pattern swing combine | M2        |
| **2 left** of ~59  |                                          |           |

Both are ordinary exports — no recording rig, no sweep, one encoder each. This is the end of the
programme: every other question the device could answer has been asked.

Tier 7 earned its place at the front of the queue. T7.1 was a two-capture go/no-go — had the Time
Shift range come back as ±4, most of tier 8 would not have been worth running — and it came back
±49-ish, so the range is usable and the rest was worth doing. T7.5 was called out as "the one place
the shipped code may be wrong", and it turned out the code was right and MCC's field label was
wrong, which is a result worth having either way.

Tier 8 then earned the effort of building a rig. Its result could not have come from any export,
and it overturned the reading the files supported: a Time Shift unit looked like a fraction of a
step, because at the 1/16 grid every sample project uses, the maximum shift is exactly half a step.
Recording a second step size showed the unit is a fixed count instead. **A quantity sampled at one
setting of the lever that matters will fit whatever curve you had in mind** — the same lesson gate
taught in tier 2, learned again.

This ordering has a track record. The previous version put D1 and Tier 3 first as "the two places
where the current code is arguably wrong", and both were: D1 found the export emitting silent
notes, and Tier 3 confirmed the mode flag. D2 then overturned the polyphony-slot model, which
nothing had flagged as doubtful — so the ranking is a guide, not a guarantee, and a capture that
merely confirms is still worth its five minutes.
