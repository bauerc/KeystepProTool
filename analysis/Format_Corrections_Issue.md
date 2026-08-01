# Issue: format corrections resolvable without hardware

**Type:** work order. Self-contained — an agent can pick this up with no other context.
**Blocks:** M5, M6 (the two blockers listed at the bottom of `../ROADMAP.md`).
**Needs hardware:** no. Every claim here is re-derivable from files already on disk.
**Companion document:** [`Hardware_Test_Protocol.md`](./Hardware_Test_Protocol.md) covers what
genuinely needs the device.

---

## Summary

`analysis/KeyStepPro_Format_Spec.md` lists four format questions as open and `ROADMAP.md` puts
two of them on the critical path to writing files. They are not open. MCC ships a machine-readable
description of the format's index dimensions in `KeyStepPro.json` → `bulkOperation`, and that
document plus the five sample projects settles all of them.

The spec was written from the *field* list (`fields[]`, which gives names only). `bulkOperation`
is the part that gives **shapes** — it declares, for every parameter, exactly which index ranges
are addressable and what each index means. Reading it changes five conclusions.

> **Status: every finding below is confirmed, but not all of them reached the code.** The tier
> 1/3/4 captures agreed with all six. An earlier version of this header claimed the whole work
> order was implemented; that was wrong, and it cost real time — finding 4 sat unapplied for long
> enough that the reader kept discarding 43 notes while *this document explained exactly why*.
> **Confirming a finding and applying it are separate columns.** The table below now tracks both.

| # | Finding | Confirmed | In the code |
|---|---|---|---|
| 1 | `48`/`49` are per-pattern, not per-slot | ✅ | ✅ 83ef72f — reader reads `48` from chunk 1 as pattern-wide |
| 2 | Every track has **3** poly slots, Track 1 included | ✅ D2 — `idx2` is a 64-entry **pool chunk**, not a voice at all | ❌ **open** — `SLOTS_BY_ITEM[123]` is still 4 and `slot_is_initialised` still guards the zero-filled phantom |
| 3 | `52` (drum step active) is fully decoded | ✅ D1/D3 — lane-major, 7 bits per entry (spec §4) | ✅ 83ef72f |
| 4 | The drum note array is a **pool**, not a compacted list | ✅ D3 filled it to its 192-event ceiling | ✅ — the scan now skips holes for drums and keeps `break` for melodic |
| 5 | `52` is authoritative for what sounds, not the note pool | ✅ **D1** — the step did not sound with its flag clear | ✅ 83ef72f |
| 6 | `51` is indexed by drum lane 1–24, not by step | ✅ D4 | ⚠️ constants only — nothing reads it, so per-lane lengths are not rendered |

Findings 3 and 4 together cleared M5's blocker. M6's other blocker — the drum-mode bit — was
*not* resolved here, and the hardware protocol settled it: it is `86` bit 6, not `100`.

---

## Where the evidence comes from

MCC keeps its device dictionary outside the app bundle:

```
/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json
```

It is not strict JSON (same trailing-comma dialect as the project files). To read it:

```python
import json, re

def load(path):
    s = open(path, encoding="utf-8", errors="replace").read()
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", s))

spec = load("/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json")
```

`spec["fields"]` is the 205-entry name list the current spec was built from. **`spec["bulkOperation"]`
is the part that matters here.** Each descriptor carries `bulkParamIds` (which parameters), a
`bulkItemId` address template, and a human-readable `desc`. The address template is a list where
`"IDX"` is substituted from the enclosing `multibulk_idx` range, a nested list is a set of literal
index values, and a trailing `start, count` pair gives a range. So

```json
{"bulkParamIds": [48, 49], "bulkItemId": [[123], ["IDX"], [1], 17, 16],
 "desc": "Pattern idx / Step seq parameters (step 17 -> 32) (step active, step skip)"}
```

reads as: parameters `48` and `49`, item `123`, pattern `IDX`, **index-2 value `1` and only `1`**,
index-3 running 16 values from 17. That middle `[1]` is the whole finding of §1 below.

