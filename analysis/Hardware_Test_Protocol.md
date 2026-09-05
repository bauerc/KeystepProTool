# KeyStep Pro hardware capture protocol

**Purpose:** resolve the format questions that cannot be answered from files already on disk, by
setting known values on the device, exporting them, and diffing — or, for a write test, by running
that loop backwards: writing a known value into a file, loading it, and reading the device's own
export back out.

**Audience:** a human at the device, and an agent re-reading this later to interpret the captures.

> **This document holds no unfinished work.** Every tier it once carried has been answered and
> removed; what survives is the *method*, for the next question that needs the device. Findings live
> in [`KeyStepPro_Format_Spec.md`](./KeyStepPro_Format_Spec.md), which is the authoritative record —
> never here.

**The baseline every test below starts from** is `B0-baseline.KeyStepPro` — an initialised,
untouched project, already captured. Where a test says "from the baseline", start by loading or
re-initialising to that state; do not re-derive it.

**What is genuinely unknown and needs the device: Phase 3's acceptance run.** Every format question
this programme opened has been answered, and the procedures have been removed as each tier closed.
What is left below is the method — how to run a capture, the export and import routes, the device
operating notes, the rules — kept because the next format question will need all of it, and because
reconstructing it from memory is exactly how a capture gets taken wrongly. Phase 3 (below) is the
one open item: H3.1 and H3.2 have not yet been run on hardware.

**Tiers 7 and 8 are complete and have been removed.** Tier 7 (2026-08-05) measured the Time Shift
range and linearity, the swing encoding and scope, and the meaning of randomness. Tier 8
(2026-08-04) measured the one quantity no export can carry — what a Time Shift unit is worth in
time, which is **1/400 of a beat**, fixed, independent of both step size and tempo. The findings
are in [the spec](./format/Time_Shift_And_Swing.md) and the recordings are reduced in
[`Timing_Calibration.md`](./Timing_Calibration.md) §6.1. T7.6 also settled the last of it by ear:
**the per-pattern swing takes precedence over the global**, so `74` is never folded in.

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

## Nothing is owed

Every capture this programme called for has been taken and read. `T7-swing-pattern-min` and
`T7-swing-both` both came back byte-identical to files they were meant to differ from — the first
because 50 % is both the minimum and the default so the export really is a no-op, the second
because the per-pattern value never made it into the capture. Neither is worth redoing: the
question they served was answered at the device instead.

## Open from M6 — one the import direction cannot settle

It does not block a conversion: it is a place `midi2ksp` reports rather than decides, because
deciding would mean inventing a limit the captures do not show.

### H5.1 — Does a gate survive a chain boundary?

**What it resolves.** A note in the last steps of a chained pattern whose gate runs past the
pattern's last step. `midi_import` warns (`gate-past-end`) that the device "loops the pattern
rather than sustaining" it, which is measured for a *looping* pattern and assumed for a *chained*
one. If a chain sustains into the next pattern, a split track can carry ties across the seam and
the warning is wrong for that case.

**Device steps.** Write two chained patterns on one track. On the first, place a note on step 64
with a gate of 4 steps. Play the chain and listen to, or record, the first two steps of pattern 2.

**Confirms the assumption.** The note stops at the seam. **Falsifies it.** It sustains into
pattern 2 — in which case `gate-past-end` should fire only for an unchained pattern, and
`plan_track` may keep the full gate on a split track's interior patterns.

## Phase 1 — USB read probes

**Not a tier and not part of M1–M14.** These do not go through MIDI Control Center and produce no
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

Byte 7 of every frame carries the **project slot**, but confirmed on hardware 2026-08-14, firmware
2.5.20, it is the `05 <slot>` prologue that *selects* the project — byte 7 only agrees with it
([spec 7.4](./format/SysEx_Direct_Transfer_Path.md)). Every probe below sent `01` and read
whichever project happened to be loaded, so none of them exercises project selection; note the
loaded project in the ledger. `usb_probe.py` now takes a `--slot` and sends `05 <slot>` itself
before reading, so naming a slot selects it and reads that slot's data **as stored** — a
device-side edit that was not saved does not travel.

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
  from 38.3 s to 9.6 s for nothing but a different count byte. **Acted on** by `ksp.bulk_fast`,
  which went further than this probe measured — see the Phase 1 findings note below.

