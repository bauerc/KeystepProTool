# The SysEx direct-transfer path

**Spec section:** §7 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The `arturia_v2` SysEx bulk stream and the decoded read protocol. Not needed for file conversion.

---

## 7. Direct-to-hardware over SysEx

**Not needed for file conversion**, but no longer speculative: the read half of the protocol is
decoded and implemented in `ksp.sysex`, `ksp.bulk_plan` and `ksp.bulk_read`.

MCC's `arturia_v2` protocol pushes projects as an ack-per-chunk SysEx bulk stream inside an
`F0 00 20 6B … F7` envelope. A canned frame in the binary reads:

```
f0 00 20 6b 7f 42 02 00 40 6a 31 f7
         ^^ ^^    ^^ ^^^^^
         |  |     |  familyId 0200
         |  |     productId 42 (KeyStep Pro)
         manufacturerId 00 20 6B
```

The bulk stream is addressed by the tuple `(bulkItemId…, paramId, valueId/index)` — **the same
address tuple the file keys encode**, which is why `bulkOperation` in the device JSON describes
both transports. A CoreMIDI direct-transfer path is not merely feasible but measured: see
[7.9](#79-the-transport-coremidi-answers-and-raw-usb-is-not-required).

### 7.1 The read protocol

Decoded from a 26,856-frame capture of MCC performing **Recall To** over USB. Four frame types,
all inside the envelope above:

```
long   request  F0 00 20 6B 7F 42 0B <slot> <param> <nIdx> <item> <idx1..idxN> <count> F7
long   reply    F0 00 20 6B 7F 42 0C <slot> <param> <nIdx> <item> <idx1..idxN> <count> <count bytes> F7
short  request  F0 00 20 6B 7F 42 01 <slot> <param> <item> F7
short  reply    F0 00 20 6B 7F 42 02 <slot> <param> <item> <one byte> F7
ack             F0 00 20 6B 7F 42 1C 00    F7
```

`<slot>` is the project number — see [7.4](#74-the-05-slot-prologue-selects-the-project), which is
also where the `05` frame that *selects* it lives. The ack is the only frame that does not carry
it; its `00` is a constant, not a slot.

The reply **echoes the request address verbatim**, which is what makes a desynchronised stream
detectable rather than silently misfiled. The count byte is echoed as *honoured*, not as asked —
it differs from the request whenever the request exceeded 100, so desync is a comparison of the
address and the count is the device's answer rather than a copy of the question. See
[7.7](#77-request-limits-measured-at-the-device). A long read walks its *last* index forward by
`count`; the other indices are fixed. Traffic is strictly serialised — request, reply, ack — so
one outstanding request at a time is the whole flow control.

Values are 7-bit. The single exception is the device's unset sentinel `0xFF`, which is a MIDI
System Reset byte; see the `123_117_<pat>` row in
[per-pattern scalars](./Parameters_Pattern_Scalars.md) for what happens to it in transit.

### 7.2 The read plan is vendor-declared, not reverse-engineered

Which addresses MCC asks for, and in what order, is **declared by Arturia** in the `bulkOperation`
array of the device JSON (see [reproducing findings](./Reproducing_Findings_And_Index_Shapes.md)).
Walking that descriptor generates MCC's request stream **byte-identically and in order — all
8,951 requests**. `tools/gen_bulk_plan.py` transcribes it into `src/ksp/bulk_plan.py` and
`tests/test_bulk_plan.py` holds the result against the captured stream, so this is transcription
rather than discovery.

The plan addresses the **logical extent only**: 117,783 of the file's 153,495 numeric keys. The
remaining 35,712 are the unaddressed corners of the dense rectangle and hold literal `0` in every
corpus file, so `ksp.bulk_read` zero-fills them instead of spending 693 requests retrieving zeros.

### 7.3 What is verified, and what is not

Replaying the capture through `ksp.bulk_read` reconstructs **all 153,497 keys of
`initial_project.KeyStepPro`, byte-identical to MCC's export** minus the trailing comma this
writer omits — so the hardware is a second producer of the same flat dict `ksp.reader` already
consumes, and nothing downstream changes.

**The read path matches the panel.** A single pattern read off the device — the 115-request walk
of 7.8, through `bulk_read` and `ksp.reader` to a MIDI export — reproduced a hand-built pattern
exactly: notes on the steps the panel showed, at its pitches, and a deliberately long gate coming
out eight times the length of the others. The note pool, the step-active array and the pool's
existence markers each decode to what the panel displays. 2026-08-14, firmware 2.5.20.

**The full 8,951-request walk has not been run against hardware**, and no dump has been
byte-diffed against an MCC export of the same project. That is the outstanding acceptance gate.

Project selection is settled on hardware (7.4). The **write direction is capture-only** — nothing
in 7.5 or 7.6 has been sent to a device by this project.

(`libusb` in `/Library/Arturia/Shared/` is used only for DFU firmware updates — not for projects.)

### 7.4 The `05 <slot>` prologue selects the project

`05 <slot>` is what tells the device which project to serve. Byte 7 of every frame carries the
same slot number but does not itself select: send one prologue and then vary byte 7, and every
request answers from the prologue's project — the others return the `0x7f` filler. **Switching
project means sending `05 <slot>` again.** `ksp.bulk_read.read_raw` sends it.

Slots are **1-based and match the panel**: `05 02` serves the panel's Project 2. All sixteen read
this way, and the panel need not be touched. A read returns the slot **as stored** — edits made on
the panel and not saved do not appear in it.

`120_37` reads `3` in all sixteen slots, so no project-level scalar identifies which project was
served. Only per-note data does.

No handshake is required to re-read whatever project is *already* loaded — neither the identity
request nor a prologue. Selecting a different one is the prologue's whole job.

Confirmed on hardware 2026-08-14, firmware 2.5.20.

Byte 7 was carried as an untested constant `01` for as long as every capture came from project 1.
Four captures disagree about it, and they disagree exactly where the project changes:

| Capture | Operation | Byte 7 |
|---|---|---|
| `sysex_until_project_1_track_1_pattern_1.jsonl` | partial read, project 1 | `01` |
| `recall_sysex.jsonl` | full Recall To, project 1 | `01` |
| `recall_project_2.jsonl` | full Recall To, project 2 | `02` |
| `import_to_project_3.jsonl` | full write, project 3 | `03` |

It rides in every command — `01`, `02`, `05`, `06`, `0B`, `0C` — and is constant for the whole of
a transfer. Only the ack is exempt.

Each capture also contains exactly one `05`/`06` frame, naming that same project: `05 01` before
the project 1 recall, `05 02` before the project 2 recall, `06 03` closing the project 3 import.
Byte 7 and the prologue are in lockstep for the whole of every capture, which is why the tapes
alone cannot say which of the two selects, and why this section once read it as byte 7 alone.

Two further capture facts, both from gapless recordings — frame numbers step by exactly two from
frame 7 with no holes, so nothing was dropped in extraction. The import's 8,951 outbound writes
are byte-identical to the recall's 8,951 inbound replies once byte 7 is masked, 8,950 of 8,951,
the exception being the sentinel frame in 7.6. And the project 1 and project 2 recalls send an
identical request stream but differ on **971 of 8,951 addresses**, so the two reads were never
both returning one loaded project.

`tests/test_capture_evidence.py` holds the tape claims above.

### 7.5 The write direction

A write is the read protocol with the **reply opcodes sent as requests**:

```
long   write  F0 00 20 6B 7F 42 0C <slot> <param> <nIdx> <item> <idx1..idxN> <count> <count bytes> F7
short  write  F0 00 20 6B 7F 42 02 <slot> <param> <item> <one byte> F7
ack           F0 00 20 6B 7F 42 1C 00    F7
```

**Hardware-confirmed 2026-08-19, firmware 2.5.20.**

Session framing rules for writes:

- **Do NOT send `05 <slot>` before writing.** `05` selects project `<slot>` for *reading*. Sending `05` before write frames places the device into read-request mode, causing write frames to be ignored.
- **Do NOT pause for per-frame inline ACKs.** Standalone write frames sent synchronously stall waiting for ACKs. Write frames must be streamed unbuffered in a continuous USB endpoint transfer burst.
- **`06 <slot>` is the mandatory commit epilogue.** The hardware updates RAM and panel state only when the burst ends with `F0 00 20 6B 7F 42 06 <slot> F7`. The device responds with a single ACK (`1C 00`) for the burst.
- **Targeted partial writes work.** Pushing a full 8,951-frame dump is not required; sending only modified parameters (preceded by item 120 initialization and ended by `06 <slot>`) commits directly to the hardware slot in < 1 ms.
- **Display Pitch Convention:** Displayed pitch C3 corresponds to MIDI note 60 (`0x3C`). MIDI note 48 (`0x30`) displays as C2.


### 7.6 `0xFF` survives a read and does not survive a write

H1.5 confirmed on hardware that the `0xFF` unset sentinel reaches a raw-USB reader intact. The
write direction is the other half of that story, and it does not.

The corpus has exactly one address holding the sentinel, `123_117_1`. In the two captures:

```
read reply   f000206b7f42 0c 02 75 01 7b 01 01 ff f7     count 1, value 0xFF
write sent   f000206b7f42 0c 03 75 01 7b 01 01    f7     count 1, value gone
```

The count byte still promises one value and no value follows, so the frame is malformed by the
protocol's own rule. **The device did not ack it** — the only unacked message in either capture —
and MCC recovered by sending a fresh Identity Request before carrying on, the only mid-stream
identity exchange in either capture.

That missing ack is what makes this a finding rather than a capture artefact: a host-side filter
eating the byte after transmission could not have stalled the device.

The practical consequence for a device writer: **a value read as `0xFF` cannot be echoed back**.
Re-emitting it verbatim stalls the link. A file writer's rule is unchanged and opposite — it must
keep emitting `247`, MCC's in-transit corruption of the same byte; see the `123_117_<pat>` row in
[per-pattern scalars](./Parameters_Pattern_Scalars.md). What a device writer *should* send instead
is unknown; the capture shows only what MCC failed to send.

### 7.7 Request limits, measured at the device

MCC never sends a `count` above 16 and its longest reply in any capture is 32 bytes, so every
limit below is outside what the captures could show. H1.6 pushed each field until the device
objected:

| Request | What the device does |
| ------- | -------------------- |
| `count` ≤ 100 | honoured exactly |
| `count` > 100 | **clamped to 100**, and the reply echoes `0x64` |
| `count` = 0 | well-formed reply, zero data bytes |
| a byte appended after `count` | ignored; the count is one 7-bit byte and there is no wide form |
| start index `0` | answers `0x00` filler — indices are **1-based**, and starting at 0 wastes a slot |
| start + `count` past the item's extent | **full count returned**, padded — no error, no short reply |
| `nIdx` = 4 | **no reply and no ack**; only 1, 2 and 3 are accepted |

The clamp is a transfer-buffer size, not an end-of-extent clamp: a request starting at index 65
and asking for 127 clamped to 100 exactly as one starting at index 1 did. So 100 values may be
read from any address.

**An overrun is safe to send and unsafe to store.** Asking past an item's extent is not an error,
but the padding is the item's own unset value — `0x7f` for the 64-step `7b` items, `0x00` for the
`nIdx=2` items — which is precisely what a real unset entry reads as. Nothing in the reply
distinguishes the two. `bulk_read` must therefore clip every reply to the extent the plan
declares, and must never infer an extent from reply length or from where sentinel values start:
reply length is always `min(count, 100)` whatever the address.

There is also no error frame in the protocol. A malformed request produces silence, so a reader
detects one only by timing out.

None of this is a speedup on its own. The 64-step items are already covered by a single
`count=64`, so the headroom above 64 only helps items whose extent exceeds it — the 240-entry
parameters that H1.3's note singles out as the ones that do not divide evenly. What a raised count
does to the full-dump time has not been measured, and H1.3's 9.6 s stands as the only figure.

### 7.8 The same addresses in a ninth of the requests

MCC's stream is what `bulk_plan` reproduces and what the tapes pin down, so it stays. `ksp.bulk_fast`
derives a second walk from the identical `PLAN`: same 117,783 addresses, different frames. Two
things account for the whole saving.

> **The coalescing below is measured against the tapes, not the device, and hardware has since
> refuted part of it — see [#255](https://github.com/bauerc/KeystepProTool/issues/255).** A
> per-pattern scalar coalesced into a 16-entry range comes back as index 1's value repeated, so
> `nIdx=1` runs must not be coalesced. The gate and the `nIdx=3` runs are unaffected.

**Coalescing.** Every contiguous run over the walking index becomes one request. All 2,004 runs in
the plan are contiguous and none exceeds 64 values, so **8,911 long reads become 2,004** — the
extent binds long before the 100 of 7.7 does. Two details only a plan-wide view catches: MCC's
per-pattern scalars each walk the *group* index, so sixteen `count=1` reads of `122_90` are one
16-entry range; and `121_83` is read scene 5 first, so a run is a range whatever order it arrived
in.

**The melodic gate.** `50` and `109`–`113` share a note ordinal, so a 64-entry chunk of `50` that is
all `127` settles all five per-note parameters at once. Both tapes agree without exception —
59,415 and 61,120 such values, every one `127`. And notes reach a chunk only once the chunk before
it is full, so a sentinel in chunk 1 proves chunks 2 and 3 empty and `50` need not be read for them
either. `bulk_fast` emits the existence array ahead of the parameters it gates; MCC's leaf order
puts it after.

| walk | project 1 | project 2 |
| ---- | --------- | --------- |
| `bulk_plan`, MCC's stream | 8,951 | 8,951 |
| `bulk_fast`, coalesced | 2,044 | 2,044 |
| `bulk_fast` + the gate | **1,007** | **976** |

> **The drum pool is not gateable, and assuming otherwise destroys bytes.** Where `54` is `127`,
> `117`–`121` are `127` in some patterns and the default row `60/7/100/49/100` in others *within one
> project*: 10,420 against 2,880 on project 1, and 960 against 14,400 on project 2. A drum entry is
> a hole that keeps what was there, not an empty one — see
> [the note pool](./Note_Pool_Sentinels_And_Capacity.md). Nothing derives those values; they are
> fetched.

Both figures above are counted against the tapes, not the device. `tests/test_bulk_fast.py` answers
both walks out of one model of the tape's values and requires the resulting projects to be equal,
which is what makes the saving checkable without hardware. **No timing here is measured**: H1.3's
9.6 s remains the only figure taken off the device, and what the gate does to wall-clock is
untested.

`ksp-pull` (`src/ksp_cli/pull.py`) is the command that drives this walk: it reads the coalesced
`bulk_fast` plan by default and takes `--mcc-plan` to walk the generated one instead. Replayed
against `recall_tape.txt` it writes a file byte-identical to MCC's own export of the same
project — but for the trailing comma MCC appends and this writer's strict JSON omits, same as 7.3
above (`tests/test_pull_cli.py::test_the_dump_is_byte_identical_to_mcc_s_export`). That is the
tapes again, not the device; H3.1 and H3.2 in the [hardware test
protocol](../Hardware_Test_Protocol.md#phase-3--acceptance) are what carry this check to hardware.

### 7.9 The transport: CoreMIDI answers, and raw USB is not required

**The device answers the whole read protocol over its ordinary CoreMIDI endpoint, with no root, no
interface claim and no privileged helper.** Measured on hardware 2026-09-03, firmware 2.5.20,
macOS 26.6.2, Swift 6.2.3, through `tools/coremidi_probe.swift`.

**Why it was open.** `ksp_cli.usb_transport` claims USB interface 2, and it is **the claim** that
needs root: macOS reports its class driver as active but refuses to detach it, and the claim
succeeds anyway against an unreleased driver — which is what `ksp-pull` spends its `sudo` on
(`src/ksp_cli/usb_transport.py`, and the `TransportError` it raises says so). A GUI app cannot
prompt for a password and re-exec itself as root, so if the protocol were reachable only that way,
the app would need an `SMJobBless` helper or an XPC service.

**The driver being detached is CoreMIDI's own.** While any MIDI client is connected,
`IOUSBHostInterface` with `bInterfaceNumber = 2` carries exactly one interface-level user client,
and it is `MIDIServer` — CoreMIDI's server process:

```sh
ioreg -r -c IOUSBHostInterface -l -w0 | awk '/KeyStep Pro/,0' |
    grep -E 'bInterfaceNumber|IOUserClientCreator'
```

That single interface is published as a single CoreMIDI endpoint pair named `KeyStep Pro`; the
device offers no second port. So the raw path and the CoreMIDI path are **the same wire**, and
claiming interface 2 is evicting CoreMIDI from it rather than reaching past it. Talking *through*
`MIDIServer` reaches the identical endpoint cooperatively.

`MIDIServer` is launch-on-demand: with no client connected it exits and the user client disappears,
so the `ioreg` line above shows interface 2 unowned. Run it while something holds a MIDI client
open, or it reads as though nothing binds the interface.

Sent to that endpoint, every frame type answers unchanged — reply then ack, exactly as 7.1
describes:

| Request | Reply |
| ------- | ----- |
| `f07e7f0601f7` identity | `f07e7f060200206b0200090025140502f7` → **2.5.20** |
| `01 01 25 78` short read `120_37` | `02 01 25 78 03` — the value `3` of 7.4, not the `0x7f` filler |
| `0b 01 6d 03 7c 01 01 01 10` long read, count 16 | all 16 values |
| `0b 01 6d 03 7c 01 01 01 64` long read, count 100 | all 100 values, a 116-byte frame |

**The prologue selects over CoreMIDI too.** `05 <slot>` then `120_37` answers for all sixteen
slots, byte 7 echoing the slot each time; `120_37` reads `3` throughout, as 7.4 says it must, while
the pitch chunk `124_109_1_1_1` differs per slot — `24 28 2b 24` in slot 1, `3c 3e 40 3c` in slots
4–6, `3c 48 4c 48` in slot 7, filler in the empty ones. Different projects, so the selection is
real and not an echo.

**Cost: 4.00 ms per exchange, and it does not vary with payload.** 200 request/reply/ack rounds at
each of count 1, 16, 64 and 100 returned 200 replies and 200 acks apiece, no drops, at 4.00 ms
throughout. A one-value reply costs what a hundred-value reply costs, so the cadence is
per-transaction rather than per-byte, and the whole benefit of coalescing (7.8) survives it,
because coalescing removes transactions rather than bytes.

**That is the same figure the raw path gives, so the transport costs nothing.** H1.3 measured
interface 2 directly at **3.994 ms at `count=16` and 3.998 ms at `count=64`** — flat, and within
noise of the 4.00 ms here. The 4 ms is therefore **the device's own transaction rate**, not an
overhead the class driver adds: going through `MIDIServer` rather than around it is free.

**The coalesced walk has been run, not just projected.** Replaying `ksp.bulk_fast`'s own 2,044
frames — 1,776 of them at `count=64` — over CoreMIDI, against slot 1:

```
answered 2044/2044   acks 2044   mismatched 0
values   117,767 of the plan's 117,783
elapsed  8.20 s -- 4.01 ms per request
```

Every request was answered, every reply echoed the address it was asked for, and the measured 8.20 s
lands on the 8.2 s the per-exchange cost predicts.

| Walk | Requests | At 4.00 ms |
| ---- | -------- | ---------- |
| `bulk_plan`, MCC's stream, `count` as MCC sends it | 8,951 | ≈ 36 s |
| `bulk_fast`, coalesced | 2,044 | **8.20 s, measured** |
| `bulk_fast` + the gate | 1,007 | ≈ 4.0 s |

H1.3's own dump figures corroborate the column: 38.3 s for the walk at MCC's count against ≈ 36 s
projected, and 9.6 s once the count byte alone is raised — the latter is a coalesced walk of
roughly 2,400 requests, **not** MCC's 8,951, so it belongs beside the 8.20 s row rather than being
divided by 8,951. The two transports agree per request, and the entire saving in the table is the
gate's, never the wire's.

### 7.9.1 CoreMIDI truncates a reply at the first `0xFF`

**This is the one thing the CoreMIDI path does not carry, and a transport that ignores it silently
loses data.** `0xFF` is MIDI System Reset, and it is also the device's unset sentinel (7.6). Sent
inside a reply it never reaches the client: CoreMIDI cuts the frame at that byte and delivers the
terminator, so the reply arrives well-formed, echoing the address and the *honoured* count, while
carrying fewer values than that count promises — or none at all.

It is a truncation, not a per-byte strip. Reading `123_117_<pattern>`, where patterns 1–13 hold the
sentinel and 14–16 hold 60 (H1.5):

| Request | Values back |
| ------- | ----------- |
| start 1, `count=16` (what `bulk_fast` issues) | **0** — the whole range lost to the sentinel at index 1 |
| start 13, `count=4` | **0** — a strip would have returned the three at 14–16 |
| start 14, `count=3` | 3 |
| start `<n>`, `count=1`, n ≤ 13 | **0** |
| start `<n>`, `count=1`, n ≥ 14 | 1 |

That single `123_117` range is the whole of the walk's shortfall above: 16 values, one request, and
`ksp.sysex.parse_reply` rejects it correctly — "reply carried 0 values, header promised 16".

**Recovering it is exact and nearly free.** A reply short by its first `k` values means index
`start + k` holds `0xFF`; re-request from `start + k + 1` and repeat. `count=1` makes the position
unambiguous, so the fallback is: on a short reply, take the values that arrived, record `0xFF` for
the next index, and re-read the remainder. Only `123_117` carries the sentinel in any corpus file,
so the worst case is sixteen extra round trips — under 70 ms against an 8.2 s walk.

Verified as CoreMIDI's doing rather than the probe's: the same three requests, re-run with the
probe's real-time filter compiled out entirely, return byte-identical truncated frames.

### 7.9.2 A whole project, read over CoreMIDI

Not a frame count and not a projection — the file. The transport is `KSPDevice` (#246), a
`KSPKit.Transport` over CoreMIDI carrying the 7.9.1 repair, handed straight to `BulkRead.readRaw`
and `LenientJSON.write`; no format logic of its own, so what it exercises is the transport.
`ksp-swift-cli pull` (#247) is the command that reads a project with it;
`tools/coremidi_read.swift` is the bare driver the figures below were measured through.

```
slot 1: 153497 keys, 1007 requests, 13 sentinels repaired, 4.80 s
```

- **153,497 keys** — the whole project, the same count 7.3 reconstructs from the capture.
- **1,007 requests** — the gated `bulk_fast` walk, matching the table in 7.8 exactly.
- **13 sentinels repaired** — `123_117`, patterns 1–13, each recovered by the re-read of 7.9.1.
- **4.80 s**, against the ≈ 4.0 s the per-exchange cost predicts.

**Re-measured through `KSPDevice` itself** (2026-09-04, same slot, same firmware): 153,497 keys,
**1,021 exchanges**, 13 sentinels repaired, **4.49 s**, and two consecutive reads byte-identical at
3,523,191 bytes. The exchange count is the same walk seen one layer lower — the gate's 1,007
requests, plus the 13 sentinel re-reads, plus the one identity request that decides the device is
answering — so it corroborates the 1,007 above rather than disagreeing with it.

**The sentinels land where raw USB says they must.** `123_117_1` through `123_117_13` are written as
`247`, and 14–16 as `60` — which is H1.5's raw-USB reading (255 raw, 247 in a file) reproduced
through a transport that cannot carry the byte. That is the sharpest evidence here that the repair
restores the value rather than merely filling a hole.

**Two consecutive reads of the same slot are byte-identical** (3,523,191 bytes), and the result
parses: `ksp-swift-cli dump` renders it as a project — 132 BPM, sixteen-note patterns, drum mode —
not as a well-formed sheet of filler.

**The byte-diff has since been run, and it found a defect that is not the transport's.** Against a
fresh MCC `Recall From` of the same slot, this read differs on **114 of 153,497 keys** — and the
Python raw-USB read of the same slot, taken the same day, differs on **117**. The two cores agree
with each other and disagree with MCC in the same families, so the transport is exonerated and the
walk is not: `bulk_fast` coalesces per-pattern scalars into a range the device does not honour, and
answers with index 1's value repeated. That is **[#255](https://github.com/bauerc/KeystepProTool/issues/255)**, it predates this work, and it corrupts
`ksp-pull` today.

So 7.9.2 establishes what it set out to — the transport carries a whole project, deterministically,
at the projected cost — and nothing more. **A CoreMIDI read is not yet byte-equal to MCC's export,
and will not be until #255 is fixed in both cores.**

One accident worth recording: the two cores' three-key difference is `123_117_14/15/16`, where
CoreMIDI's own `0xFF` truncation forced the element-wise re-read of 7.9.1 and so produced the
*correct* values where the raw-USB walk's coalesced read did not. The defect in this transport
masked a worse one in the plan.

**A published endpoint is not a live one, and the app must not treat it as one.** After an MCC
launch-and-quit cycle in the same session, the `KeyStep Pro` endpoint was still enumerated and
still accepted sends, while the device answered nothing — first the read frames went silent with
identity still answering, then identity went silent too. Nothing was unplugged and the device was
never power-cycled. **`killall MIDIServer` restored it completely**: identity, every read frame and
the full 4.00 ms timing came back byte-identical on the next run. So the remedy is a CoreMIDI
server restart, not a re-plug, and the diagnosis is a probe rather than an enumeration —
`MIDIObjectFindByUniqueID` finding the endpoint proves nothing. **Open an exchange with the
identity request and treat silence as "no device", however healthy the endpoint list looks.**

What evicted `MIDIServer` was not isolated: an MCC launch and quit preceded it, and MCC does use
raw IOKit USB (`IOUSBLib` is loaded in its process). Whether MCC detaches interface 2 on exit, or
whether `MIDIServer` simply failed to re-acquire it, was not separated — only that the state is
reachable and that the restart clears it.

**MIDI Control Center merely running changes nothing.** With MCC launched alongside, every reply
above was byte-identical and the timing unchanged at 4.00 ms. MCC holds only *device*-level user clients
(`AppleUSBHostDeviceUserClient`, which it opens on every USB device on the bus, Arturia or not) and
no interface-level client, so it is not contending for interface 2 while idle. **Not tested: MCC
mid-transfer**, driving a Recall From at the same time — that needs a hand on the GUI.

**Recommendation for the transport ticket: CoreMIDI, and nothing else.** The Swift read wants
`MIDIClientCreateWithBlock`, an input port per source and `MIDISend` to the destination, with SysEx
reassembled across packets — the device's replies exceed one packet's three bytes and arrive split.
Traffic is strictly serialised (7.1), so one outstanding request and a wait on the ack is the whole
flow control. The consequences that matter:

- **No `SMJobBless`, no XPC service, no privileged helper, no password prompt.** The app ships as an
  ordinary sandboxed-capable bundle. That larger, riskier piece of work is not needed and should
  not be ticketed. This is the finding that matters; the sentinel below is a wrinkle in the
  transport, not a reason to reach for root.
- **No `pyusb`, no `libusb`, no vendor-id matching** in the Swift port — CoreMIDI is a system
  framework and the endpoint is found by name.
- **It conforms to `KSPKit.Transport` but must not live in `KSPKit`.** The seam is already there —
  `public protocol Transport { exchange, send }` in `BulkRead.swift`, which `readRaw` drives — and
  conforming to it adds nothing to `KSPKit`. But `KSPKit` is the one target that builds and tests
  on the Linux runner, which is why `Package.swift` gates the MIDI layer off there, and CoreMIDI is
  Apple-only. So the transport belongs in a macOS-gated target beside `KSPMIDI`, never in `KSPKit`.
- **`tools/coremidi_read.swift` was that transport already, and it worked** (7.9.2). Moving it
  into `KSPDevice` was #246, and it has landed with the device-not-answering wording, a
  configurable timeout defaulting to Python's 1,000 ms, and tests. Two things changed in the move:
  the input port connects to the device's own source rather than to every source, so other MIDI
  gear on the same Mac cannot queue its traffic as a reply, and the identity request — which is
  universal, and measurably *not* acked, unlike every Arturia frame — ends on its own reply
  instead of waiting out the timeout for an ack that never comes.
- **The `0xFF` recovery of 7.9.1 is not optional.** It is the one place CoreMIDI is not a
  byte-transparent substitute for raw USB, it is invisible unless checked (the frame is well-formed
  and the address echoes), and `bulk_fast`'s `123_117` range hits it on every project. Reply length
  must be validated against the echoed count on every read, and a short reply re-read element-wise.
  `parse_reply` already refuses the frame, so the failure is loud — but only if nothing catches the
  error and carries on.
- **Liveness is a probe, not an enumeration.** The endpoint outlives the device's ability to answer,
  so the transport opens with the identity request and reports "not answering — quit MIDI Control
  Center, and if that does not help, `killall MIDIServer`" rather than "not connected".
- **The Python CLI is unaffected.** `ksp-pull` keeps its raw path and its `sudo`; this is the Swift
  transport's answer, and the two need not converge. Should the CLI ever want it, the same finding
  applies — a CoreMIDI transport there would drop the root requirement too.
