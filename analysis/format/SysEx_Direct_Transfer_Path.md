# The SysEx direct-transfer path

**Spec section:** §7 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The `arturia_v2` SysEx bulk stream, recorded for completeness. Not needed for file conversion.

---

## 7. Future path: direct-to-hardware over SysEx

Recorded for completeness; **not needed for file conversion.**

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

The blocker: the binary's strings do not reveal the byte-level command layout beyond the
envelope, so this would need live frame capture to reverse. The file route needs none of that.

(`libusb` in `/Library/Arturia/Shared/` is used only for DFU firmware updates — not for projects.)