- **Resolves:** whether `count` may exceed the 16 MCC never goes above. At 16 a full dump is ~36 s;
  at 64 it would be ~10 s. **This was a re-confirmation, not a discovery** — an early investigation
  note had already sent a live `count=0x40` request and been answered with 64 bytes, but it predated
  the protocol decode, which is why it was run again properly.
- **Command:** `usb_probe.py throughput`
- **Confirms if:** the `count=64` row returns 64 values and its median period is close to the
  `count=16` row's — throughput is per-request, not per-byte.
- **Falsified if:** `count=64` returns short, errors, or takes four times as long. Then 16 is a
  device limit rather than an MCC convention and the plan stays as generated.

### H1.4 — Prologue minimisation

- [x] **run 2026-08-06 — all four combinations returned `120_37 = 3`, including both frames
  skipped. Holds only for the already-loaded project** — see the 2026-08-14 correction below.

- **Resolved:** which of the two handshake frames a read of the *already-loaded* project needs.
  The answer is **neither**. MCC sends a universal identity request and then
  `f0 00 20 6b 7f 42 05 01 f7`, and the investigation notes guessed the latter was an "unlock or
  mode switch". Confirmed on hardware 2026-08-14: it is not a mode switch, it is what *selects*
  the project — it could be skipped here because the project read was the one already loaded, so
  nothing needed selecting. A read of a *different* slot needs `05 <slot>` first
  ([spec 7.4](./format/SysEx_Direct_Transfer_Path.md)).
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

### H1.6 — Count ceiling and extent overrun

- [x] **run 2026-08-06 — confirmed, and the ceiling is 100, not 127.** A `count` of `0x7f` came
  back echoing `0x64` with exactly 100 values. 65 and 96 were honoured exactly. Reading past an
  item's extent is **silent**: 106 values requested from index 1 of a 64-step item returned the 64
  real values followed by 36 × `0x7f`, with no error and no short reply. `nIdx=4` drew no reply at
  all. Full account in [spec 7.7](./format/SysEx_Direct_Transfer_Path.md).

- **Resolves:** how far `count` may be pushed above the 64 H1.3 confirmed, and — the question
  H1.3's note left open — what happens when a count overruns a parameter's extent. Both gate any
  future raise of the count in `ksp.bulk_plan`.
- **Command:** none. **This probe has no `usb_probe.py` subcommand**, unlike H1.1–H1.5. It was run
  by appending request lines to `outbound_sysex_sequence.txt` and replaying them with
  `usb_midi_investigation/replay_handshake.py`; raw output is in `ksp_clean_bytes_log.txt` and
  `ksp_raw_packets_log.txt`. Giving it a subcommand is the obvious way to make it repeatable.
- **Two script faults to fix before the next replay run.** `send_and_read` reads with `timeout=2`
  — two milliseconds — so a reply arriving with any gap is truncated and looks exactly like a
  device-imposed cap. And the flush condition `line_idx % 100 == 0` never fires past line 0 on a
  short file, so a probe that wedges the device loses every result after the first.
- **Confirms if:** a `count` above 100 comes back echoing `0x64` with 100 values, and an overrunning
  read returns the full count padded rather than erroring or returning short.
- **Falsified if:** a large count errors, returns short, or the echoed count matches what was asked.
  A *smaller* echo for a request starting further into the item would mean the clamp follows the
  extent rather than being a fixed buffer — that was tested directly (start 65, count 127) and it
  clamped to 100 the same as start 1, so the cap is flat.

### Probe ledger

