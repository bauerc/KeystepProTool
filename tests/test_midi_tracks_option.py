"""The ``--midi-tracks`` grammar, and how it meets ``--midi-track``."""

import pytest

from ksp_cli.midi_tracks_option import resolve_midi_tracks


def test_neither_spelling_selects_nothing() -> None:
    # Empty is what ImportOptions already reads as "all of them".
    assert resolve_midi_tracks(None, None) == frozenset()


def test_the_single_spelling_is_its_own_set() -> None:
    assert resolve_midi_tracks(3, None) == frozenset({3})


def test_the_single_spelling_keeps_an_out_of_range_number() -> None:
    # ImportOptions words the refusal for --midi-track, as it did before --midi-tracks existed.
    assert resolve_midi_tracks(0, None) == frozenset({0})


def test_a_comma_list() -> None:
    assert resolve_midi_tracks(None, "1,2,5") == frozenset({1, 2, 5})


def test_a_range() -> None:
    assert resolve_midi_tracks(None, "2-4") == frozenset({2, 3, 4})


def test_a_list_of_ranges_and_numbers() -> None:
    assert resolve_midi_tracks(None, "1,3-5") == frozenset({1, 3, 4, 5})


@pytest.mark.parametrize("text", ["bad", "", "1_0", "1,", "1-"])
def test_a_malformed_item_names_itself(text: str) -> None:
    with pytest.raises(ValueError, match=r"--midi-tracks: .* is not a number or a range"):
        resolve_midi_tracks(None, text)


def test_a_backward_range() -> None:
    with pytest.raises(ValueError, match=r"--midi-tracks: '3-1' ends before it starts"):
        resolve_midi_tracks(None, "3-1")


def test_zero_is_out_of_range() -> None:
    with pytest.raises(ValueError, match=r"--midi-tracks: 0 is out of range 1-65535"):
        resolve_midi_tracks(None, "0")


def test_a_number_past_the_file_format_is_out_of_range() -> None:
    # A Standard MIDI File counts its tracks in 16 bits, so nothing above this can exist.
    with pytest.raises(ValueError, match=r"--midi-tracks: 65536 is out of range 1-65535"):
        resolve_midi_tracks(None, "65536")


def test_an_oversized_numeral_is_printed_as_written() -> None:
    # Python's ints are unbounded and Swift's saturate; both must print these digits.
    with pytest.raises(ValueError, match=r"99999999999999999999 is out of range 1-65535"):
        resolve_midi_tracks(None, "99999999999999999999")


def test_the_two_spellings_contradict_each_other() -> None:
    with pytest.raises(ValueError, match=r"--midi-track and --midi-tracks contradict each other"):
        resolve_midi_tracks(1, "1")
