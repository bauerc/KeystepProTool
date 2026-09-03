# Read Cost: What Parsing a Project Costs

**Status:** **complete.** Measured 2026-09-03 on both cores by
[`./scripts/bench_read.sh`](../scripts/bench_read.sh).
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

The measurement changed nothing under `src/`, `swift/Sources/` or the parity scripts. It did name
a defect, and §8 is the record of that being fixed.

## 1. The model: three phases

A read is the same three phases in both cores, which is what makes them comparable:

| Phase | Python | Swift |
|---|---|---|
| bytes off disk | `Path.read_bytes()` | `Data(contentsOf:)` |
| lenient JSON parse | `lenient_json.loads` → `strip_trailing_comma_fast` + `orjson.loads` | `LenientJSON.parse` → `strippingTrailingComma` + `JSONDecoder` |
| decode to model | `reader.read_project(raw)` | `Reader.readProject(raw)` |

Three facts about the subject bind the harness:

- **`src/ksp/reader.py:25` — `load` is `@lru_cache(maxsize=16)`.** A repeat measurement in one
  process measures the cache, not the parser, so the harness calls `cache_clear()` between reps
  and reports the cached call separately as its own figure.
- **Swift's `Reader.load` has the same cache since #238** — `ReadCache`, sixteen entries, keyed on
  the path. It did not when this document was first written, and that asymmetry is the finding §8
  came of. Its harness clears it once before the warm-up; unlike the Python one it needs no clear
  between reps, because the Swift phases call `LenientJSON.parse` and `readProject` directly and
  never reach the cache at all.
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

**The configuration is load-bearing and the tables say which.** The parity scripts build debug and
so does `./scripts/bench_read.sh`, but the app ships release, where the decode is 3.6× faster.
A debug number is not a release number, and §3.2 gives both rather than picking one.

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

**The Swift `repeat` column is from a later run**, after #238 gave `Reader.load` its cache; every
other figure is the original one. The two runs put the Swift totals within 5 % of each other, and
§3.2's release row already mixes runs this way. Before #238 the column read 109–119 ms — a full
re-parse, which is the whole of what #238 removed. Two runs, as §6 requires: a single-file run put
`project_5` at 0.0061 ms against the 0.0055 ms tabled here, which for a four-orders-of-magnitude
change is agreement.

| file | core | bytes | json | decode | **total** | median total | repeat |
|---|---|---:|---:|---:|---:|---:|---:|
| `Default` | python | 0.30 | 7.6 | 14.5 | **22.5** | 22.7 | 0.000050 |
| | swift | 0.44 | 82.8 | 26.1 | **109.8** | 110.3 | 0.0062 |
| `baseline` | python | 0.29 | 7.7 | 14.4 | **22.4** | 23.0 | 0.000048 |
| | swift | 0.44 | 87.3 | 25.7 | **113.5** | 114.4 | 0.0055 |
| `initial_project` | python | 0.29 | 7.7 | 14.9 | **22.9** | 24.1 | 0.000050 |
| | swift | 0.44 | 83.7 | 29.0 | **113.8** | 114.7 | 0.0064 |
| `project_5` | python | 0.29 | 7.7 | 14.6 | **22.7** | 22.8 | 0.000048 |
| | swift | 0.46 | 80.0 | 26.1 | **107.1** | 108.9 | 0.0055 |
| `project_9` | python | 0.30 | 7.6 | 14.5 | **22.8** | 23.1 | 0.000048 |
| | swift | 0.47 | 89.1 | 26.0 | **115.6** | 116.7 | 0.0059 |
| `user_empty_project` | python | 0.29 | 7.4 | 13.9 | **21.7** | 22.4 | 0.000050 |
| | swift | 0.42 | 88.2 | 25.7 | **114.7** | 117.3 | 0.0081 |

The six samples land within a few percent of each other in both cores, and the spread that is
there does not track the file — `project_5` is fastest in Swift on this run and mid-pack on the
next. That is the format doing what it does: every `.KeyStepPro` file carries the same 153,497
keys whatever is recorded in them (§6). **One sample is the corpus, for this purpose.**

### 3.2 `project_5`, the two Swift configurations

Mins, same run for the two Python and debug rows; the release row comes from the same command with
`-c release`.