> **This table is on its way out.** A finding belongs in the spec, in one place, stated as a fact.
> Kept here it is a second copy that drifts, obfuscates the fact it duplicates, and has to be
> cross-read to be trusted. Rows are cut to a verdict and a link as each probe closes; delete the
> table outright once nothing points at it.

**All six run 2026-08-06 and all six confirm.** The loaded project answered `120_37 = 3` with
patterns 1–13 unset, which is what `initial_project.KeyStepPro` holds — the same project the
Recall To capture was taken from. Raw output in `usb_probe_results.txt`, and for H1.6 in
`ksp_clean_bytes_log.txt`.

| Probe | Date       | Loaded project | Result |
| ----- | ---------- | -------------- | ------ |
| H1.1  | 2026-08-06 | initial_project | version = **2.5.20**. Reply `f07e7f060200206b0200090025140502f7`, byte-identical to capture frame 9 |
| H1.2  | 2026-08-06 | initial_project | `120_37` = **3**, matching the capture |
| H1.3  | 2026-08-06 | initial_project | count=64 **honoured**, 64 values. Median 3.994 ms at 16, 3.998 ms at 64 — flat. Full dump 38.3 s → 9.6 s |
| H1.4  | 2026-08-06 | initial_project | **all four rows succeeded, for the already-loaded project.** No handshake is required to re-read what is already loaded — neither the identity request nor the `0x05` frame. Corrected 2026-08-14: `0x05` is what selects a *different* project ([spec 7.4](./format/SysEx_Direct_Transfer_Path.md)) |
| H1.5  | 2026-08-06 | initial_project | patterns 1–13 read **255** raw; 14–16 read 60. The sentinel survives raw USB |
| H1.6  | 2026-08-06 | initial_project (restored) | `count` clamps to **100**; the reply echoes the honoured count, not the requested one. Overrun is **silent** — 106 asked, 64 real values then 36 × `0x7f`. Indices are 1-based; `nIdx=4` draws no reply |
| H2.1–H2.4 | 2026-08-14 | hand-built pattern, slot 2 | **all confirm** — the read matches the panel. Facts in [spec 7.3](./format/SysEx_Direct_Transfer_Path.md) |
| H4.1  | 2026-08-14 | all sixteen slots | **confirmed** — `05 <slot>` selects the project. Facts in [spec 7.4](./format/SysEx_Direct_Transfer_Path.md) |

**H1.6 ran across two device states.** The first pass went out while track 1 had been deleted from
the panel, so every `7b` value in it reads `0x7f` and it establishes lengths only. The project was
reloaded to `initial_project` before the overrun probes, and the 64 real values they returned are
byte-identical to the populated `count=64` reply from the first session — which is what makes
"64 real values then padding" a reading of the extent rather than of an empty track.

**Three findings change later phases.**

- **H1.4 removes the prologue for re-reading the already-loaded project.** `bulk_read` need send no
  handshake to read what is already on the panel, and the early investigation note's "unlock or
  mode switch" guess for `0x05` is wrong. Corrected 2026-08-14: `0x05 <slot>` is not habit, it is
  what *selects* a project. H1.4 could skip it because the project it read was the one already
  loaded — the ledger records that as `initial_project` and never recorded which slot that was, so
  the probe says nothing about naming a slot ([spec 7.4](./format/SysEx_Direct_Transfer_Path.md)).
  `bulk_read` now sends `0x05 <slot>` itself, since a read of any other project needs it.
- **H1.3 offered a 4× dump, and `ksp.bulk_fast` took about 9×.** The obstacle this probe recorded —
  that `bulk_plan.py` is generated to reproduce MCC's request stream byte-for-byte, and
  `test_bulk_plan.py` holds it there — was sidestepped rather than paid: `bulk_fast` derives a
  second walk from the same `PLAN` and leaves the generated one alone, so MCC's stream and its pin
  both still hold. Nor do the tail chunks need the fixed count this note feared. A run is coalesced
  by its own extent, so the 24-lane and 240-entry parameters simply yield shorter requests than the
  64-step ones. 8,951 requests become 2,474 on tape 1 and 2,443 on tape 2
  ([spec 7.8](./format/SysEx_Direct_Transfer_Path.md)). **What remains gated on H3.2's byte-diff is
  only the default**: `read_raw` still walks MCC's stream unless asked for `fast`, because the
  saving is counted against the tapes and no full dump has yet been checked against a device.
