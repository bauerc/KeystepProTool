"""Reduce a Tier 8 recording into measured timing offsets.

Reads a ``.mid`` recorded from the KeyStep Pro's MIDI out (see
``analysis/Hardware_Test_Protocol.md`` tier 8) and reports, per test note, how
far it landed from the reference note on the same step.

Every figure is a *difference* between two channels recorded together, so
interface latency and clock drift cancel. Absolute onsets are never used.

    uv run python tools/reduce_timing.py capture.mid --ref-channel 3 --test-channel 2
"""

from __future__ import annotations

import argparse
import statistics
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path

import mido


@dataclass(frozen=True)
class Onset:
    tick: int
    pitch: int
    channel: int


@dataclass(frozen=True)
class Pairing:
    """One test onset matched to the reference onset it should coincide with."""

    reference_tick: int
    test_tick: int

    @property
    def offset_ticks(self) -> int:
        return self.test_tick - self.reference_tick


def read_onsets(path: Path) -> tuple[list[Onset], int, float]:
    """Return note-on onsets in absolute ticks, plus PPQ and tempo in BPM."""
    midi = mido.MidiFile(str(path))
    tempo = 500_000  # MIDI default, 120 BPM
    onsets: list[Onset] = []

    for track in midi.tracks:
        tick = 0
        for message in track:
            tick += message.time
            if message.type == "set_tempo":
                tempo = message.tempo
            # A note_on with velocity 0 is a note_off by convention.
            elif message.type == "note_on" and message.velocity > 0:
                onsets.append(Onset(tick=tick, pitch=message.note, channel=message.channel))

    onsets.sort(key=lambda o: o.tick)
    return onsets, midi.ticks_per_beat, mido.tempo2bpm(tempo)


def pair_onsets(
    onsets: Sequence[Onset], *, ref_channel: int, test_channel: int, window: int
) -> list[Pairing]:
    """Match each test onset to the nearest reference onset within *window* ticks.

    Nearest-match rather than index-match on purpose: if a note fails to sound
    (randomness, spec §6 of the calibration doc) the sequences desynchronise,
    and index-matching would silently pair the wrong notes.
    """
    references = [o.tick for o in onsets if o.channel == ref_channel]
    if not references:
        return []

    pairings: list[Pairing] = []
    for onset in onsets:
        if onset.channel != test_channel:
            continue
        nearest = min(references, key=lambda r: abs(onset.tick - r))
        if abs(onset.tick - nearest) <= window:
            pairings.append(Pairing(reference_tick=nearest, test_tick=onset.tick))
    return pairings


def report(pairings: Sequence[Pairing], *, ppq: int, bpm: float) -> Iterator[str]:
    """Yield the measured offset, with spread so jitter stays visible."""
    if not pairings:
        yield "no test notes paired with a reference note -- check the channel numbers"
        return

    offsets = [p.offset_ticks for p in pairings]
    ms_per_tick = 60_000.0 / (bpm * ppq)

    mean = statistics.fmean(offsets)
    spread = statistics.pstdev(offsets) if len(offsets) > 1 else 0.0

    yield f"pairs            {len(offsets)}"
    yield f"tempo            {bpm:g} BPM, {ppq} ticks/beat ({ms_per_tick:.4f} ms/tick)"
    yield f"offset (ticks)   mean {mean:+.2f}   sd {spread:.2f}   " + (
        f"min {min(offsets):+d}   max {max(offsets):+d}"
    )
    yield f"offset (ms)      mean {mean * ms_per_tick:+.2f}   sd {spread * ms_per_tick:.2f}"

    if spread > 1.0:
        yield ""
        yield (
            "spread exceeds one tick -- treat this as jitter, not a measurement. "
            "Check T7.8 (randomness) before trusting any figure here."
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Reduce a Tier 8 MIDI recording into measured timing offsets.",
    )
    parser.add_argument("recording", type=Path, help="the .mid exported from the DAW")
    parser.add_argument(
        "--ref-channel", type=int, default=3, help="0-based channel of the reference track"
    )
    parser.add_argument(
        "--test-channel", type=int, default=1, help="0-based channel of the track under test"
    )
    parser.add_argument(
        "--window",
        type=int,
        default=240,
        help="max ticks between a test note and its reference before they stop being a pair",
    )
    args = parser.parse_args(argv)

    onsets, ppq, bpm = read_onsets(args.recording)
    pairings = pair_onsets(
        onsets,
        ref_channel=args.ref_channel,
        test_channel=args.test_channel,
        window=args.window,
    )
    for line in report(pairings, ppq=ppq, bpm=bpm):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
