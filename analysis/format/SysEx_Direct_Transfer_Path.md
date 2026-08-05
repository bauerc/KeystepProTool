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
long   request  F0 00 20 6B 7F 42 0B 01 <param> <nIdx> <item> <idx1..idxN> <count> F7
long   reply    F0 00 20 6B 7F 42 0C 01 <param> <nIdx> <item> <idx1..idxN> <count> <count bytes> F7
short  request  F0 00 20 6B 7F 42 01 01 <param> <item> F7
short  reply    F0 00 20 6B 7F 42 02 01 <param> <item> <one byte> F7
ack             F0 00 20 6B 7F 42 1C 00 F7
```

The reply **echoes the request header verbatim**, count byte included, which is what makes a
desynchronised stream detectable rather than silently misfiled. A long read walks its *last*
index forward by `count`; the other indices are fixed. Traffic is strictly serialised — request,
reply, ack — so one outstanding request at a time is the whole flow control.

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

That is a recording, not the device. The read has not been run against live hardware, and the
**write** direction is undecoded — nothing here says how to send a project *to* the device.
One open question the address tuple cannot answer: **nothing in it identifies a project slot**,
so a read returns whichever project is currently loaded. See `ROADMAP.md`.

(`libusb` in `/Library/Arturia/Shared/` is used only for DFU firmware updates — not for projects.)
