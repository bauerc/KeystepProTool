# Read Cost: What Parsing a Project Costs

**Status:** **complete.** The Python figures were measured 2026-09-03 by
[`./scripts/bench_read.sh`](../scripts/bench_read.sh); the Swift figures were re-measured
2026-09-05, after [#239](https://github.com/bauerc/KeystepProTool/issues/239) replaced
`JSONDecoder` with a hand-rolled scan (§9). **The harness measures the Python core only** —
§7 says what took the Swift figures and how to take them again.
**Evidence for** requirement **D1** of `project_requirements/project_requirements.md` — *"a parser
that reads them in a timely, byte-efficient and non-duplicative manner"* — which epic #115 records
as already delivered on this document's authority.
**Prerequisite:** [`KeyStepPro_Format_Spec.md`](./KeyStepPro_Format_Spec.md) §2, the dialect being
parsed.

---

## 0. Why this exists

Both cores have a parser and both are fast, but "fast" was an impression. #115's
requirement-coverage table records D1 as delivered and points at #161 for the number; there was no
number, and no note of where the cost goes on a 3.5 MB project.

M15 is what makes that matter. The app parses a whole project to draw the preview grid, on a path
a person is standing in front of — so the question is no longer academic, and the answer turned
out to name a real defect (§8).

The measurement changed nothing under `src/` when it was made. It named a defect (§8, #238) and
the one phase worth optimising (§9, #239), and both have since been acted on in `swift/Sources/`;
the Python core and the parity scripts are untouched by either.

## 1. The model: three phases

A read is the same three phases in both cores, which is what makes them comparable:

| Phase | Python | Swift |
|---|---|---|
| bytes off disk | `Path.read_bytes()` | `Data(contentsOf:)` |
| lenient JSON parse | `lenient_json.loads` → `strip_trailing_comma_fast` + `orjson.loads` | `LenientJSON.parse` → `JSONScanner` |
| decode to model | `reader.read_project(raw)` | `Reader.readProject(raw)` |

Three facts about the subject bind the harness:

- **`src/ksp/reader.py:25` — `load` is `@lru_cache(maxsize=16)`.** A repeat measurement in one
  process measures the cache, not the parser, so the harness calls `cache_clear()` between reps
  and reports the cached call separately as its own figure.
- **Swift's `Reader.load` has the same cache since #238** — `ReadCache`, sixteen entries, keyed on
  the path. It did not when this document was first written, and that asymmetry is the finding §8
  came of. A Swift measurement clears it once before the warm-up; unlike the Python one it needs no
  clear between reps, because the Swift phases call `LenientJSON.parse` and `readProject` directly
  and never reach the cache at all.
- **`project_files/captures/` is gitignored**, so a worktree or CI sees only the six tracked
  samples. The bench measures what it finds and names on stderr anything it skipped; an absent
  sample is never a failure.

## 2. The machine, and why the configuration is on the label

| | |
|---|---|
| Machine | Apple silicon (arm64), 2026-09-03 |
| OS | macOS 26.6.2 (build 25G83), `Darwin 25.6.0 arm64` |
| Python | CPython 3.13.14, `orjson` 3.11.9 (from `uv.lock`) |
| Swift | Apple Swift 6.2.3 (`swiftlang-6.2.3.3.21`, `clang-1700.6.3.2`), Command Line Tools |
| Swift configuration | **debug** in §3 — the one `port_parity.sh` and its two siblings build |
| Samples | the six tracked `project_files/*.KeyStepPro`, 3.518–3.523 MB each |
| Reps | 5 timed, after one discarded warm-up; min and median of each phase |

**The configuration is load-bearing and the tables say which.** The parity scripts and CI build
debug, but the app ships release, where our own code is several times faster. A debug number is not
a release number, and §3.2 gives both rather than picking one. It matters more since #239 than it
did before: `JSONDecoder` came prebuilt and optimised whatever configuration called it, whereas a
scan written here is compiled the way the rest of the package is.

Every figure is wall clock on a laptop. **The tables below give the min of five reps**, because
that is the reproducible one: mins repeat to within ~2 %, while a whole run's medians sit up to
10 % higher or lower depending on what else the machine was doing. Both are in the JSON, and the
median is the one a person actually waits on — it runs 1–3 % above the min in Python and 1–5 %
above it in Swift. **Two significant figures is all any of this supports**: quote 23 ms, not
22.67 ms.

## 3. The numbers

### 3.1 Both cores, all six samples, debug

Milliseconds, from one `./scripts/bench_read.sh` run. Phases and **total** are mins; the last two
columns show what that run's median total and repeated-`load` figure were beside them.

**The Python rows are the 2026-09-03 run and the Swift rows the 2026-09-05 one**, that core having
changed under #239 and this one not. Two runs, as §6 requires: the second Swift run put every
figure within 1 % of the one tabled here.

| file | core | bytes | json | decode | **total** | median total | repeat |
|---|---|---:|---:|---:|---:|---:|---:|
| `Default` | python | 0.30 | 7.6 | 14.5 | **22.5** | 22.7 | 0.000050 |
| | swift | 0.31 | 51.7 | 26.6 | **79.3** | 80.4 | 0.0070 |
| `baseline` | python | 0.29 | 7.7 | 14.4 | **22.4** | 23.0 | 0.000048 |
| | swift | 0.30 | 52.0 | 25.7 | **78.2** | 78.9 | 0.0051 |
| `initial_project` | python | 0.29 | 7.7 | 14.9 | **22.9** | 24.1 | 0.000050 |
| | swift | 0.32 | 52.2 | 27.9 | **80.5** | 81.7 | 0.0055 |
| `project_5` | python | 0.29 | 7.7 | 14.6 | **22.7** | 22.8 | 0.000048 |
| | swift | 0.30 | 52.0 | 25.8 | **78.2** | 78.8 | 0.0051 |
| `project_9` | python | 0.30 | 7.6 | 14.5 | **22.8** | 23.1 | 0.000048 |
| | swift | 0.29 | 52.2 | 25.6 | **78.5** | 79.2 | 0.0063 |
| `user_empty_project` | python | 0.29 | 7.4 | 13.9 | **21.7** | 22.4 | 0.000050 |
| | swift | 0.31 | 51.5 | 25.4 | **77.8** | 78.6 | 0.0060 |

The six samples land within a few percent of each other in both cores, and the spread that is
there does not track the file — `project_5` is fastest in Swift on this run and mid-pack on the
next. That is the format doing what it does: every `.KeyStepPro` file carries the same 153,497
keys whatever is recorded in them (§6). **One sample is the corpus, for this purpose.**

### 3.2 `project_5`, the two Swift configurations

Mins. The release row is the same measurement with `-c release`; the `before #239` rows are the
original `JSONDecoder` figures, kept because §4 and §8 are written against them.

| core | bytes | json | decode | **total** |
|---|---:|---:|---:|---:|
| Python (CPython 3.13) | 0.29 | 7.7 | 14.6 | **22.7** |
| Swift, release | 0.23 | 6.6 | 6.3 | **13.3** |
| Swift, debug | 0.30 | 52.0 | 25.8 | **78.2** |
| Swift, release, before #239 | 0.46 | 59.2 | 7.2 | **67.2** |
| Swift, debug, before #239 | 0.46 | 80.0 | 26.1 | **107.1** |

Release is the app's number; debug is the parity scripts' and CI's. **A whole Swift read is now
13 ms against Python's 23 ms**, where before #239 it was 67 ms.

## 4. Where the cost goes

As a share of the total read:

| | bytes | json | decode |
|---|---:|---:|---:|
| Python | 1.3 % | 34 % | 64 % |
| Swift, debug | 0.4 % | 66 % | 33 % |
| Swift, release | 1.7 % | 50 % | 47 % |

**Getting the bytes off disk is free in both cores** — under half a millisecond for 3.5 MB, and
that is out of the page cache, not off the platter (§6). Everything that matters happens after.

**The interesting comparison is the three parsers over a flat dict of 153,495 numeric keys** (the
count `pyproject.toml` records for the shipped template; plus `device` and, in user saves,
`version`, so 153,497 entries in all):

| | ms | keys per second |
|---|---:|---:|
| `orjson` | 7.7 | 20 M |
| `JSONScanner`, release | 6.6 | 23 M |
| `JSONScanner`, debug | 52.0 | 3.0 M |
| `JSONDecoder`, release, before #239 | 59.2 | 2.6 M |
| `JSONDecoder`, debug, before #239 | 80.0 | 1.9 M |

**This is the finding that moved.** When this document was first written `JSONDecoder` was 88 % of
a Swift read and 7.7× slower than `orjson`, and the gap did not close with optimisation, because
it was not our code: `Foundation` ships prebuilt, so release bought 1.4× on the parse against 3.6×
on the decode. That paragraph named the one place worth optimising, #239 optimised it, and the
sentence no longer holds.

What replaced it reads the same file at **23 M keys/sec in release, marginally ahead of `orjson`**
— unsurprising for a scan that knows the shape it is walking (spec 2: one flat object, integers
under every key but two) against a general JSON parser that cannot assume it. **No phase dominates
a Swift read any more**: half the parse, half the decode, and 13 ms in total.

**The configuration split changed sign, and this is the trap.** `JSONDecoder` was prebuilt, so a
debug build barely slowed it down; `JSONScanner` is ours, so debug costs it 7.9×. It is still
1.5× faster than `JSONDecoder` was in debug — the first draft of the scan was *slower* than
`JSONDecoder` there, and indexing a raw pointer rather than a bounds-checked `UnsafeBufferPointer`
is what bought that back. Anyone rewriting this loop should measure both configurations, because
CI and all three parity gates only ever run the debug one.

**The two cores are no longer far apart.** Our own decode is 2.3× faster in Swift release than in
Python (6.3 ms against 14.6 ms), and now that the parse is no longer a handicap the Swift core is
**1.7× faster end to end** (13.3 ms against 22.7 ms) where it used to be 3.0× slower.

## 5. What it holds: bytes per byte of file

This is D1's "byte-efficient and non-duplicative" half, answered with a number.
`tracemalloc` on `project_5` (3,518,401 bytes), each figure as a ratio to the file's size on disk:

| point in the read | held | of which |
|---|---:|---|
| the file's bytes in memory | 1.00× | |
| after the parse | 4.88× | the bytes, plus the raw dict at 3.88× |
| after the decode | 4.89× | the above, plus the model |
| **the decoded `Project` alone**, bytes and raw dict dropped | **0.04×** | 0.27× on a process's *first* read |
| **high-water mark across the whole read** | **17.88×** | all of it inside `orjson.loads` |

**The model is a twenty-fifth of the file it came from.** Nothing is duplicated into it: 153,497
keys and their integers become four `Track`s of decoded patterns and notes, 145 KB against 3.52 MB
on disk. What the raw dict costs on the way there — 3.88×, about 89 bytes per entry — is CPython's
dict and `str` overhead over key strings of ten to fourteen characters, and it is dropped when
`load` returns.

**The first read in a process retains 0.27× rather than 0.04×, and the difference is not the
model.** It is `keys.key`, an `@lru_cache(maxsize=4096)` at `src/ksp/keys.py:17` that fills on the
first decode and is bounded there: ~790 KB, paid once per process, never again and never per
project. Quote 0.04× for what a project costs and 790 KB for what the module costs; a figure that
folds them together is one or the other misread.

**The 17.88× peak is transient and it is all inside `orjson.loads`.** Measured with
`tracemalloc.reset_peak()` around each phase, the parse peaks at 17.88× while settling at 4.88×,
and the decode never peaks above its own steady 4.89×. So the honest statement of the cost is:
*a 3.5 MB project needs ~63 MB of headroom for a fraction of a second and holds 145 KB
afterwards.*

Process peak, above each runtime's own floor (~26 MB for CPython, ~27 MB for the Swift test
runner in debug and ~22 MB in release), lands at 16.1–16.4× for Python and 17.9–18.1× for Swift
debug, 14.8× release. Those agree with the traced figure, but they are a cruder instrument: RSS
never comes back down, so a process peak is an upper bound and cannot be attributed to a phase.

**Verdict on D1.** Timely: 23 ms in Python, 13 ms in Swift release, for 3.5 MB. Byte-efficient and
non-duplicative: **0.04 bytes retained per byte of file**, and no representation outlives the call
that made it. Both met, with the 17.88× transient named above as the one figure a
memory-constrained caller has to budget for.

## 6. How this goes wrong

- **The corpus cannot vary the size.** `.KeyStepPro` is fixed-shape: all six samples are within
  6 KB of each other because every project carries all 153,497 keys whether or not a note is
  recorded in them. A project full of notes moves the decode a little and the parse not at all.
  These numbers therefore describe *the format*, not *a project*, and no larger file exists to
  extrapolate towards.
- **"bytes off disk" is bytes out of the page cache.** Every rep reads a file the warm-up just
  read. A genuinely cold read is a different measurement and this harness does not make it.
- **The `lru_cache` hit is timed in a batch of 1,000** — one hit is 48 ns, below
  `perf_counter`'s resolution. Swift's repeat column is still a single call: a `ReadCache` hit is
  ~5 µs, three orders of magnitude above `ContinuousClock`'s resolution, so it needs no batching.
  Both columns now measure a cache hit, but only one of them measures it usefully — the Swift
  figure carries a dictionary lookup's worth of noise the Python one has averaged away.
- **The Swift figures carry the test runner's process with them.** The RSS floor is subtracted,
  but a suite host is not an app.
- **The §5 decomposition has no Swift counterpart.** The Swift measurement had only `task_info`'s
  resident-size high-water mark, which cannot be attributed to a phase or read back down, so there
  is no Swift figure for what the decoded `Project` holds. Everything in §5 is the Python core, and
  the §5 and §8 memory figures predate #239 — the scan's allocation profile has not been measured.
- **`getrusage`'s `ru_maxrss` is bytes on Darwin and kilobytes elsewhere**; `tools/bench_read.py`
  scales for it, and nothing here has been run on Linux.
- **A busy machine moves a whole run, not one row.** Successive runs put every figure within a few
  percent of each other and the run as a whole up to 10 % apart — in one run `initial_project` sat
  10 % above its neighbours, in the next it was level with them. So a difference *between samples*
  in one run means nothing, and two runs is the minimum before quoting a number.
- **The Swift figures are not on a committed harness.** §7 says what took them. Nothing in CI
  re-takes them, so they go stale silently: a change to `JSONScanner` or `Reader` invalidates §3's
  Swift rows and nothing will say so.

## 7. Reproducing the findings

```sh
./scripts/bench_read.sh            # the Python core, six samples, one table
./scripts/bench_read.sh --json     # the same, plus the raw readings the tables were built from
```

The script loops the six tracked samples, invoking the Python harness once per file — a
peak-memory figure belongs to one file and must not bleed into the next. **§4's shares and §5's
decomposition are in the `--json` readings**, which the table has no room for; §3's tables are the
mins and medians of the same lines. One file alone:

```sh
uv run python tools/bench_read.py project_files/project_5.KeyStepPro
uv run python tools/bench_read.py --json --reps 9 project_files/baseline.KeyStepPro
```

**The Swift half is not committed.** `swift/Tests/KSPKitTests/ReadCostTests.swift` was deleted
before #239, and rather than restore a benchmark nothing runs, §3's Swift rows were taken with a
throwaway `@Suite` under `swift/Tests/KSPKitTests/`, gated on an environment variable and removed
again. It is three phases and a clock, and rebuilding it is a few minutes:

```swift
Reader.clearCache()                                  // #238's cache, or rep two measures it
let start = ContinuousClock.now
let data = try Data(contentsOf: url)                 // bytes
let raw = try LenientJSON.parse(data)                // json
let project = try Reader.readProject(raw, sourceName: name)   // decode
```

Six reps per sample, the first discarded, mins reported; `swift test` for the debug row and
`swift test -c release` for the release one, both carrying the Command Line Tools flags
`validate.sh` builds (swift/README.md §6). §6 records what that leaves unmeasured.

§5's one figure that is *not* in a reading is the 0.27× first read, because the harness measures
memory after its timing reps and by then `keys.key` is warm. To see it, call
`tools.bench_read.traced_memory` as the first thing a fresh interpreter does.

## 8. What came of this: #238

**[#238](https://github.com/bauerc/KeystepProTool/issues/238) — the dropped project was parsed
once per reader. Fixed.**

Four call sites read the same dropped file, and each was a full re-parse:

| call site | when it fired |
|---|---|
| `SummaryRunner.run` — `swift/Sources/KSPRun/SummaryRunner.swift:29` | on drop, for the preview grid |
| `ArrangementRunner.run` — `swift/Sources/KSPRun/ArrangementRunner.swift:42` | on drop, and again on **every settings change** |
| `ExportRunner.run` — `swift/Sources/KSPRun/ExportRunner.swift:103` | the dry-run preview, then the real convert |
| `DumpRunner.run` — `swift/Sources/KSPRun/DumpRunner.swift:48` | `dump`, once per process |

Nothing carried the parsed `Project` between them: `Conversion.summarise`, `Conversion.arrange`
and `Conversion.run` are separate detached tasks. At §3.2's release figure a drop followed by a
convert paid ~67 ms four times over. The arrangement re-parse was the worst of them and is not in
the issue as filed — `AppModel.arrangementKey` is keyed on the whole of `Settings`, so every tick
and every slider in the options panel bought another 67 ms parse of 3.5 MB.

The fix is `ReadCache` (`swift/Sources/KSPKit/ReadCache.swift`), a sixteen-entry LRU of decoded
`Project`s behind `Reader.load`, so all four sites share one parse without an API change.
Parsing happens outside the lock: two callers racing the same cold path both parse, as they both
did before, and every read after that hits.

**The measured result, `project_5`, mins of five reps: a repeat read falls from a full re-parse to
a dictionary lookup.** The first two columns are the pre-#238 measurement of §3.2 and of the issue;
the third is this change.

| configuration | one full read | a second `load` of the same path — before | after |
|---|---:|---:|---:|
| Swift, release | 67 ms | 68 ms | **0.0025 ms** |
| Swift, debug | 107 ms | 109 ms | **0.0048 ms** |

What the cache does *not* do is make the model cheaper to hold, and **what it retains is not
measured in the core that retains it.** A full cache holds sixteen decoded projects for the life of
the process. §5's 145 KB per project is the Python figure, and §6 is explicit that it has no Swift
counterpart — so read ~2.3 MB as the order of magnitude it implies, not as a Swift measurement.
Either way it sits against the 63 MB of transient headroom one parse already needs.

**No invalidation.** The cache is keyed on the path and never checks whether the file moved
underneath it. Nothing edits a project mid-session, so a `stat` on every read would buy nothing.
A process that did rewrite a file it had already read would have to call `Reader.clearCache()`.

## 9. What came of this: #239

**[#239](https://github.com/bauerc/KeystepProTool/issues/239) — `JSONDecoder` was 88 % of a Swift
read. Replaced.**

§4 named the parse as the one place worth optimising and put a target on it: 59 ms → 10–20 ms, or
close the issue unfixed. `LenientJSON.parse` now walks the bytes itself
(`swift/Sources/KSPKit/JSONScanner.swift`); the signature, `RawProject` and everything above the
seam are unchanged, and `KSPKit` gained no dependency.

The scan can be direct because the format is (spec 2): one flat object, `\t"<key>": <value>,\n` per
entry, exactly two string values, an integer everywhere else, one trailing comma before the closing
brace. It still accepts general JSON for the object it is handed — a nested array or object is
walked to its end and keeps only its type name, as `RawProject` has always recorded it.

**`project_5`, mins of five reps:**

| configuration | json, before | json, after | whole read, before | whole read, after |
|---|---:|---:|---:|---:|
| Swift, release | 59.2 ms | **6.6 ms** | 67.2 ms | **13.3 ms** |
| Swift, debug | 80.0 ms | **52.0 ms** | 107.1 ms | **78.2 ms** |

Release beat the target; the whole read is 13 ms against the 20–27 ms the issue hoped for, and
M15's twenty-file import drops from ~1.3 s of parsing to ~0.13 s.

**Two things worth knowing before touching this loop again.**

- **Debug is where it nearly went wrong.** The first draft indexed a bounds-checked
  `UnsafeBufferPointer` and ran 120 ms in debug — *slower* than the `JSONDecoder` it replaced,
  which as prebuilt `Foundation` never loses its optimisation. A raw `UnsafePointer` took that to
  52 ms. Release would have hidden it: CI and all three parity gates build debug.
- **`UInt8(ascii:)` costs nothing**, measured, and it is what the scan uses. It is `@inlinable`,
  which does nothing at `-Onone`, so a table of named byte constants looked like the faster
  spelling; the two were 52.3 ms and 54.5 ms, inside run-to-run noise.

**Malformed input is reported differently, and better.** `JSONDecoder` returned one sentence for
every kind of damage — `could not parse: The given data was not valid JSON.` — with no position.
The scan says what it wanted and where: `could not parse: expected : after the key "device" at
byte 12`. The `expected a JSON object, got <type>` line is untouched, that one being the only
wording the two cores share; Python's malformed-input text is `orjson`'s and has never matched
Swift's.

Four inputs that `JSONDecoder` mis-reported are now parse failures rather than a value of the wrong
type. `Document.value` tried `Int`, then `String`, then `Bool`, `Double`, `nil` and an unkeyed
container, and fell through to `.other("dict")` — so `{"a": "x\q"}`, a raw newline inside a string,
`{"a": 01}` and `{"a": -}` all read as *a key holding a dict*, which the reader then complained
about as a type error. They are malformed JSON and now say so.

Three edge cases moved toward the Python reference, none of them reachable from a `.KeyStepPro`
file: a repeated key keeps its **last** value (Python's dict semantics; `JSONDecoder` kept the
first), `1e3` is a **float** rather than `.int(1000)`, and an integer too large for `Int` stays a
float, as it already was. The rule is now one sentence — a number no `Int` holds is a float.
