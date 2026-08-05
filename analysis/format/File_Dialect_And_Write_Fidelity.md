# File dialect and write fidelity

**Spec section:** §2 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** The flat-JSON dialect, the `<itemId>_<paramId>[_i1][_i2][_i3]` key grammar, the byte-level rules a writer must honour to produce a file MCC accepts, and the item IDs.

---

## 2. File format

A single flat JSON object. No nesting anywhere.

```json
{
	"device": "KeyStepPro",
	"version": "2.5.20",
	"120_101": 127,
	"123_109_10_1_1": 64,
	"125_49_1_1_5": 5,
	...
	"126_99_9": 20,
}
```

### Key grammar

```
<itemId>_<paramId>[_<idx1>][_<idx2>][_<idx3>]
```

`itemId` selects a functional section, `paramId` selects a parameter within it, and one to three
indices address pattern / pool chunk / step-or-note. "Pool chunk" is `idx2`; it is *not* a
polyphony voice, and `52` does not follow this scheme at all — see [the two index spaces](./Index_Spaces_And_Note_Placement.md).

### Write-fidelity rules

These are easy to get wrong and will produce files MCC rejects or misreads:

| Rule | Detail |
|---|---|
| **Trailing comma** | **Read:** MCC writes a `,` before the final `}`, so `json.loads` fails on every file it produces. Strip with `,(\s*[}\]])` → `\1`, or use a lenient/JSON5 parser. **Write: not required** — protocol test T6.2 (2026-08-01) put a file identical to a known-good export apart from that one byte into MCC; it loaded and transferred to the device. `ksp.lenient_json.dumps` therefore emits strict JSON. This is the *only* rule in this table shown to be optional |
| **Indentation** | Tab-indented |
| **No final newline** | The file ends at `}`. A standard end-of-file fixer breaks byte identity |
| **Line format** | Every line is exactly `\t"<key>": <value>,\n` — one tab, the key quoted, `": "` as the separator. Values are integers (0–247 across all samples) or the two strings below, each formatted exactly as `json.dumps` would. There are no floats, no booleans and no nesting anywhere |
| **Key order** | `device` first, then `version` if present, then every numeric key **sorted as a string**: `126_99_16` comes before `126_99_2`. A numeric sort produces a different file |
| **`version` key** | User-saved projects have `"version": "2.5.20"` immediately after `"device"`. The factory `Default.KeyStepPro` **does not**. A converter starting from the factory default must inject it — and put it in position, because assigning it to a loaded dict appends it at the end |
| **Fixed key set** | All observed files share an identical set of **153,495 numeric keys**. `Default.KeyStepPro` = 153,496 total (no `version`); user projects = 153,497. Never add or remove keys — only overwrite values |

The fixed key set is a significant simplification: there is no risk of omitting a key the
firmware requires, because you always start from a complete file.

**These rules are now confirmed against the firmware, not just against MCC.** Protocol M4.1 and
M4.2 built two files with `ksp.lenient_json` — one placing notes into an empty baseline, one
overwriting a single pitch in `project_5` — loaded both in MCC, transferred them to the device,
and read the results off its display. Both landed: the placed notes appeared and played, and the
edited pitch read C#3 at the step addressed, with its unedited neighbours untouched. Re-exporting
from the device returned the placement candidate with **zero keys changed**. So a file this writer
produces is not merely accepted by MCC's parser (T6.2) — the device stores and replays it
faithfully.

The only keys a device round trip moves are its own bookkeeping: `39` latches 2 → 3 per item,
alongside `40`, and `123_117_<pat>` normalises to 60 (see [per-pattern scalars](./Parameters_Pattern_Scalars.md)). A converter should expect those and
must not treat them as its own output drifting.

Together these rules are enough: applying them to a parsed sample reproduces its bytes exactly.
`ksp.lenient_json.dumps` / `canonical` implement them and `tests/test_round_trip.py` holds all
five samples to byte identity (milestone M3) — save the trailing comma, which the writer
deliberately omits on T6.2's evidence, so its output is one byte shorter than MCC's and is strict
JSON. Every other byte still has to match. Project names are **not** an exception — they are
stored as integer parameters, not JSON strings, so `device` and `version` are the only strings in
the file and no sample contains a non-ASCII byte.

### Item IDs

From `bulkOperation[].bulkItemId` in `KeyStepPro.json`:

| Item ID | Meaning | Entries |
|---|---|---|
| `120` | Project / global — tempo, swing, ARP globals | ~30 |
| `121` | **Scenes** (16 per project) | ~1,488 |
| `122` | **Control track** — 5 CC automation lanes | ~7,316 |
| `123` | **Track 1** — carries **both** a sequencer and a full drum parameter set | ~70,102 |
| `124` / `125` / `126` | **Tracks 2 / 3 / 4** — sequencer only | ~24,853 each |

Track 1 is roughly three times the size of tracks 2–4 because it holds a complete **second
parameter set for DRUM mode**, not because of any extra modulation lane.
