"""Measure what reading a ``.KeyStepPro`` project costs, phase by phase.

Evidence for requirement D1 -- "a parser that reads them in a timely,
byte-efficient and non-duplicative manner". Times the bytes off disk, the
lenient JSON parse and the decode to the model separately, and reports peak
memory as a ratio to the file's own size on disk.

    uv run python tools/bench_read.py project_files/project_5.KeyStepPro
    uv run python tools/bench_read.py --json --reps 9 project_files/baseline.KeyStepPro
    uv run python tools/bench_read.py --render < readings.jsonl

In ``tools/`` rather than ``src/``: a dev instrument, not a shipped command.
"""

from __future__ import annotations

import argparse
import json
import platform
import resource
import statistics
import sys
import time
import tracemalloc
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Allow running from a source checkout without installing the package.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from ksp import lenient_json, reader

# ru_maxrss is bytes on Darwin and kilobytes everywhere else.
RSS_UNIT = 1 if sys.platform == "darwin" else 1024

TRACKS_PER_PROJECT = 4

# One `lru_cache` hit is below `perf_counter`'s resolution, so it is timed in a batch.
REPEAT_CALLS = 1000

# Column key -> heading, in the order the table prints them.
COLUMNS = {
    "read_bytes_s": "bytes",
    "parse_json_s": "json",
    "decode_s": "decode",
    "total_s": "total",
    "repeat_load_s": "repeat",
}


@dataclass(frozen=True)
class Rep:
    """One uncached read, phase by phase, plus a second ``load`` of the same path."""

    read_bytes_s: float
    parse_json_s: float
    decode_s: float
    repeat_load_s: float

    @property
    def total_s(self) -> float:
        return self.read_bytes_s + self.parse_json_s + self.decode_s


def one_rep(path: Path) -> Rep:
    """Time one read with the ``lru_cache`` cleared, then one repeat that hits it."""
    reader.load.cache_clear()

    start = time.perf_counter()
    data = path.read_bytes()
    after_bytes = time.perf_counter()
    raw = lenient_json.loads(data)
    after_json = time.perf_counter()
    project = reader.read_project(raw, source_name=path.name)
    after_decode = time.perf_counter()

    repeated = reader.load(path)
    before_repeat = time.perf_counter()
    for _ in range(REPEAT_CALLS):
        reader.load(path)
    after_repeat = time.perf_counter()
    if repeated.device != project.device:
        raise RuntimeError(f"{path.name}: the repeated load disagrees with the decoded project")

    return Rep(
        read_bytes_s=after_bytes - start,
        parse_json_s=after_json - after_bytes,
        decode_s=after_decode - after_json,
        repeat_load_s=(after_repeat - before_repeat) / REPEAT_CALLS,
    )


def traced_memory(path: Path) -> dict[str, int]:
    """What one read holds and where its high-water mark falls, by ``tracemalloc``.
    Runs after the reps, so the model figure excludes ``keys.key``'s one-off 4096-entry cache."""
    reader.load.cache_clear()
    tracemalloc.start()
    try:
        data = path.read_bytes()
        held_bytes, _ = tracemalloc.get_traced_memory()

        tracemalloc.reset_peak()
        raw = lenient_json.loads(data)
        held_raw, parse_peak = tracemalloc.get_traced_memory()

        tracemalloc.reset_peak()
        project = reader.read_project(raw, source_name=path.name)
        held_decoded, decode_peak = tracemalloc.get_traced_memory()

        del data, raw
        held_model, _ = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()

    if len(project.tracks) != TRACKS_PER_PROJECT:
        raise RuntimeError(f"{path.name}: decoded {len(project.tracks)} tracks, expected 4")

    return {
        "traced_peak_bytes": max(parse_peak, decode_peak),
        "traced_held_bytes_bytes": held_bytes,
        "traced_held_raw_bytes": held_raw,
        "traced_held_decoded_bytes": held_decoded,
        "traced_model_bytes": held_model,
    }


def rss_bytes() -> int:
    return int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss) * RSS_UNIT


def format_ms(seconds: float) -> str:
    """Milliseconds, kept to three significant figures down to the cache hit's 50 ns."""
    value = seconds * 1e3
    if value >= 1:
        return f"{value:.2f}"
    return f"{value:.4f}" if value >= 0.001 else f"{value:.6f}"


def spread(values: Sequence[float]) -> dict[str, float]:
    """Min is the honest floor; median is what a person waits on."""
    return {"min": min(values), "median": statistics.median(values)}


