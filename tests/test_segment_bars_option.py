"""The ``--segment-bars`` grammar, and what it refuses."""

import pytest

from ksp.midi_import import TrackSegments
from ksp_cli.segment_bars_option import resolve_segments


def _parse(text: str | None) -> tuple[TrackSegments, ...]:
    return resolve_segments(None, text)


def test_unset_segments_nothing() -> None:
    # Empty is what ImportOptions already reads as "the automatic split, as before".
    assert _parse(None) == ()


def test_one_pair() -> None:
    assert _parse("3:5") == (TrackSegments(3, (5,)),)


def test_pairs_naming_one_track_gather_into_its_bars() -> None:
    assert _parse("2:5,2:9") == (TrackSegments(2, (5, 9)),)


def test_a_comma_list_keeps_its_order() -> None:
    # Ordered, not a mapping: the two cores are a byte-for-byte contract and
    # Swift's Dictionary iteration is nondeterministic.
    assert _parse("3:3,2:5") == (TrackSegments(3, (3,)), TrackSegments(2, (5,)))


def test_a_track_holds_the_place_it_first_took() -> None:
    assert _parse("2:5,3:3,2:9") == (TrackSegments(2, (5, 9)), TrackSegments(3, (3,)))


def test_whitespace_around_items_is_ignored() -> None:
    assert _parse(" 2 : 5 , 2 : 9 ") == (TrackSegments(2, (5, 9)),)


def test_a_sign_survives_to_be_refused_by_range() -> None:
    # Out of range is ImportOptions' refusal to word, not the grammar's.
    assert _parse("-1:5") == (TrackSegments(-1, (5,)),)


@pytest.mark.parametrize(
    "text", ["3", "", "3:", ":5", "3:x", "x:3", "1:2:3", "1_0:2", "2:5,", "2:5,3"]
)
def test_a_malformed_pair_names_itself(text: str) -> None:
    # ``1_0`` and a non-ASCII digit are refused although ``int`` takes both: Swift's does not.
    with pytest.raises(ValueError, match="is not a source:bar pair"):
        _parse(text)


def test_a_malformed_pair_is_quoted_whole() -> None:
    with pytest.raises(ValueError, match=r"--segment-bars: '1:2:3' is not a source:bar pair"):
        _parse("1:2:3")


@pytest.mark.parametrize(
    "text",
    [
        "99999999999999999999:5",
        "5:99999999999999999999",
        # Int.min: Swift parses it and then traps on abs(), so it is refused by magnitude.
        "-9223372036854775808:1",
        # Past 4300 digits ``int`` raises its own message about
        # sys.set_int_max_str_digits, which is not what Swift's failed parse says.
        "9" * 5000 + ":1",
    ],
)
def test_a_number_too_large_to_be_one(text: str) -> None:
    # Python's ints are unbounded and Swift's are not, so an oversized numeral
    # is refused here rather than reaching a range message that would print it.
    with pytest.raises(ValueError, match="too large to be one"):
        _parse(text)


def test_a_single_target_and_a_segmentation_contradict_each_other() -> None:
    with pytest.raises(ValueError, match="contradict each other"):
        resolve_segments(1, "1:5")


def test_a_single_target_alone_segments_nothing() -> None:
    assert resolve_segments(1, None) == ()
