# KeystepProTool
A tool that aims to take Keystep Pro project files and transform them into midi files and vice versa

The `.KeyStepPro` format is decoded and hardware-validated — see
[`analysis/KeyStepPro_Format_Spec.md`](./analysis/KeyStepPro_Format_Spec.md). The staged build
plan is in [`ROADMAP.md`](./ROADMAP.md).

## Status

Milestone 1 of 9 is done: reading and inspecting project files. Converting to MIDI (M2) and from
MIDI (M5) is next.

## Install

Requires Python 3.13 and [uv](https://docs.astral.sh/uv/).

```sh
uv sync
```

## `ksp-dump`

Print what is actually in a project file, without opening MIDI Control Center:

```sh
uv run ksp-dump project_files/project_5.KeyStepPro
```

```
project_5.KeyStepPro
  device KeyStepPro   version 2.5.20
  tempo 120 BPM   swing 50%   scene 1

  Track 1 (item 123)
    Pattern 1  [drum]
      drum: 16 steps, swing 50%
        slot 1
          note  1  step  1  lane 0     vel 127  gate    1  shift -1  rand  80  seq 16,32
          note  2  step  5  lane 0     vel  50  gate    2  shift +1  rand  90  seq 48,64
  Track 3 (item 125)
    Pattern 1  [seq]
      seq: 16 steps, swing 50%
        slot 1
          note  1  step  1  C2 (48)    vel  60  gate    2  shift +1  rand  10  seq always
          ...
```

| Option | Effect |
|---|---|
| `--all` | Include patterns that hold no notes (all 16 always exist on disk) |
| `--track N` | Show only track 1–4 |
| `--pattern N` | Show only pattern 1–16 |
| `--json` | Emit the decoded model as JSON instead of a tree |

`seq` on a note line is the note's step skip — which of the four 16/32/48/64 sequences it plays
in.

A gate printed as `?(2)` means that encoding has not been measured on the hardware yet. Only six
gate values are confirmed, and the tool prints the raw number rather than guessing at the rest.
See M7 in the roadmap.

## Development

```sh
uv run pytest          # tests
uv run ruff check .    # lint
uv run mypy            # types
```

Tests marked `hardware` need a physical KeyStep Pro and are skipped in CI
(`uv run pytest -m "not hardware"`).
