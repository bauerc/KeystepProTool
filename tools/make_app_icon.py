"""Draw the app icon and pack it into an ``.icns``.

Run by scripts/bundle_app.sh; stdlib only, so bundling needs no virtualenv.
"""

import struct
import subprocess
import sys
import zlib
from math import sqrt
from pathlib import Path
from tempfile import TemporaryDirectory

Rgb = tuple[int, int, int]

#: The matte black control band, DesignTokens.swift ``Face.standard.band``.
BAND: Rgb = (0x0D, 0x0D, 0x0D)
#: Manual 2.5.2 §1.4, in track order; DesignTokens.swift ``DeviceColor.track``.
TRACKS: list[Rgb] = [(0x01, 0xA9, 0x86), (0xFB, 0x5C, 0x26), (0xFA, 0xCC, 0x00), (0xE0, 0x00, 0x2E)]

#: Steps held by each track, in track order -- the device's 64 / 32 / 48 / 32 pattern lengths.
STEPS = [4, 2, 3, 2]
COLUMNS = 4

# Proportions of the 1024 grid. The body is Apple's rounded square, inset for the shadow the
# system draws around it; everything else is a fraction of the square it sits in.
BODY_INSET = 100.0
BODY_RADIUS = 185.4
CONTENT_INSET = 112.0
ROW_PITCH = 5.26  # four rows and three gaps, in units of one row's height
GAP_RATIO = 0.42
STEP_GAP_RATIO = 0.24
STEP_RADIUS_RATIO = 0.28

#: Below this the steps are drawn merged: a 4 px cell either aliases or closes its own gaps.
SEGMENTED_FROM = 64

#: ``iconutil`` reads these names and nothing else.
LADDER = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


class Canvas:
    """A square RGBA bitmap that draws rounded rectangles and emits a PNG."""

    def __init__(self, size: int) -> None:
        self.size = size
        self.pixels = bytearray(size * size * 4)

    def round_rect(self, x0: float, y0: float, x1: float, y1: float, r: float, rgb: Rgb) -> None:
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        half_w, half_h = (x1 - x0) / 2, (y1 - y0) / 2
        r = min(r, half_w, half_h)
        for y in range(max(0, int(y0) - 1), min(self.size, int(y1) + 2)):
            qy = max(abs(y + 0.5 - cy) - (half_h - r), 0.0)
            for x in range(max(0, int(x0) - 1), min(self.size, int(x1) + 2)):
                qx = max(abs(x + 0.5 - cx) - (half_w - r), 0.0)
                coverage = min(max(0.5 - (sqrt(qx * qx + qy * qy) - r), 0.0), 1.0)
                if coverage > 0:
                    self._blend(x, y, rgb, coverage)

    def _blend(self, x: int, y: int, rgb: Rgb, alpha: float) -> None:
        i = (y * self.size + x) * 4
        dst_alpha = self.pixels[i + 3] / 255
        out_alpha = alpha + dst_alpha * (1 - alpha)
        for channel in range(3):
            src = rgb[channel] * alpha
            dst = self.pixels[i + channel] * dst_alpha * (1 - alpha)
            self.pixels[i + channel] = round((src + dst) / out_alpha)
        self.pixels[i + 3] = round(out_alpha * 255)

    def png(self) -> bytes:
        stride = self.size * 4
        raw = bytearray()
        for y in range(self.size):
            raw.append(0)  # filter type: none
            raw += self.pixels[y * stride : (y + 1) * stride]
        header = struct.pack(">IIBBBBB", self.size, self.size, 8, 6, 0, 0, 0)
        return b"".join(
            [
                b"\x89PNG\r\n\x1a\n",
                _chunk(b"IHDR", header),
                _chunk(b"IDAT", zlib.compress(bytes(raw), 9)),
                _chunk(b"IEND", b""),
            ]
        )


def _chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def render(size: int) -> bytes:
    """The pattern map in miniature: four rows of steps in the four track colours."""
    scale = size / 1024
    canvas = Canvas(size)
    body0, body1 = BODY_INSET * scale, (1024 - BODY_INSET) * scale
    canvas.round_rect(body0, body0, body1, body1, BODY_RADIUS * scale, BAND)

    left, right = body0 + CONTENT_INSET * scale, body1 - CONTENT_INSET * scale
    top, bottom = left, right
    row_height = (bottom - top) / ROW_PITCH
    row_gap = row_height * GAP_RATIO
    step_gap = row_height * STEP_GAP_RATIO
    step_radius = row_height * STEP_RADIUS_RATIO
    step_width = ((right - left) - (COLUMNS - 1) * step_gap) / COLUMNS

    for track, steps in enumerate(STEPS):
        y0 = top + track * (row_height + row_gap)
        y1 = y0 + row_height
        if size < SEGMENTED_FROM:
            width = steps * step_width + (steps - 1) * step_gap
            canvas.round_rect(left, y0, left + width, y1, step_radius, TRACKS[track])
            continue
        for step in range(steps):
            x0 = left + step * (step_width + step_gap)
            canvas.round_rect(x0, y0, x0 + step_width, y1, step_radius, TRACKS[track])
    return canvas.png()


def write_icns(destination: Path) -> None:
    with TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        drawn: dict[int, bytes] = {}
        for name, size in LADDER:
            if size not in drawn:
                drawn[size] = render(size)
            (iconset / name).write_bytes(drawn[size])
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["iconutil", "--convert", "icns", "--output", str(destination), str(iconset)],
            check=True,
        )


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <output.icns>", file=sys.stderr)
        return 2
    write_icns(Path(sys.argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
