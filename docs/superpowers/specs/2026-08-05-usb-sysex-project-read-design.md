# Reading a project off the KeyStep Pro over USB SysEx

Design, 2026-08-05.

## Context

`ksp2midi` converts a `.KeyStepPro` file to MIDI, but getting that file requires MIDI Control
Center: connect, Recall To, export. The device itself is never asked directly. Spec §7 recorded a
direct-to-hardware path as "structurally feasible" but blocked, because "the binary's strings do
not reveal the byte-level command layout beyond the envelope, so this would need live frame
capture to reverse."

That capture now exists, and the blocker is gone. `usb_midi_investigation/recall_sysex.jsonl` is a
26,856-frame Wireshark capture of MCC performing Recall To against the device. Decoding it settled
the protocol outright, and the read plan turned out not to need reversing at all — Arturia declares
it.

The goal of this milestone is narrow: **read a project off the hardware and write a
`.KeyStepPro` file**, so the existing converter can take it from there.

## What the capture established

### The wire protocol

Read request:

```
F0 00 20 6B 7F 42 0B 01 <paramId> <nIdx> <itemId> <idx1..idxN> <count> F7
```

`nIdx` is 1, 2 or 3 and is the number of index dimensions. Reply is command `0x0C`, echoing
request bytes 8..(11+nIdx) verbatim — including the count byte — then exactly `<count>` data
bytes, then `F7`. The device then sends `F0 00 20 6B 7F 42 1C 00 F7` as an ack. There is a short
form for the index-less parameters:

```
F0 00 20 6B 7F 42 01 01 <paramId> <itemId> F7      -> reply 0x02
```

The address tuple is exactly the project-file key `<itemId>_<paramId>_i1_i2_i3`. `nIdx` matches the
underscore count in the file keys with no exceptions: 40 keys carry no index, 1,567 carry one,
7,248 two, 144,640 three.

Verified across all 8,911 long reads in the capture: reply length equals `<count>` every time, and
the header echo is byte-identical every time. Across all 8,951 transactions (8,911 long plus 40
short) the ack payload is `1C 00` every time and never an error code.

### The wire is 7-bit, with one exception that is not a value

Every data byte in every reply is `0x00..0x7F` except 13 bytes, all `0xFF`, all on
`123_117_<pattern>` for patterns 1–13. There is no escape scheme, no high-bit packing, no bias:
one value is one byte.

`0xFF` is System Reset, a real-time status byte no conformant host MIDI parser passes through
inside a SysEx. MCC's receive buffer loses the data byte, MCC reads the `0xF7` terminator sitting
at that offset, and writes **247** into the file. This is why 247 is the only number above 127 in
any project file in the corpus.

This closes the open question at `analysis/KeyStepPro_Format_Spec.md:303`, which says 247 is
"something MCC writes and the firmware does not keep." The firmware does keep something. It keeps
`0xFF`, meaning *pattern default pitch unset*; `60` means initialised. 247 is host-side corruption
and a writer must never emit it.

Evidence: `recall_sysex.jsonl` frame 5745 (`... 75 01 7b 01 01 ff f7`), and independently
`ksp_handshake_replay_log.txt` line 3846, which shows the raw USB-MIDI packet `07 01 ff f7` —
CIN `0x7`, "SysEx ends with three bytes". Not a sniffer artifact.

### The read plan is declared, not reverse-engineered

`bulkOperation` in `/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json` generates
MCC's exact 8,951-request stream, byte-for-byte and in order, by walking each leaf as
item → param → index-set combinations.

The project file stores a dense `[16][3 or 4][64]` rectangle per parameter, but `bulkOperation`
addresses only the logical extent:

| params | logical extent | addressed as |
|---|---|---|
| `48`, `49` (all tracks) | 64 steps | i2 fixed at 1, i3 1–64 |
| `50`, `109`–`113` | 192 note pool | i2 ∈ {1,2,3}, i3 1–64 |
| `53`, `54`, `117`–`121` (drum) | 192 | i2 ∈ {1,2,3}, i3 1–64 |
| `51` drum lane step count | 24 lanes | i2=1, i3 1–24 |
| `52` drum step-active | 240 (24 lanes × 10 parts) | i2 1–4, i3 stops at 48 in chunk 4 |

The 35,712 unaddressed keys hold literal `0` in all six corpus files. **Zero-fill them; do not
request them.** Fetching them would cost 693 extra requests to retrieve 35,712 zeros.

Two vendor confirmations fall out of the `desc` strings: `52`'s packing is labelled "DRUM 1 part 1
to 10, DRUM 2 part 1 to 6" and so on, which is spec §4's `flat = lane*10 + step//7` stated by
Arturia; and `48`/`49`'s middle index is the literal `[1]`, which is the vendor's own reason for
spec §4's "take `48` from slot 1 and treat it as pattern-wide". The spec does not currently say
this also holds for `49`. It does.