To print the descriptors flattened:

```python
def walk(o, depth=0):
    if isinstance(o, dict):
        d = o.get("desc") or o.get("multibulk_desc")
        if "bulkParamIds" in o:
            print(" " * depth, o["bulkParamIds"], "|", json.dumps(o.get("bulkItemId")), "|", d)
        elif d:
            print(" " * depth, "##", d, o.get("multibulk_idx", ""))
        for k, v in o.items():
            if k == "multibulk":
                walk(v, depth + 2)
    elif isinstance(o, list):
        for x in o:
            walk(x, depth)

walk(spec["bulkOperation"])
```

> If MCC is not installed, findings 1–6 are all still checkable against
> `project_files/*.KeyStepPro` alone — every verification snippet below reads only those files.
> The dictionary explains *why*; the files prove *that*.

---

## Finding 1 — `48` and `49` are per-pattern, not per-slot

**Descriptor.** The step-active/step-skip pair is addressed with index-2 fixed at `[1]`:

```
[48, 49] | [[123], ["IDX"], [1],  1, 16] | Pattern idx / Step seq parameters (step 1 -> 16)
[48, 49] | [[123], ["IDX"], [1], 17, 16] | Pattern idx / Step seq parameters (step 17 -> 32)
[48, 49] | [[123], ["IDX"], [1], 33, 16] | Pattern idx / Step seq parameters (step 33 -> 48)
[48, 49] | [[123], ["IDX"], [1], 49, 16] | Pattern idx / Step seq parameters (step 49 -> 64)
```

identically for items `124`, `125`, `126`. Compare the note parameters, which use `[1, 2, 3]`:

```
[109, 110, 111, 112, 113, 50] | [[123], ["IDX"], [1, 2, 3], 1, 16] | Pattern idx / Note seq parameters
```

So the second index is a poly slot **only for note parameters**. For `48`/`49` it is a fixed `1`,
and the keys `..._48_<pattern>_2_*` through `_4_*` are padding.

**Verification — padding is always zero, and slot 1 is the union across slots:**

```python
from ksp import lenient_json

files = ["Default", "user_empty_project", "project_5", "project_9", "initial_project"]
for f in files:
    d = lenient_json.load_path(f"project_files/{f}.KeyStepPro")
    pad = {v for it in (123, 124, 125, 126) for pr in (48, 49)
           for p in range(1, 17) for sl in (2, 3, 4) for i in range(1, 65)
           if (v := d.get(f"{it}_{pr}_{p}_{sl}_{i}")) is not None}
    bad = 0
    for it in (123, 124, 125, 126):
        for p in range(1, 17):
            flags = {i for i in range(1, 65) if d.get(f"{it}_48_{p}_1_{i}") == 1}
            notes = set()
            for sl in (1, 2, 3):
                for i in range(1, 65):
                    s = d.get(f"{it}_50_{p}_{sl}_{i}")
                    if s is None or s == 127:
                        break
                    notes.add(s + 1)
            bad += flags != notes
    print(f"{f:20s} padding values={sorted(pad)}  mismatched patterns={bad}/64")
```

**Result.** Padding is `{0}` in all five files. Mismatched patterns: **0 out of 64 in every
file** — 320 patterns, exact agreement, no exceptions.

**Consequence.** `reader._check_step_active` compares `48` against a *per-slot* note list, so on
any pattern using more than one poly slot it reports a disagreement that does not exist. That is
the source of all three step-active warnings on `initial_project` Track 3 pattern 3. The check is
worth keeping — it caught nothing real here, but it is close to free and would catch a misread
index space — it just has to compare against the union over slots 1–3.

---

## Finding 2 — every track has 3 poly slots, Track 1 included

**Descriptor.** As quoted above, both note-parameter groups use `[1, 2, 3]` on **item 123 as well**:

