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
both transports. A CoreMIDI direct-transfer path is therefore structurally feasible and would
reuse the same model layer.

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

`<slot>` is the project number — see [7.4](#74-the-project-slot-is-byte-7). The ack is the only
frame that does not carry it; its `00` is a constant, not a slot.

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

That is a recording, not the device. `ksp.bulk_read` has not been run end to end against live
hardware — the six H1 probes exercised pieces of it, not the whole walk.

The two questions this section used to leave open — how a project slot is named, and how a write
is framed — are answered by the captures in 7.4 and 7.5, and **not** by hardware. What 7.4 proves
is that MCC *sends* a slot number and that nothing else in the stream could be one. Whether the
device honours it is H4.1. Nothing below has been sent to a device by this project.

(`libusb` in `/Library/Arturia/Shared/` is used only for DFU firmware updates — not for projects.)

### 7.4 The project slot is byte 7

The byte after the command is the **project number**. It was carried as an untested constant `01`
for as long as every capture came from project 1. Four captures now disagree about it, and they
disagree exactly where the project changes:

| Capture | Operation | Byte 7 |
|---|---|---|
| `sysex_until_project_1_track_1_pattern_1.jsonl` | partial read, project 1 | `01` |
| `recall_sysex.jsonl` | full Recall To, project 1 | `01` |
| `recall_project_2.jsonl` | full Recall To, project 2 | `02` |
| `import_to_project_3.jsonl` | full write, project 3 | `03` |

It rides in every command — `01`, `02`, `05`, `06`, `0B`, `0C` — and is constant for the whole of
a transfer. Only the ack is exempt.

**Why it cannot be anything else.** Both new captures are gapless: frame numbers step by exactly
two from frame 7 with no holes, so every USB frame that crossed the wire is in the file and no
non-SysEx MIDI was dropped in extraction. Laid side by side, the import's 8,951 outbound writes
are byte-identical to the recall's 8,951 inbound replies once byte 7 is masked — **8,950 of
8,951**, the exception being the sentinel frame in 7.6. Byte 7 and the closing `06 <slot>` are
therefore the *only* bytes in the entire import stream that name slot 3. There is nothing else
left for the destination to be encoded in.

Independently: the project 1 and project 2 recalls send an identical request stream and get
**different answers for 971 of 8,951 addresses**, so the two reads are not both returning one
loaded project.

**This is capture-derived, not confirmed** — but one hypothesis is now ruled out. Editing a project
on the device and *not* saving it, then pulling, does not bring the unsaved edits across: a read
returns the slot's stored project, not the panel's live edit buffer. That kills "byte 7 is inert
and the panel's working buffer is what you get" as written. It does not, on its own, separate the
two hypotheses that remain — byte 7 selects the slot, or a read always returns the panel-loaded
slot's stored data regardless of byte 7 — since both agree with unsaved edits never travelling.
**H4.1** in the [hardware test protocol](../Hardware_Test_Protocol.md) is still the probe that
separates them, and it now runs inside `usb_probe.py phase2`.

`tests/test_capture_evidence.py` holds the tape claims above.

### 7.5 The write direction

A write is the read protocol with the **reply opcodes sent as requests**:

```
long   write  F0 00 20 6B 7F 42 0C <slot> <param> <nIdx> <item> <idx1..idxN> <count> <count bytes> F7
short  write  F0 00 20 6B 7F 42 02 <slot> <param> <item> <one byte> F7
ack           F0 00 20 6B 7F 42 1C 00    F7
```

The device acks each one. Flow control is unchanged — one outstanding message, strictly
serialised — and the addresses and their order are **the same 8,951 the read plan walks**, so
`ksp.bulk_plan` is the write plan as well as the read plan. Nothing new has to be generated.

Session framing is asymmetric, and each frame appears exactly once:

- `05 <slot>` is the **first** frame of a read, before any request.
- `06 <slot>` is the **last** frame of a write, after the final value. It is not acked.

H1.4 already showed `05` is not required to read. Whether `06` is a required commit — whether a
write without it persists to the slot at all — has not been tested, and is the obvious thing to
establish before anything writes to hardware.

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