Do **not** use the `desc` strings as index documentation — the four note-pool chunk leaves all read
"note 129 -> 144" style text, chunk-3 numbering copy-pasted across all three chunks with an
off-by-one on the last. The `bulkItemId` templates are correct; the prose is not.

### Round trip is exact

Applying the plan to the capture, with `0xFF → 247`, the three MCC-side constants below, and
zero-fill, reconstructs **153,495 / 153,495 numeric values** of
`project_files/initial_project.KeyStepPro`. Adding `device` (constant) and `version` gives 153,497
keys — a complete round trip.

`120_55_5`, `120_56_4` and `120_56_5` read back `0` from hardware but are `127` in all six corpus
files including the factory `Default.KeyStepPro`, which never came off a device. They are MCC-side
constants and must be hard-coded, not taken from the wire.

`"version": "2.5.20"` comes from the universal identity reply's trailing bytes
(`0x02`.`0x05`.`0x14`). Nothing in the read protocol supplies it, so the identity request is
required for a byte-identical file.

### Transport and pacing

The device exposes two USB interfaces and CoreMIDI only surfaces one; SysEx reads issued through
mido have never drawn a reply. Raw USB on interface 2 is the only path that answers. This is a
constraint on the design, not a preference.

Traffic is strictly serialized — request, reply, ack, next request, never pipelined. Median
request period is 4.047 ms and is **identical for count=1 and count=16**, so throughput is
per-request, not per-byte. Maximum observed `count` is 16; whether that is a device limit or an MCC
convention is untested. A full project reads in ~36 s measured. There is no epilogue, no close, no
keepalive and no retransmit anywhere in the capture.

## Architecture

CLAUDE.md's one-way dependency holds, and the M8–M9 Swift port means the protocol must stay a
translation of pure functions. So the **protocol is pure and the transport is injected**.

| Module | Contents |
|---|---|
| `src/ksp/sysex.py` | `build_read_request(item, param, idxs, count) -> bytes`, `parse_reply(bytes) -> (addr, values)`, envelope constants. No I/O |
| `src/ksp/bulk_plan.py` | Generated table of `(itemId, paramId, extents, count)` and `iter_requests()`. Pure data |
| `src/ksp/bulk_read.py` | Walks the plan against an injected `Transport` protocol, assembles the flat dict, applies corrections, zero-fill, `device` and `version`. No pyusb import |
| `src/ksp_cli/usb_transport.py` | pyusb: interface 2, kernel detach, libusb discovery, USB-MIDI 4-byte CIN framing |
| `src/ksp_cli/pull.py` | `ksp-pull` entry point |
| `scripts/gen_bulk_plan.py` | One-off generator from the vendor JSON |

`bulk_read` emits a flat `dict[str, int | str]` and hands it to the existing
`ksp.reader.read_project()` at `src/ksp/reader.py:58`. Nothing downstream changes —
`lenient_json.load_path()` is simply one producer of that dict and the hardware reader is a second.
The pyusb import never enters `ksp/`, so the Swift port swaps in CoreMIDI and reuses the codec
unchanged.

Per CLAUDE.md, the `ksp-pull` console entry point goes into `pyproject.toml` only when the
milestone lands.

### The read plan is generated into the repo

`scripts/gen_bulk_plan.py` reads the vendor JSON once and emits a compact table into
`src/ksp/bulk_plan.py`, which is checked in. The repo ships facts rather than Arturia's file, the
tool works on machines with no MCC installed, and the generator stays available to re-derive on a
firmware update. This mirrors how `GATE_TABLE` is already held.

The vendor JSON needs last-wins parsing — one object carries duplicate `desc` keys, the same
not-quite-JSON family as the project files themselves.

A test asserts the generated table reproduces the captured request stream, so a regeneration that
changes behaviour fails loudly.

### Testing without hardware

A `ReplayTransport` answers requests out of a captured exchange, making the entire read path
testable in CI with no device attached.

**The fixture must be a tracked file.** `usb_midi_investigation/recall_sysex.jsonl` is gitignored
at `.gitignore:45`, so a test bound to it would skip silently on any other checkout and inside every
worktree. `usb_midi_investigation/sysex_until_project_1_track_1_pattern_1.jsonl` is tracked and is
the fixture of record; if full-project coverage is wanted in CI, a distilled subset gets committed
alongside it.

The test asserts reconstruction against `project_files/initial_project.KeyStepPro` over the keys the
fixture covers. Green CI still does not mean verified on hardware.

## Project selection — settled on hardware 2026-08-14