```
[109, 110, 111, 112, 113, 50]      | [[123], ["IDX"], [1, 2, 3], 1, 16] | Note seq parameters
[53, 54, 117, 118, 119, 120, 121]  | [[123], ["IDX"], [1, 2, 3], 1, 16] | Note DRUM parameters
```

There is no descriptor anywhere that addresses a note parameter at index-2 value `4`.

**The files say the same thing without the dictionary.** Enumerate the actual key space and
tracks 2–4 have **no slot 4 at all** — the keys do not exist:

```python
import re, collections
from ksp import lenient_json

d = lenient_json.load_path("project_files/initial_project.KeyStepPro")
dims = collections.defaultdict(lambda: collections.defaultdict(set))
for k in d:
    if not re.match(r"^\d+_\d+", k):
        continue
    parts = k.split("_")
    idx = parts[2:]
    if len(idx) != 3:
        continue
    for i, v in enumerate(idx):
        dims[(int(parts[0]), int(parts[1]))][i].add(int(v))

for key in sorted(dims):
    print(key, [f"{min(dims[key][i])}-{max(dims[key][i])}" for i in range(3)])
```

Every three-index parameter on items `124`, `125`, `126` has slot range **1–3**. Only item `123`
has 1–4 — and on item `123` it is *every* three-index parameter, including `48`, `49` and `50`,
which have no use for a fourth slot.

**Why slot 4 exists there.** Parameter `52` needs 240 entries (finding 3) and is packed across the
same three-index address space, so item 123's arrays are dimensioned `16 × 4 × 64` to give it
room. Every parameter in that item inherits the shape. Slot 4 of the note parameters is space
nothing writes to — which is why it is uniformly zero rather than sentinel-filled.

**Consequence.** Spec §4's "Track 1's fourth slot is zero-filled, not sentinel-filled" is a true
observation with the wrong explanation. It is not that "the firmware appears never to initialise
it" — it is that slot 4 was never a poly slot. `reader.slot_is_initialised` and its
zero-fill heuristic can be deleted outright rather than kept as a defensive special case, and the
open question "whether slot 4 is usable at all on the hardware is untested" is answered: it is
not addressable.

`constants.SLOTS_BY_ITEM` becomes `3` for all four items. Since it is then uniform, consider
replacing the dict with a single `SLOTS_PER_PATTERN: Final = 3`.

---

## Finding 3 — `52` (DRUM step active) is fully decoded

This is M5's blocker and the descriptors state the layout in plain words. Sixteen of them cover
`52`; here are the first three and the last:

```
[52] | [[123], ["IDX"], [1],  1, 16] | (DRUM 1 part 1 to 10, DRUM 2 part 1 to 6) (step active)
[52] | [[123], ["IDX"], [1], 17, 16] | (DRUM 2 part 7 to 10, DRUM 3 part 1 to 10, DRUM 4 part 1 to 2)
[52] | [[123], ["IDX"], [1], 33, 16] | (DRUM 4 part 3 to 10, DRUM 5 part 1 to 8)
...
[52] | [[123], ["IDX"], [4], 33, 16] | (DRUM 23 part 5 to 10, DRUM 24 part 1 to 10)
```

Read them in order and the picture is a **single flat 240-entry array laid out lane-major**,
spilling across the slot index: slot 1 indices 1–64, slot 2 indices 1–64, slot 3 indices 1–64,
slot 4 indices 1–48. 240 = **24 drum lanes × 10 parts**.

```
n     = (slot - 1) * 64 + idx           # 1 .. 240
lane  = (n - 1) // 10                   # 0-based, 0 .. 23   (lane 0 = kick)
part  = (n - 1) %  10                   # 0 .. 9
```

Ten parts per lane over 64 steps means **7 bits per entry** — which is also the natural width for
a format whose values are all MIDI 7-bit. Part *p* covers steps `7p+1 … 7p+7`, giving 70 addressable
steps for a 64-step maximum:

```
step = part * 7 + bit + 1               # bit 0 .. 6, LSB first
```

**Worked check.** `initial_project` Track 1 pattern 1 slot 1 stores `52` = `17, 34` at indices 1
and 2, i.e. lane 0 parts 0 and 1:

- part 0 → steps 1–7. `17` = `0b0010001` → bits 0, 4 → **steps 1, 5**
- part 1 → steps 8–14. `34` = `0b0100010` → bits 1, 5 → **steps 9, 13**

Lane 0's note list in that pattern is steps 1, 5, 9, 13. Exact.

The same pattern's second lane is lane 17, whose parts live at `n` = 171–180 → slot 3, indices
43–52 — and slot 3 indices 43, 44, 45 are the only non-zero entries there. This is why the values
looked scattered and unexplainable when `52` was read as a 16-entry per-slot array.

**Verification — decode `52` and compare against the drum note pool:**

```python
from ksp import lenient_json

def flags52(d, pattern):
    out = {}
    for n in range(1, 241):
        slot, idx = (n - 1) // 64 + 1, (n - 1) % 64 + 1
        v = d.get(f"123_52_{pattern}_{slot}_{idx}")
        if not v:
            continue
        lane, part = (n - 1) // 10, (n - 1) % 10
        for bit in range(7):
            if v >> bit & 1:
                out.setdefault(lane, set()).add(part * 7 + bit + 1)
    return out

def pool(d, pattern):                      # finding 4: scan all, skip 127, never break
    out = {}
    for slot in (1, 2, 3):
        for i in range(1, 65):
            s = d.get(f"123_54_{pattern}_{slot}_{i}")
            if s is None or s == 127:
                continue
            out.setdefault(d.get(f"123_117_{pattern}_{slot}_{i}"), set()).add(s + 1)
    return out
```

**Result.** `flags52` reproduces both hardware-confirmed projects exactly — `project_5`
pattern 1 → steps 1 and 5 on lane 0, `project_9` patterns 2 and 3 → step 1 on lane 0 — and every
lane of `initial_project` patterns 2, 6 and 12. On the remaining `initial_project` patterns it is
a strict subset of the pool, which is finding 5.

---

## Finding 4 — the drum note array is a pool, not a compacted list

Spec §4 rule 1 says "notes must be packed contiguously from index 1, with no gaps", and the
reader implements that by stopping at the first `127`. That holds for the melodic parameter set
and **not** for the drum set.

**Evidence.** `initial_project` Track 1 pattern 5 slot 1, parameter `54` (note → step), entries
1–39:

```
0, 4, 52, 4, 12, 8, 11, 12, 13, 14, 15, 12, 1, 2, 51, 36, 35, 56, 48, 56, 24, 27, 28, 40, 43,
44, 60, 127, 127, 20, 28, 36, 44, 52, 127, 20, 28, 36, 44
```

with `117` (lane) alongside:

```
5, 17, 7, 12, 12, 7, 7, 7, 7, 7, 7, 17, 5, 5, 7, 7, 7, 12, 7, 17, 7, 7, 7, 7, 7, 7, 12, 127,
127, 12, 12, 12, 12, 12, 127, 17, 17, 17, 17
```

Entries 28–29 are `127`, and entries 30–34 hold five lane-12 notes at steps 21, 29, 37, 45, 53,
and entries 36–39 hold four lane-17 notes. These are not stale — `52` flags **exactly** those
steps on those lanes, which is what makes them provably live rather than leftover.

So `127` marks an *empty entry*, not a terminator, and the array is a 192-slot pool with holes.
"N value(s) after the end of the note list were ignored" is the reader announcing that it dropped
real user notes.

**The melodic set is genuinely compacted.** Verified — zero slots in any of the five files have a
non-`127` value after a `127` in parameter `50`:

```python
for f in files:
    d = lenient_json.load_path(f"project_files/{f}.KeyStepPro")
    hits = 0
    for it in (123, 124, 125, 126):
        for p in range(1, 17):
            for sl in (1, 2, 3):
                seen = False
                for i in range(1, 65):
                    v = d.get(f"{it}_50_{p}_{sl}_{i}")
                    if v == 127:
                        seen = True
                    elif seen and v is not None:
                        hits += 1
                        break
    print(f, hits)          # 0 for all five files
```

