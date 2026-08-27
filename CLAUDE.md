# CLAUDE.md

Guidance for Claude Code working in this repository.

## Conventions

- **A comment exists only where the code cannot document itself.** Docstrings: two lines at most,
  none that restate the symbol name, no `Args:`/`Returns:`/`Raises:` — signatures are typed and
  mypy is strict. Port narration, history, refactoring notes, architecture prose, restatement of
  the line beneath and banner comments all go. Two exceptions: `src/ksp/constants.py` and
  `swift/Sources/KSPKit/Constants.swift`, where a bare `48` or `127` cannot self-document, so every
  value keeps a **one-line** comment with a spec pointer where one fits; and a genuine trap, one
  line, where behaviour reads as a bug a reader would otherwise "fix". Functional pragmas
  (`# type: ignore`, `# pragma: no cover`, `# noqa`) are directives, and are never touched.
- Serena's tools for symbol work — but after `EnterWorktree` Serena still writes to the main
  checkout, so use `Edit` inside a worktree.
- Send wide greps, corpus dumps and spec lookups to the subagents in `.claude/agents/`.
- On pull requests: read the comments and act on them, leave the replies to the User.
- A Claude plan file committed here is deleted by the task that implements it.

## What this is

Converts Standard MIDI files ↔ Arturia KeyStep Pro `.KeyStepPro` project files. MIDI Control
Center has no MIDI export for it, so `ksp2midi` is the only one that exists, and there is no render
to check against: **the hardware's live MIDI output is the sole ground truth.** Tests marked
`hardware` need the device and are deselected wherever automated — **green CI ≠ verified on
hardware.**

- [Format spec](analysis/KeyStepPro_Format_Spec.md) — **read it before touching format code.**
- [ROADMAP.md](ROADMAP.md) — milestones, status, release track. Issues are GitHub issues on
  `bauerc/KeystepProTool`, driven through `gh`; triage labels and skill conventions in
  [docs/agents/](docs/agents/).
- [CONTEXT.md](CONTEXT.md), [docs/adr/](docs/adr/) — domain model and decisions. **The device's
  vocabulary is canonical**: Arturia beats MCC beats the code, and
  [ADR 0001](docs/adr/0001-device-vocabulary-is-canonical.md) says why a rename is never its own PR.
- [swift/README.md](swift/README.md) — toolchain, the six targets, the app.
- [Timing calibration](analysis/Timing_Calibration.md), [hardware protocol](analysis/Hardware_Test_Protocol.md).

## Commands

`uv` toolchain, Python 3.13 (pinned in `.python-version`). Swift 6.2, Command Line Tools, no Xcode.

```sh
uv sync                          # from uv.lock; CI uses --locked, so commit lockfile changes
./scripts/validate.sh            # format, typecheck, tests, parity — both toolchains, and the Stop hook
uv run pytest -m "not hardware"  # as CI runs it
uv run ruff check . && uv run mypy
```

**Swift tests go through `./scripts/validate.sh`, never `swift test` directly** — it adds the three
flags a Command Line Tools install needs (swift/README.md §6). Re-run a confusing parity failure
with `KSP_PARITY_JOBS=1` first. Run `pre-commit install` **only from the main checkout**: worktrees
share `.git/hooks` and the generated hook hard-codes the installing `.venv`'s absolute path, so
installing from a worktree blocks commits repo-wide once that worktree is deleted.

## Architecture

`src/` layout, strict one-way dependency — the same logic must work behind a CLI, a frozen binary
and the Swift port, so the port stays a translation of pure functions:

- **`ksp/`** — pure format, model and MIDI logic. No `ksp_cli` import, no printing, no `sys.argv`,
  no deciding where files live.
- **`ksp_cli/`** — args, path resolution, terminal output. No format logic.

`swift/` mirrors that split across six targets, and two invariants bind an edit: **nothing may add
a dependency to `KSPKit`**, and **a command body goes in `KSPRun`**, never in `KSPSwiftCLI` or
`KSPApp`, because both faces must run the very same `convert`. See swift/README.md §5.

**The two CLIs' output is a byte-for-byte contract**, held by `port_parity.sh`, `writer_parity.sh`
and `midi_parity.sh` as validate.sh's last three steps. A diagnostic's wording, a key's position in
the JSON and a number's formatting are all load-bearing on both sides: change one, change the other
in the same commit, and **the Python is the reference implementation.** The exported `.mid` is the
one exception — mido writes running status and `swift-midi-file` does not, so it is compared as
parsed event streams; `.KeyStepPro` still gets a real `cmp`.

`ksp.midi_export` has three layers that must stay separate: `render_pattern` (pattern → tick data),
`arrange` (timeline placement), `build_midi_file` (the only `mido` caller). `ksp.midi_import`
mirrors it inverted — `read_clip` (the only `mido` caller) → `quantise` → `apply`. Tests assert on
`Rendering` and `Placement` data, never on parsed MIDI.

The CLI is Typer: each command is a function in its own module with a `register(app)` that mounts
it, so `ksp2midi ...` and `kspplus ksp2midi ...` are one command reached two ways — add a command
by writing `register`, never by declaring its options twice. Failure is `typer.Exit(code)`, and the
codes are load-bearing: **0 success, 1 file or format failure, 2 usage failure**. A console entry
point enters `pyproject.toml` only when its milestone lands.

## Repository data is not source

`project_files/*.KeyStepPro` and `analysis/*.txt` are excluded from pre-commit deliberately — never
reformat, re-indent, or add a final newline. The exports are M3's byte-identical baseline, and the
`.txt` files are transcribed from the hardware display and cannot be regenerated without the
device. `tests/test_format_invariants.py` fails loudly on such corruption; the fix is never in that
file.
