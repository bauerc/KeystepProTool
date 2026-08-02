"""M5 -- a converted MIDI clip, on the device.

Same two phases as M4: this writes the candidate, the operator loads it in MCC,
pushes it to the KeyStep Pro and listens. What makes it a milestone is the
listening, not a green run here.

M4 already proved that a file built by ``place_note`` loads, transfers and
plays back unchanged. What is new is that the notes came from a MIDI file
nobody typed in, so the thing under test is the conversion: sixteen steps, in
the order the clip has them, at the pitches the clip has.

The protocol entry is ``analysis/Hardware_Test_Protocol.md``, tier M5.
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
