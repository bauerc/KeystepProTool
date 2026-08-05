# Reproducing the findings, and where index shapes come from

**Spec section:** §9 — part of [`KeyStepPro_Format_Spec.md`](../KeyStepPro_Format_Spec.md)
**Covers:** A minimal parser for re-deriving every claim from files already on disk, and how `bulkOperation` — not `fields[]` — gives the index shapes.

---

## 9. Reproducing these findings

Everything in this specification is checkable from files already on disk. Minimal parser:

```python
import json, re

def load(path):
    s = open(path, encoding='utf-8', errors='replace').read()
    return json.loads(re.sub(r',(\s*[}\]])', r'\1', s))   # strip trailing commas

spec = load('/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json')
proj = load('project_files/project_5.KeyStepPro')

# the parameter dictionary
for f in spec['fields']:
    print(f.get('paramId'), f.get('name'))

# Track 3, pattern 1, slot 1 — pitch by note ordinal
print([proj.get(f'125_109_1_1_{i}') for i in range(1, 13)])
```

The tables in [the worked example](./Worked_Example_Project_5.md) were produced this way. Any claim here that cannot be re-derived from
`KeyStepPro.json` plus the files in `../../project_files/` should be treated as suspect.

### `bulkOperation` — where the index shapes come from

`fields[]` gives parameter names and nothing else. **`bulkOperation` gives shapes**: for every
parameter it declares which index ranges are addressable and what each index means. Reading only
`fields[]` is how the two index spaces (see [the two index spaces](./Index_Spaces_And_Note_Placement.md)) were originally misread, so start here for any question
of the form "what is this index".

Each descriptor carries `bulkParamIds`, a `bulkItemId` address template and a human-readable
`desc`. In the template, `"IDX"` is substituted from the enclosing `multibulk_idx` range, a nested
list is a set of literal index values, and a trailing `start, count` pair is a range:

```json
{"bulkParamIds": [48, 49], "bulkItemId": [[123], ["IDX"], [1], 17, 16],
 "desc": "Pattern idx / Step seq parameters (step 17 -> 32) (step active, step skip)"}
```

— parameters `48` and `49`, item `123`, pattern `IDX`, **index-2 fixed at `1` and only `1`**,
index-3 running 16 values from 17. That middle `[1]` is why `48`/`49` are per-pattern rather than
per-slot, while the note parameters use `[1, 2, 3]`. Flatten them all with:

```python
def walk(o, depth=0):
    if isinstance(o, dict):
        d = o.get('desc') or o.get('multibulk_desc')
        if 'bulkParamIds' in o:
            print(' ' * depth, o['bulkParamIds'], '|', json.dumps(o.get('bulkItemId')), '|', d)
        elif d:
            print(' ' * depth, '##', d, o.get('multibulk_idx', ''))
        for k, v in o.items():
            if k == 'multibulk':
                walk(v, depth + 2)
    elif isinstance(o, list):
        for x in o:
            walk(x, depth)

walk(spec['bulkOperation'])
```

The dictionary explains *why*; the sample files prove *that*. Every shape claim in the parameter dictionary and index-space files is
also checkable against `../../project_files/` alone, with no MCC installation.