- **H1.6 answers the overrun half of that, and moves the risk.** Overrunning a parameter's extent
  is no longer untested: the device pads to the full count with the item's own unset value and
  neither errors nor returns short. So an overrunning request is safe to *send* and unsafe to
  *store* — the padding is indistinguishable from a real unset entry, and a raised count must clip
  by the plan's declared extent rather than by anything in the reply. The ceiling is 100, not 64,
  so the tail chunks have more room than H1.3 assumed. `bulk_fast` meets this by never spending it:
  it asks for a run's declared extent and no more, so no reply it draws carries padding to clip.
  The rule still governs any walk that does overrun. See
  [spec 7.7](./format/SysEx_Direct_Transfer_Path.md).

**Settled 2026-08-14.** H1.4's "no handshake required" was measured against the project already
loaded on the panel, and stands for that case only. The `0x05` frame is not habit: it is what
selects the slot, so reading any other project needs `0x05 <slot>` sent first
([spec 7.4](./format/SysEx_Direct_Transfer_Path.md)).

---

## Phase 2 — correctness against visible ground truth ✅ **ran 2026-08-14, all probes passed**

Ground truth the panel itself provides, not a capture: the note pool, the step-active array and a
MIDI export of one pattern, checked against what H2.1 puts on the panel by hand. **H4.1** (Phase
4's probe, below) rode along in the same run — once the transport is open there is nothing left
to pay to also flip byte 7 and re-read.

One command, over one open transport, runs H2.2, H2.3, H2.4 and H4.1:

```sh
sudo uv run python tools/usb_probe.py \
  --save project_files/captures/H2-phase2.jsonl \
  --slot A --other-slot B --track 1 --pattern 1 \
  --steps 1,5,9,13 --pitches 60,64,67,72 \
  --midi-out project_files/captures/H2-4.mid \
  phase2
```

**Every option goes before the probe name**, as they do for the Phase 1 probes. `phase2 --slot 2`
is an `unrecognized arguments` error, and the place to find that out is not with the device
already on the desk.

Nothing here writes to the device.

### The pattern to build, and how to read it back

Panel work first, in a scratch slot **A**: Track 1 in **Seq** mode — item 123 is also the drum
track item, so Seq mode matters or the export takes the drum set — Pattern 1, 16 steps, notes on
steps 1/5/9/13, ascending pitches, one deliberately long gate. **Save it**; the read is of stored
data. Slot **B** is any slot whose Track 1 / Pattern 1 differs, and it should hold notes of its
own rather than be empty: an empty pool reads back all `127`, which is both the empty marker and
what a degraded read returns (H1.6 saw `36 × 0x7f` on an overrun), so an empty B is ambiguous.

Then the command above. It prints PASS/FAIL for the note pool against `--steps`/`--pitches`, for
the step-active array, and writes `--midi-out` to listen to. `120_37` coming back `0x7f` means the
device is not returning that slot's contents at all — most likely it has never been saved.

---

## Phase 3 — acceptance

The milestone gate: a whole project pulled off the device, checked against MCC's own export of the
same project. Everything up to here has been probes and fragments; this is the first run that has
to hold end to end. Neither entry below has run on hardware yet.

### H3.1 — Full dump

- [ ] **not yet run.**

- **Resolves:** whether a full project reads correctly off the device end to end, at the request
  volume `bulk_fast` actually walks — Phase 1 and 2 exercised single scalars, one pattern and a
  sixteen-slot sweep of one field, never all 117,783 addresses in one run.
- **Command:**

  ```sh
  sudo ksp-pull project_files/captures/H3-pull.KeyStepPro --slot <N>
  ```

  Any populated slot works; `--slot` needs no panel work first, per Phase 4. The slot is read as it
  was **saved**, so save any panel edits before pulling. Add `--mcc-plan` to walk MCC's
  8,951-request stream instead of the coalesced 2,474 if the two need comparing directly on
  hardware.

  The Swift CLI reads the same slot over CoreMIDI, so it wants no `sudo` and no libusb, and the two
  files must `cmp`. `scripts/pull_parity.sh` holds that over the tapes; this is the same check on
  the wire, and it costs one more read:

  ```sh
  swift/.build/debug/ksp-swift-cli pull project_files/captures/H3-pull-swift.KeyStepPro --slot <N>
  ```

  `--also-midi` on either core writes the `.mid` beside the project from the same read. It costs no
  extra read to check, because the file it writes is the one a separate `export` of that project
  makes, and `tools/midi_events.py` compares the two cores' across the running-status difference:

  ```sh
  swift/.build/debug/ksp-swift-cli pull project_files/captures/H3-pull-swift.KeyStepPro \
      --slot <N> --also-midi --force
  swift/.build/debug/ksp-swift-cli export project_files/captures/H3-pull-swift.KeyStepPro \
      -o /tmp/separate.mid
  cmp project_files/captures/H3-pull-swift.mid /tmp/separate.mid
  ```
- **Confirms if:** the command completes, `ksp.reader.read_project` parses the result without
  error, and the printed note count and tempo look like the loaded project.
- **Falsified if:** the device times out, returns a filler answer (an unsaved slot reads as `0x7f`
  throughout and `bulk_read` refuses it, exit 1), or the parsed project disagrees with what the
  panel shows for that slot.

### H3.2 — Byte-diff against MCC's export

- [ ] **not yet run.**

- **Resolves:** whether the coalesced walk `ksp-pull` uses by default reproduces MCC's export byte
  for byte. This is what promotes `bulk_fast` from "checked against the tapes" to "checked against
  the device" — the saving H1.3 and §7.8 count is over 8,951 requests that were never replayed
  live.
- **Pick a project whose per-pattern scalars differ across its patterns**, and check that they do
  (`123_115` — the step count — is the readiest: a project of all-16-step patterns holds it
  uniform). This is the check #255 escaped: where every pattern holds the same value, a walk that
  reads pattern 1 and repeats it is indistinguishable from a correct one.
- **Command:** Recall the same project H3.1 pulled (slot `<N>`) in MCC and export it, then compare
  against the file H3.1 already wrote:

  ```sh
  cmp path/to/mcc-export.KeyStepPro project_files/captures/H3-pull.KeyStepPro
  wc -c path/to/mcc-export.KeyStepPro project_files/captures/H3-pull.KeyStepPro
  ```

  **Read this before running it: a passing H3.2 does not print "identical".** `ksp-pull` writes
  strict JSON; every file MCC writes ends `,\n}` with a trailing comma before the closing brace
  that this writer deliberately omits. That one-byte deviation was settled by T6.2 and is pinned in
  `tests/test_round_trip.py::test_output_differs_from_mcc_by_exactly_the_trailing_comma`. So `cmp`
  is expected to report one difference, and **where** it reports it is the whole result: `cmp`
  stops at the first differing byte, so a difference on the *last* line proves every byte before it
  matched. Rehearsed against `initial_project.KeyStepPro`, a pass looks like

  ```
  differ: char 3523190, line 153498      # the last line -- the trailing comma, nothing before it
  3523192 mcc-export.KeyStepPro
  3523191 H3-pull.KeyStepPro             # exactly one byte shorter
  ```

  A single wrong value in the middle of the file moves that `char` figure by about 1.7 MB, which is
  why the position and not the mere presence of a difference is what is being read.
  `tests/test_pull_cli.py::test_the_dump_is_byte_identical_to_mcc_s_export` already holds this over
  the replayed capture in CI; H3.2 is the same check against a live device.
- **Confirms if:** `cmp`'s first difference falls on the file's last line and the two sizes differ
  by exactly one byte.
- **Falsified if:** they differ anywhere earlier, or by more than one byte. That would mean the
  coalesced walk or the melodic gate ([spec 7.8](./format/SysEx_Direct_Transfer_Path.md)) drops or
  misreads something the tapes never exposed, and `ksp-pull` defaulting to the coalesced walk would
  have to be revisited — `--mcc-plan` is the comparison to run next in that case.

---

## Phase 4 — the project slot ✅ **settled affirmatively, 2026-08-14**

One probe, and it was the last thing standing between the read path and a project chooser.

### H4.1 — Does the device honour the project slot?

- [x] **run 2026-08-14 — CONFIRMED.** A project can be named and read without touching the panel.
  It is the `05 <slot>` prologue that selects, not byte 7 alone — see
  [spec 7.4](./format/SysEx_Direct_Transfer_Path.md).

- **Resolved:** what selects a project, and that all sixteen slots are readable without touching
  the panel. The facts are in [spec 7.4](./format/SysEx_Direct_Transfer_Path.md) — this entry
  keeps only how to re-run it.
- **Command:** the sixteen-slot sweep, `slots`. As with every probe here, every option goes
  **before** the probe name:

  ```sh
  sudo uv run python tools/usb_probe.py --save project_files/captures/slots.jsonl slots
  ```

**Do not extend this to the write direction.** Confirming byte 7 on a read costs nothing. Testing
it on a write means sending 8,951 frames to a slot, and spec 7.5 flags `06 <slot>` as an untested
commit — that needs its own protocol entry and a slot the user is willing to lose.

---

## Phase 6 — the transport ✅ **settled affirmatively, 2026-09-03**

One probe, and it was what stood between the Swift port and a read the app could actually perform.

### H6.1 — Does the device answer over CoreMIDI rather than raw USB?

- [x] **run 2026-09-03 — CONFIRMED, with one caveat.** Identity, short read, coalesced read at count
  16 and at the count-100 ceiling, and the sixteen-slot prologue sweep all answer over the ordinary
  CoreMIDI endpoint, unprivileged, at 4.00 ms an exchange — the same period H1.3 measured on raw
  USB, so the transport costs nothing. `bulk_fast`'s whole 2,044-frame walk replayed in **8.20 s,
  2,044 answered, 0 mismatched** — the plan as it stood before #255, and "0 mismatched" says every
  frame was answered, not that every answer was right. The caveat: **CoreMIDI truncates a reply at the first `0xFF`**, so
  the `123_117` sentinel range comes back empty and must be re-read element-wise. Facts and the
  recommendation are in [spec 7.9](./format/SysEx_Direct_Transfer_Path.md) — this entry keeps only
  how to re-run it.

- **Nothing to quit and no `sudo`.** This is the one probe here that neither needs the device to
  itself nor needs root: it goes *through* macOS's USB-MIDI driver rather than detaching it, which
  is the whole finding.
- **Command:** compile the standalone probe and run it. It is deliberately not a package target —
  `KSPKit` takes no dependency, and the probe answers a question rather than shipping a feature.

  ```sh
  swiftc -O tools/coremidi_probe.swift -o /tmp/coremidi_probe
  /tmp/coremidi_probe list                          # the endpoints CoreMIDI publishes
  /tmp/coremidi_probe exchange "KeyStep Pro" 1      # identity, scalar, count 16, count 100
  /tmp/coremidi_probe slots "KeyStep Pro"           # the sixteen-slot prologue sweep
  /tmp/coremidi_probe throughput "KeyStep Pro" 1    # 200 rounds at each of count 1/16/64/100
  /tmp/coremidi_probe sniff 20                      # whatever arrives, e.g. during an MCC recall
  ```

- **Replaying a real walk** is what turned up the `0xFF` truncation, and it is the only figure here
  that is a timed dump rather than a projection. Generate the plan at the desk, then replay it —
  `replay` reports any reply carrying fewer values than its echoed count:

  ```sh
  uv run python -c "
  from ksp import bulk_fast
  from ksp.sysex import build_read_request
  print('\n'.join(build_read_request(r, 1).hex() for r in bulk_fast.iter_requests()))
  " > /tmp/plan.txt
  /tmp/coremidi_probe replay "KeyStep Pro" 1 /tmp/plan.txt
  ```

- **Which process holds interface 2** is the question behind the question, and `ioreg` answers it
  without the device being busy:

  ```sh
  ioreg -r -c IOUSBHostInterface -l -w0 | awk '/KeyStep Pro/,0' |
      grep -E 'bInterfaceNumber|IOUserClientCreator'
  ```

- **If the probe goes silent, restart CoreMIDI before suspecting the device.** An MCC launch-and-quit
  cycle left the endpoint enumerated and accepting sends while the device answered nothing, identity
  included. Nothing needed unplugging:

  ```sh
  killall MIDIServer      # launchd respawns it on the next client connection
  ```

  Everything came back byte-identical on the next run. Note also that `MIDIServer` is
  launch-on-demand, so the `ioreg` line above reads as though nothing owns interface 2 unless
  something is holding a MIDI client open while you run it — `sniff` in another shell does.

- **Reading a whole project over CoreMIDI** is the end of the chain. `ksp-swift-cli pull` is the
  command that does it now; the bare driver below is what the figures were measured through, and it
  needs `KSPKit` linked because it drives `BulkRead.readRaw` rather than replaying frames:

  ```sh
  (cd swift && swift build --target KSPKit)
  swiftc -O -I swift/.build/debug/Modules tools/coremidi_read.swift \
      swift/.build/debug/KSPKit.build/*.o -o /tmp/coremidi_read
  /tmp/coremidi_read 1 /tmp/slot1.KeyStepPro src/ksp_cli/templates/Default.KeyStepPro
  ```

  Slot 1 read in **4.80 s — 153,497 keys, 1,007 requests, 13 sentinels repaired**, twice over and
  byte-identical both times ([spec 7.9.2](./format/SysEx_Direct_Transfer_Path.md)). That was the
  pre-#255 walk, and the project it wrote was wrong in 114 keys; the corrected walk is 2,474
  requests and has not been re-run here.

**What is still untested: MCC mid-transfer, and H3.2's diff over this transport.** MCC was running
but idle; driving a Recall From while the probe reads needs a hand on the GUI. And the project read
above has not been byte-diffed against MCC's own export of the same slot — the same Recall From is
what that would take.

---

## Capture ledger

Fill in as you go. This table is the record; the `.KeyStepPro` files are the evidence.

Rows for the completed tiers have been removed along with their procedures. The values those
captures owed were collected in a separate gaps ledger, which is now **closed** — every row was
answered and folded into the spec on 2026-08-01. **Tier 7's rows went the same way on 2026-08-05,
and tier 8's on 2026-08-06**; the findings are in [the spec](./format/Time_Shift_And_Swing.md), and
tier 8's six recordings stay reduced in
[`Timing_Calibration.md`](./Timing_Calibration.md) §6.1 because that is where the arithmetic lives.

The table is empty because every tier is closed — **H2.1–H2.4 and H4.1 all ran and confirmed on
2026-08-14**, closing the last open probes. Add a row when a new question sends someone back to
the device.

## Effort summary

**H2.1–H2.4 and H4.1 all ran 2026-08-14 and confirmed.** B0, tiers 1–8, the two write tiers,
Phase 1 and Phase 2 are all complete — roughly 59 captures and 6 recordings, and every question
they were opened to answer has been answered and folded into
[the spec](./KeyStepPro_Format_Spec.md).

H4.1 reopened the programme on 2026-08-06, not because a tier missed something but because two new
USB captures decoded a byte that had been carried as a constant. It is a single scalar read and it
needs no `.KeyStepPro` export, so it does not belong to a tier.

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