| core | bytes | json | decode | **total** |
|---|---:|---:|---:|---:|
| Python (CPython 3.13) | 0.29 | 7.7 | 14.6 | **22.7** |
| Swift, release | 0.46 | 59.2 | 7.2 | **67.2** |
| Swift, debug | 0.46 | 80.0 | 26.1 | **107.1** |

Release is the app's number; debug is the parity scripts' and CI's.

## 4. Where the cost goes

As a share of the total read:

| | bytes | json | decode |
|---|---:|---:|---:|
| Python | 1.3 % | 34 % | 64 % |
| Swift, debug | 0.4 % | 75 % | 24 % |
| Swift, release | 0.7 % | 88 % | 11 % |

**Getting the bytes off disk is free in both cores** — under half a millisecond for 3.5 MB, and
that is out of the page cache, not off the platter (§6). Everything that matters happens after.

**The interesting comparison is `orjson` against `JSONDecoder` over a flat dict of 153,495
numeric keys** (the count `pyproject.toml` records for the shipped template; plus `device` and
`version`, so 153,497 entries in all):

| | ms | keys per second |
|---|---:|---:|
| `orjson` | 7.7 | 20 M |
| `JSONDecoder`, release | 59.2 | 2.6 M |
| `JSONDecoder`, debug | 80.0 | 1.9 M |

`JSONDecoder` is **7.7× slower than `orjson` even in release**, and the gap does not close with
optimisation because it is not the package's code: `Foundation` ships prebuilt, so the release
build wins only 1.4× there against 3.6× on the decode, which is ours.

That single fact inverts the two cores. Our own decode is **2.0× faster in Swift release than in
Python** (7.2 ms against 14.6 ms) — the port did its job — and yet **the Swift core is 3.0× slower
end to end**, entirely on the JSON parse. Anyone reaching for a faster read should reach there and
nowhere else.

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

**Verdict on D1.** Timely: 23 ms in Python, 67 ms in Swift release, for 3.5 MB. Byte-efficient and
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
- **The §5 decomposition has no Swift counterpart.** The Swift harness has only `task_info`'s
  resident-size high-water mark, which cannot be attributed to a phase or read back down, so there
  is no Swift figure for what the decoded `Project` holds. Everything in §5 is the Python core.
- **`getrusage`'s `ru_maxrss` is bytes on Darwin and kilobytes elsewhere**; `tools/bench_read.py`
  scales for it, and nothing here has been run on Linux.
- **A busy machine moves a whole run, not one row.** Successive `./scripts/bench_read.sh` runs put
  every Swift figure within a few percent of each other and the run as a whole up to 10 % apart —
  in one run `initial_project` sat 10 % above its neighbours, in the next it was level with them.
  So a difference *between samples* in one run means nothing, and two runs is the minimum before
  quoting a number.

## 7. Reproducing the findings

```sh
./scripts/bench_read.sh            # both cores, six samples, one table
./scripts/bench_read.sh --json     # the same, plus the raw readings the tables were built from
```

The script loops the six tracked samples, invoking the Python harness once per file — a
peak-memory figure belongs to one file and must not bleed into the next — and the Swift suite once
per file beside it, carrying the Command Line Tools flags `validate.sh` builds. **§4's shares and
§5's decomposition are in the `--json` readings**, which the table has no room for; §3's tables
are the mins and medians of the same lines. Either half runs alone:

```sh
uv run python tools/bench_read.py project_files/project_5.KeyStepPro
uv run python tools/bench_read.py --json --reps 9 project_files/baseline.KeyStepPro

cd swift && KSP_BENCH=1 KSP_BENCH_FILE=project_5.KeyStepPro \
    swift test --filter ReadCost          # add validate.sh's CLT flags
```

§5's one figure that is *not* in a reading is the 0.27× first read, because the harness measures
memory after its timing reps and by then `keys.key` is warm. To see it, call
`tools.bench_read.traced_memory` as the first thing a fresh interpreter does.

`swift/Tests/KSPKitTests/ReadCostTests.swift` is `.disabled(if:)` on `KSP_BENCH` being unset, so
`swift test` and `./scripts/validate.sh` skip it and CI time is untouched. It still asserts that
the decoded project has four tracks — a real test that happens to time itself. §3.2's release row
comes from adding `-c release` to that command.

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
