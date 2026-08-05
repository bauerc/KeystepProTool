# MCC resources and device identity

**Spec section:** §1 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** Where MCC keeps the parameter dictionary on disk, the device's USB and SysEx identity, and the MCC implementation constraints that follow from it.

---

## 1. Where the authoritative data lives

MCC keeps device data **outside** its app bundle, in a shared, world-readable directory:

| Path | What it is |
|---|---|
| `/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json` | **The parameter dictionary** — 217 KB, 205 field definitions, 25 item types, 18 bulk-transfer descriptors. `fields[]` gives parameter *names*; **`bulkOperation` gives their index shapes** (see [reproducing the findings](./Reproducing_Findings_And_Index_Shapes.md)) |
| `/Library/Arturia/MIDI Control Center/Resources/KeyStepProTest.json` | Factory-test variant of the same schema |
| `/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.ui` | Panel hit-boxes for the Device Test view. Plain JSON despite the extension. **No format-relevant data** |
| `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/Factory/Default.KeyStepPro` | **Canonical blank project** — the ideal converter baseline |
| `/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/` | MCC's project library. Files here appear in the Project Browser |
| `/Library/Arturia/MIDI Control Center/Firmware/keystep-pro_Firmware_Update_2.5.20.0.kspf` | Firmware. A ZIP containing `info.json` + a DFU `.bin` |

Device identity, from `KeyStepPro.json`:

```
usbVendorId          7285 (0x1C75)      usbProductId    536 / 8728
manufacturerId       00 20 6B           familyId        0200
productId            42                 familyMemberId  0900
protocol             arturia_v2         templateExtension  .KeyStepPro
memories             16                 minimalVersionRequired  2.5.14
deviceGlobalParametersId  65
```

### MCC implementation constraints worth knowing

- MCC is a **JUCE** application (not Qt): a single 24 MB Intel-only Mach-O, no bundled frameworks.
  It parses this JSON with **Boost.PropertyTree**, which is exactly why trailing commas are accepted.
- `Info.plist` declares **no `CFBundleDocumentTypes` and no UTIs**. `.KeyStepPro` is not a
  registered document type and MCC never opens files via LaunchServices. Projects are found
  purely by **scanning the Templates directory**, which is world-writable — so a tool can drop
  files there with no elevation and no Finder integration. MCC scans at launch, so expect to
  restart it before a new file appears.
- **MCC has no MIDI export for the KeyStep Pro, and no import either** — confirmed in the UI.
  `KeyStepPro.json` declares only `actions: ["store", "recall"]`, and the binary's sole
  MIDI-file-writing code sits in the **BeatStep Pro** `.mbseq` save path, which is where the
  often-repeated "MCC can export MIDI" claim comes from. Getting patterns out as `.mid` is the gap
  this project fills, and it means there is no reference render to check our own output against.
- There is no CLI, AppleScript dictionary, or headless mode. Automation must be file-level.