def measure(path: Path, reps: int, floor_bytes: int) -> dict[str, Any]:
    one_rep(path)  # discarded warm-up
    samples = [one_rep(path) for _ in range(reps)]
    traced = traced_memory(path)
    size = path.stat().st_size
    peak = rss_bytes()

    reading: dict[str, Any] = {
        "core": "python",
        "file": path.name,
        "size_bytes": size,
        "reps": reps,
    }
    for key in COLUMNS:
        reading[key] = spread([float(getattr(sample, key)) for sample in samples])
    reading |= traced
    reading |= {
        "traced_ratio": traced["traced_peak_bytes"] / size,
        "traced_model_ratio": traced["traced_model_bytes"] / size,
        "rss_peak_bytes": peak,
        "rss_ratio": (peak - floor_bytes) / size,
        "rss_floor_bytes": floor_bytes,
        "runtime": f"CPython {platform.python_version()}",
        "platform": f"{platform.system()} {platform.release()} {platform.machine()}",
    }
    return reading


def human(reading: dict[str, Any]) -> Iterator[str]:
    """One reading, one phase per line."""
    size = int(reading["size_bytes"])
    yield f"{reading['file']}  ({size / 1e6:.2f} MB, {reading['reps']} reps)"
    for key, heading in COLUMNS.items():
        figures = reading[key]
        yield (
            f"  {heading:<7} min {format_ms(figures['min']):>10} ms"
            f"   median {format_ms(figures['median']):>10} ms"
        )
    for label, key in (
        ("the file's bytes", "traced_held_bytes_bytes"),
        ("after the parse", "traced_held_raw_bytes"),
        ("after the decode", "traced_held_decoded_bytes"),
        ("the model alone", "traced_model_bytes"),
        ("high-water mark", "traced_peak_bytes"),
    ):
        held = int(reading[key])
        yield f"  {label:<17}{held / 1e6:8.2f} MB   = {held / size:6.2f} x the file"
    yield (
        f"  rss peak    {int(reading['rss_peak_bytes']) / 1e6:7.2f} MB"
        f"   = {reading['rss_ratio']:.2f} over a"
        f" {int(reading['rss_floor_bytes']) / 1e6:.2f} MB runtime floor"
    )


def render(readings: Sequence[dict[str, Any]]) -> Iterator[str]:
    """Both cores side by side, medians in milliseconds, one row per core per file."""
    head = "".join(f"{heading:>11}" for heading in COLUMNS.values())
    yield f"{'file':<28}{'size':>8}  {'core':<7}{head}{'held/byte':>11}{'rss/byte':>10}"
    yield "-" * (28 + 8 + 2 + 7 + len(head) + 21)

    seen: list[str] = []
    for name in [str(reading["file"]) for reading in readings]:
        if name not in seen:
            seen.append(name)

    for name in seen:
        first = True
        for reading in readings:
            if reading["file"] != name:
                continue
            size = int(reading["size_bytes"])
            label = f"{name:<28}{size / 1e6:7.2f}M" if first else " " * 36
            first = False
            times = "".join(f"{format_ms(reading[key]['median']):>11}" for key in COLUMNS)
            traced = reading.get("traced_ratio")
            traced_cell = "--" if traced is None else f"{traced:.2f}"
            yield (
                f"{label}  {reading['core']!s:<7}{times}"
                f"{traced_cell:>11}{reading['rss_ratio']:>10.2f}"
            )
    yield ""
    yield "Times are medians in milliseconds. held/byte is the tracemalloc peak per byte of file;"
    yield "rss/byte is the process peak above the runtime floor, per byte of file."


def main(argv: list[str] | None = None) -> int:
    floor_bytes = rss_bytes()

    parser = argparse.ArgumentParser(
        description="Measure what reading one .KeyStepPro project costs, phase by phase.",
    )
    parser.add_argument("file", nargs="?", type=Path, help="one project file")
    parser.add_argument("--reps", type=int, default=5, help="timed reps after one warm-up")
    parser.add_argument("--json", action="store_true", help="one machine-readable line")
    parser.add_argument(
        "--render",
        action="store_true",
        help="read --json lines from stdin and print the combined table instead",
    )
    args = parser.parse_args(argv)

    if args.render:
        readings = [json.loads(line) for line in sys.stdin if line.strip()]
        for line in render(readings):
            print(line)
        return 0

    if args.file is None:
        parser.error("a project file is required without --render")
    if args.reps < 1:
        parser.error("--reps must be at least 1")

    reading = measure(args.file, args.reps, floor_bytes)
    if args.json:
        print(json.dumps(reading))
    else:
        for line in human(reading):
            print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
