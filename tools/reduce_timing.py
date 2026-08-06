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
) -> tuple[list[Pairing], int]:
    """Match each test onset to the nearest reference onset within *window* ticks.

    Returns the pairings and how many test onsets were refused as ambiguous.

    Nearest-match rather than index-match on purpose: if a note fails to sound
    (randomness, spec §6 of the calibration doc) the sequences desynchronise,
    and index-matching would silently pair the wrong notes.

    A displacement of half a step lands exactly between two reference notes,
    and picking either one turns a clean constant offset into a ±half-step
    split that reads as jitter. That is not a measurement, so it is refused
    rather than guessed -- it cost tier 8's R3 its reading once already.
    """
    references = [o.tick for o in onsets if o.channel == ref_channel]
    if not references:
        return [], 0

    pairings: list[Pairing] = []
    ambiguous = 0
    for onset in onsets:
        if onset.channel != test_channel:
            continue
        distances = sorted(references, key=lambda r: abs(onset.tick - r))
        nearest = distances[0]
        if abs(onset.tick - nearest) > window:
            continue
        runner_up = distances[1] if len(distances) > 1 else None
        if runner_up is not None and abs(onset.tick - nearest) == abs(onset.tick - runner_up):
            ambiguous += 1
            continue
        pairings.append(Pairing(reference_tick=nearest, test_tick=onset.tick))
    return pairings, ambiguous


def report(
    pairings: Sequence[Pairing], *, ppq: int, bpm: float, ambiguous: int = 0
) -> Iterator[str]:
    """Yield the measured offset, with spread so jitter stays visible."""
    if not pairings:
        yield "no test notes paired with a reference note -- check the channel numbers"
        if ambiguous:
            yield (
                f"{ambiguous} test note(s) sat exactly between two reference notes. "
                f"The displacement is half a step; use a longer step size to resolve it."
            )
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

    if ambiguous:
        yield ""
        yield (
            f"{ambiguous} test note(s) sat exactly between two reference notes and were "
            f"dropped -- the displacement is half a step, so re-run at a longer step size."
        )

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
        "--ref-channel",
        type=int,
        default=3,
        help=(
            "0-based channel of the reference track -- the one at defaults. Getting this the "
            "wrong way round negates every offset reported, so check it against a known shift"
        ),
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
    pairings, ambiguous = pair_onsets(
        onsets,
        ref_channel=args.ref_channel,
        test_channel=args.test_channel,
        window=args.window,
    )
    for line in report(pairings, ppq=ppq, bpm=bpm, ambiguous=ambiguous):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