**Consequence.** The two sets need different scan rules, and the reader must not share one. Note
that this does not weaken the existence test: `54 != 127` is still exactly right per entry. What
changes is that a `127` does not end the scan.

Writing is easier than reading here: a converter starting from `Default.KeyStepPro` can emit a
compacted pool with no holes and be well-formed. It only has to *tolerate* holes on read.

---

## Finding 5 — `52` is authoritative for what sounds

Spec §5 says "notes come from `54` plus `117`–`121`, which is authoritative" and treats `52` as
redundant. The file evidence points the other way.

**Verification — is every flagged step backed by a pooled note?**

```python
for f in files:
    d = lenient_json.load_path(f"project_files/{f}.KeyStepPro")
    for p in range(1, 17):
        fl, nt = flags52(d, p), pool(d, p)
        for lane, steps in fl.items():
            assert steps <= nt.get(lane, set()), (f, p, lane, sorted(steps - nt.get(lane, set())))
print("every flagged step has a pooled note")
```

**Result.** Passes on all five files, all 16 patterns, no exceptions. The converse is false: many
pooled notes carry no flag — for example `initial_project` pattern 3, lane 19 holds 16 pooled
notes at steps 1–16 and `52` flags none of them.

That asymmetry is exactly what you would expect if `52` is the play/don't-play state and the pool
is parameter storage the device keeps around when a step is toggled off. Under the previous
reading — pool authoritative, `52` redundant and mispacked — there is no account of why the
"redundant" array is always a subset and never a superset.

**Confidence.** Strong, but this is a claim about device *behaviour* inferred from file *state*,
which is a weaker kind of evidence than the shape findings above. It gets a hardware confirmation:
**test D1** in the protocol document. Until D1 runs, the reader should decode both and report the
flag state per note rather than silently filtering — a note that is pooled but unflagged is
information the user wants either way.

---

## Finding 6 — `51` is indexed by drum lane, not by step

```
[51] | [[123], ["IDX"], [1],  1, 12] | Pattern idx / DRUM parameters (DRUM 1 -> 12) (poly step count)
[51] | [[123], ["IDX"], [1], 13, 12] | Pattern idx / DRUM parameters (DRUM 12 -> 24) (poly step count)
```

Index-2 fixed at `1`; index-3 runs 1–24, one entry per drum lane. Every sample file holds `15`
(a 16-step lane, 0-based like the other step counts) in entries 1–24 and `0` beyond, on every
pattern that has drum data.

**Consequence.** "DRUM poly step count" means *per-lane step count* — each drum lane can run at
its own length, which is how the KeyStep Pro does polyrhythm on the drum track. Spec §3.2's
"indexed by step" is wrong. Whether lanes really can differ is worth one cheap capture
(**test D4**), because no sample file has non-uniform values.

---

## Required changes

### `src/ksp/constants.py`

- `SLOTS_BY_ITEM` → 3 for every item (finding 2). Consider collapsing to a scalar
  `SLOTS_PER_PATTERN: Final = 3`, since the dict no longer varies.
- Add the `52` geometry (finding 3): 24 lanes, 10 parts per lane, 7 bits per part, 240 entries
  total, flat index `(slot - 1) * 64 + idx`. These want a short comment tying them to the
  `bulkOperation` descriptors, in the style the module already uses.
- Correct the comment on `P_DRUM_POLY_STEP_COUNT` (`51`) to say lane-indexed, 1–24 (finding 6).
- Drop the "packing not fully decoded" comment on `P_DRUM_STEP_ACTIVE` (`52`).

### `src/ksp/reader.py`

- `_read_note_lists` / `_read_slot`: slots 1–3 only (finding 2).
- Drum scan: iterate all 64 entries of each of the 3 slots, `continue` past `127` rather than
  `break` (finding 4). Melodic scan keeps `break`. The two rules differ and the module docstring
  should say why, since it currently teaches the opposite.
