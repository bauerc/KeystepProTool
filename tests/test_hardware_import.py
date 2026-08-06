"""M5 and M6 -- a converted MIDI file, on the device.

Same two phases as M4: these write the candidates, the operator loads them in
MCC, pushes them to the KeyStep Pro and listens. What makes it a milestone is
the listening, not a green run here.

M4 already proved that a file built by ``place_note`` loads, transfers and
plays back unchanged. M5 added that the notes came from a MIDI file nobody
typed in. M6 adds everything a single monophonic clip could not reach: a drum
track on Track 1, chords, carried gates, and a sequence too long for one
pattern, which only plays as one sequence if the chain in ``121_84`` is right.

Both candidates were confirmed **by ear**; neither readback has been taken, so
the two readback tests skip until the captures exist. A readback diff is empty
when the file is right (M4.1), which makes it the cheapest regression net
available and the only way to catch a value that plays but is not the one we
meant.

The route is ``analysis/Hardware_Test_Protocol.md``, "The import route".
"""

from collections.abc import Callable
from pathlib import Path

import mido
import pytest

from ksp import lenient_json, midi_import, reader
from ksp.model import NoteKind

Loader = Callable[[str], dict[str, int | str]]

CANDIDATE = "M5-convert.KeyStepPro"
READBACK = "M5-convert-readback.KeyStepPro"

#: The clip goes on Track 1 so it is the first thing the device shows.
TRACK = 1
PATTERN = 1


@pytest.mark.hardware
def test_write_the_m5_candidate(simple_clip: Path, load_sample: Loader, captures_dir: Path) -> None:
    """Convert test_file_simple.mid. Run this before going to the device."""
    captures_dir.mkdir(parents=True, exist_ok=True)

    result = midi_import.convert(
        mido.MidiFile(simple_clip),
        load_sample("Default.KeyStepPro"),
        track=TRACK,
        pattern=PATTERN,
    )
    assert result.note_count == 16

    path = captures_dir / CANDIDATE
    lenient_json.dump_path(midi_import.saveable(result.raw), path)
    path.chmod(0o644)

    print(f"\nwrote {CANDIDATE} to {captures_dir}")
    print(
        f'cp project_files/captures/{CANDIDATE} "/Library/Arturia/MIDI Control '
        'Center/Templates/KeyStepPro/"'
    )


@pytest.mark.hardware
def test_the_device_kept_the_converted_pattern(
    require_capture: Callable[[str], Path], simple_clip: Path, load_sample: Loader
) -> None:
    """The pattern the device gives back is the clip we put in."""
    readback = lenient_json.load_path(require_capture(READBACK))
    expected = midi_import.convert(
        mido.MidiFile(simple_clip),
        load_sample("Default.KeyStepPro"),
        track=TRACK,
        pattern=PATTERN,
    )

    notes = reader.read_project(readback).track(TRACK).pattern(PATTERN).notes_of(NoteKind.SEQ)

    assert [(n.step, n.pitch, n.velocity) for n in notes] == [
        (n.step, n.pitch, n.velocity) for n in expected.notes
    ]
    assert all(note.active for note in notes)


# --- M6: the whole file ----------------------------------------------------

M6_CANDIDATE = "M6-song.KeyStepPro"
M6_READBACK = "M6-song-readback.KeyStepPro"

#: m6-test-file.mid puts its drums on channel 0 like everything else, so the
#: track has to be named. Counting every track of the file from 1.
M6_DRUM_TRACK = 3


def _m6_options() -> midi_import.ImportOptions:
    return midi_import.ImportOptions(drum_track=M6_DRUM_TRACK)


@pytest.mark.hardware
def test_write_the_m6_candidate(m6_song: Path, load_sample: Loader, captures_dir: Path) -> None:
    """Convert m6-test-file.mid. Run this before going to the device."""
    captures_dir.mkdir(parents=True, exist_ok=True)

    result = midi_import.convert_song(
        mido.MidiFile(m6_song), load_sample("Default.KeyStepPro"), options=_m6_options()
    )
    assert result.note_count == 291

    path = captures_dir / M6_CANDIDATE
    lenient_json.dump_path(midi_import.saveable(result.raw), path)
    path.chmod(0o644)

    print(f"\nwrote {M6_CANDIDATE} to {captures_dir}")
    print(
        f'cp project_files/captures/{M6_CANDIDATE} "/Library/Arturia/MIDI Control '
        'Center/Templates/KeyStepPro/"'
    )
    print(
        "listen for: four tracks; Track 1 drumming on four lanes; Track 2 in chords; "
        "Track 3 holding its notes across 8 and 16 steps; Track 4 running 8 bars "
        "rather than looping after 4, which is the chain"
    )


@pytest.mark.hardware
def test_the_device_kept_the_converted_song(
    require_capture: Callable[[str], Path], m6_song: Path, load_sample: Loader
) -> None:
    """Every track the device gives back is the one we put in.

    Wider than M5's readback on purpose: this is where a drum lane, a chord's
    pool ordinals, a carried gate and a pattern chain would each show up if the
    device disagreed with us about any of them.
    """
    readback = reader.read_project(lenient_json.load_path(require_capture(M6_READBACK)))
    expected = midi_import.convert_song(
        mido.MidiFile(m6_song), load_sample("Default.KeyStepPro"), options=_m6_options()
    )

    for plan in expected.plan.tracks:
        kind = NoteKind.DRUM if plan.is_drum else NoteKind.SEQ
        for placement in plan.placements:
            pattern = readback.track(plan.track).pattern(placement.pattern)
            notes = pattern.notes_of(kind)

            assert pattern.seq_step_count == placement.step_count or plan.is_drum
            assert [(n.step, n.pitch, n.velocity, n.gate_raw) for n in notes] == [
                (n.step, n.lane if plan.is_drum else n.pitch, n.velocity, n.gate)
                for n in placement.notes
            ]
            assert all(note.active for note in notes)

    # The chain is the only part of a split track that is not in a note.
    chain = next(c for c in readback.scenes[readback.current_scene - 1].chains if c.track == 4)
    assert chain.patterns == (1, 2)