Nothing in the address tuple identifies a project slot; the select command is the `05 <slot>`
prologue, one frame outside the address tuple. H4.1 confirmed it on hardware, firmware 2.5.20: a
sweep of byte 7 = 1..16, each preceded by its own `05 <slot>`, read back a distinct, correct
project for every one of the sixteen slots. Dumping project N needs no panel work — `05 <slot>`
selects it. See [spec 7.4](../../../analysis/format/SysEx_Direct_Transfer_Path.md) and H4.1 in
[the hardware test protocol](../../../analysis/Hardware_Test_Protocol.md).

## Task ladder

Phase 0 needs no device. Phases 1–4 are one command each at the hardware, sized at 4–5 minutes.

### Phase 0 — no hardware

- **T0.1** Generate `bulk_plan.py` from the vendor JSON. Assert it reproduces all 8,951 captured
  requests in exact order.
- **T0.2** Write the codec and `ReplayTransport`. Assert exact reconstruction over the tracked
  fixture's key coverage.

### Phase 1 — one command each

- **H1.1** Identity request only. Confirm the reply's trailing bytes decode to `2.5.20`.
- **H1.2** Single scalar read `120_37`. Confirms the whole stack end to end on one byte.
- **H1.3** Throughput probe: ask `124_109_1_1_1` with `count=64` instead of 16. If the device
  honours it, full dumps drop from ~36 s to ~10 s.
- **H1.4** Prologue minimisation: re-run without the `0x05` frame, then without identity. Settles
  what is actually required.
- **H1.5** Read `123_117_1..16`. Confirms the `0xFF` sentinel live and shows which patterns are
  initialised.

### Phase 2 — correctness against visible ground truth ✅ **done, hardware 2026-08-14**

- **H2.1** Build the scratch project by hand: Track 1 Seq, Pattern 1, 16 steps, notes on steps
  1/5/9/13, ascending pitches, one deliberately long gate. The device has 16 freely-chosen slots,
  so a scratch slot costs nothing.
- **H2.2** Read `123_50` and `123_109` chunk 1. Assert ordinals and pitches match the panel.
  **PASS** — 4 notes, ordinals 1–4 on steps 1/5/9/13, pitches 60/62/64/65, gates 7/7/7/31.
- **H2.3** Read `123_48`. Assert active bits land on steps 1/5/9/13 and nowhere else. **PASS.**
- **H2.4** Single-pattern read through `read_project` to a MIDI export. Listen to it. **PASS,
  measured: 115 requests in 440 ms** for the coalesced walk
  (`ksp.bulk_fast.iter_pattern_requests`); MCC's own plan takes 250 for the same keys. The
  exported MIDI matched the panel exactly, including the fourth note's 480-tick gate against the
  other three's 60 ticks.

**H4.1 rode along in the same run and was answered here, not in Phase 4.**
`tools/usb_probe.py phase2` ran H2.2, H2.3, H2.4 and H4.1 in one invocation over one open
transport, since the transport was already open and the extra reads cost nothing. It confirmed
that the `05 <slot>` prologue selects the project — see the project-selection section above.

### Phase 3 — acceptance

- **H3.1** Full dump, ~36 s, written to `.KeyStepPro`.
- **H3.2** Recall the same project in MCC, export, and byte-diff against H3.1. This is the
  milestone gate.

### Phase 4 — the unlock ✅ **answered inside Phase 2, hardware 2026-08-14**

- **H4.1** Switch projects on the device and re-read `120_37`. Does the value follow the panel?
  Answered by the sixteen-slot sweep in the `phase2` run, not by switching projects on the panel:
  `05 <slot>` selects, and multi-project dumping needs no capture beyond that frame — see
  "Project selection" above.

## Documentation corrections this work carries

- `analysis/KeyStepPro_Format_Spec.md:303` — the `123_117_<pat>` row: `0xFF` is the device's
  "unset" sentinel and 247 is MCC's corruption of it. The row also says `initial_project` holds 247
  "at pattern 1 only"; it is patterns 1–13, with `project_9` at 3 and `project_5` at 1.
- `analysis/KeyStepPro_Format_Spec.md:117` — the line-format note gives the value range as 0–247.
  Values are 0–127 everywhere, with the single 247 artifact above.
- `analysis/KeyStepPro_Format_Spec.md` §7 — replace "would need live frame capture to reverse" with
  the decoded protocol, and record that the read plan is vendor-declared.
- `analysis/KeyStepPro_Format_Spec.md` §4 — the slot-1-only rule for `48` is vendor-declared, and
  also holds for `49`.
- The early USB investigation note described frame 13 as "a wait or flush signal". It is the first
  real read in the plan: `paramId 37, itemId 120`, and its reply carries that key's actual value.
  (That note has since been retired; its findings are folded into this document and the protocol.)

## Out of scope

Writing to the device. The capture is read-only and proves nothing about the write path. A write
command counterpart to `0x0B` is visible in the protocol shape but untested, and the one value that
cannot be transmitted at all (`0xFF`) sits on a parameter a writer would want to set. That is its
own milestone.
