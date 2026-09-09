"""The bundle icon, as far as it goes without iconutil."""

import struct
import sys
import zlib
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

import make_app_icon


def pixels(png: bytes) -> tuple[int, list[tuple[int, ...]]]:
    """A rendered icon as ``(size, [(r, g, b, a), ...])`` in row-major order."""
    pos, idat, size = 8, b"", 0
    while pos < len(png):
        length = struct.unpack(">I", png[pos : pos + 4])[0]
        tag, body = png[pos + 4 : pos + 8], png[pos + 8 : pos + 8 + length]
        if tag == b"IHDR":
            size = struct.unpack(">I", body[:4])[0]
        elif tag == b"IDAT":
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = size * 4
    out: list[tuple[int, ...]] = []
    for y in range(size):
        assert raw[y * (stride + 1)] == 0, "the writer emits unfiltered rows"
        row = raw[y * (stride + 1) + 1 : (y + 1) * (stride + 1)]
        out += [tuple(row[x : x + 4]) for x in range(0, stride, 4)]
    return size, out


def row_run(png: bytes, track: int) -> int:
    """How far the widest opaque run of ``track``'s hue reaches across the icon, in pixels."""
    size, grid = pixels(png)
    hue = make_app_icon.TRACKS[track]
    widest = 0
    for y in range(size):
        run = [x for x in range(size) if grid[y * size + x][:3] == (*hue,)]
        widest = max(widest, (max(run) - min(run) + 1) if run else 0)
    return widest


def test_the_ladder_is_complete() -> None:
    names = {name for name, _ in make_app_icon.LADDER}
    expected = {
        f"icon_{edge}x{edge}{suffix}.png"
        for edge in (16, 32, 128, 256, 512)
        for suffix in ("", "@2x")
    }
    assert names == expected


@pytest.mark.parametrize("size", [16, 32, 64, 128, 256, 512, 1024])
def test_every_track_survives_at_every_size(size: int) -> None:
    png = make_app_icon.render(size)
    for track in range(4):
        assert row_run(png, track) > 0, f"track {track + 1} vanishes at {size}px"


def test_the_rows_run_the_lengths_their_step_counts_ask_for() -> None:
    png = make_app_icon.render(512)
    runs = [row_run(png, track) for track in range(4)]
    order = sorted(range(4), key=lambda track: make_app_icon.STEPS[track])
    assert sorted(range(4), key=lambda track: runs[track]) == order


def test_the_ground_is_the_control_band() -> None:
    _, grid = pixels(make_app_icon.render(128))
    assert (*make_app_icon.BAND, 255) in grid


def test_the_corners_are_clear_of_the_rounded_square() -> None:
    size, grid = pixels(make_app_icon.render(128))
    for x, y in ((0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)):
        assert grid[y * size + x][3] == 0