- Delete `slot_is_initialised` and the slot-4 zero-fill handling. It becomes unreachable once
  slot 4 is out of range, and leaving it in would preserve a wrong explanation in a docstring
  that is otherwise the best account of the format in the codebase.
- `_check_step_active`: compare `48` at slot 1 against the union of note steps over slots 1–3,
  once per pattern rather than once per slot (finding 1).
- Add `52` decoding, and surface per-note flag state. Add the mirror-image drum check —
  every flagged step must have a pooled note — which is the invariant finding 5 rests on, so a
  file that violates it is telling us the model is wrong.
- The "N value(s) after the end of the note list were ignored" warning goes away for drums. Keep
  it for the melodic set, where compaction is verified.

### `analysis/KeyStepPro_Format_Spec.md`

- §3.2 — `51` lane-indexed; `52` fully specified with the flat-index formula.
- §4 — poly slots are 1–3 on all tracks; delete the zero-fill trap and its "firmware never
  initialises it" explanation; state that melodic lists are compacted and the drum pool is not,
  and that rule 1 ("packed contiguously, no gaps") is a rule for *writers*, not an invariant
  readers may assume.
- §5 — replace the "`52` is not fully decoded" caveat with the decode; revise the authority
  claim per finding 5, marked as pending test D1.
- §0 and §8 — the summary bullets and the corrections table both restate the old slot and
  index-space claims.
- Add `bulkOperation` to §1's table of what lives where, and to §9's reproduction instructions.
  Its absence is why these five findings were missed: §9 currently points a reader at `fields[]`,
  which has names but no shapes.

### `ROADMAP.md`

- M1's "what it turned up" section: the three findings recorded there as unresolved are resolved.
- M5 no longer depends on drum `52` packing; M6 no longer depends on it either and retains only
  the mode bit in `100`.
- The dependency-summary table and the two-blocker note at the end both need updating.
- M6's "Poly slots cap at 3 (4 on Track 1) — decide and document what happens to a 5-note chord"
  becomes "cap at 3 everywhere"; the 4-note-chord question moves to hardware test D2.

### `tests/`

New invariants, all desk-testable:

- `48` at slot 1 equals the union of note steps over slots 1–3, for every pattern of every
  sample file.
- `48`/`49` slots 2–4 are uniformly zero.
- `52` decodes to a subset of the drum pool on every pattern of every sample file, and equals it
  exactly on `project_5` and `project_9`.
- The drum pool scan recovers the notes currently dropped in `initial_project` patterns 5 and 9 —
  assert the specific lane-12 and lane-17 notes, so a regression is legible.
- No melodic slot has data after an interior `127`.

`tests/fixtures/*.json` are hand-transcribed from the hardware description files. Where the new
reader reports notes it previously dropped, **update the fixtures by hand and cross-check against
`analysis/project_5_description.txt` and `analysis/project_9_tests.txt`** — do not regenerate them
from the reader, which would defeat their purpose as independent ground truth (see
`tests/fixtures/README.md` and the note in `CLAUDE.md`).

Do not touch `project_files/*.KeyStepPro` or `analysis/*.txt`.

---

## Acceptance

- `uv run ksp-dump project_files/initial_project.KeyStepPro --all` emits **no** step-active
  warnings and **no** trailing-value warnings. The only remaining warning is the parameter `100`
  mode ambiguity, which is hardware work.
- The notes currently dropped from `initial_project` patterns 5 and 9 appear in the dump.
- `uv run pytest -m "not hardware"` green; `uv run ruff check . && uv run ruff format --check .`
  and `uv run mypy` clean.
- The spec no longer contains a claim contradicted by the `bulkOperation` descriptors.

## Out of scope

Anything needing the device: the gate table, the drum-mode bit in `100`, the `99`/`116` bitfield
layout, the D1 confirmation of finding 5, and the real poly/lane limits. All of these are in
[`Hardware_Test_Protocol.md`](./Hardware_Test_Protocol.md).
