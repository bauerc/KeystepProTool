"""The ``--route`` grammar, and what it refuses."""

import pytest

from ksp.midi_import import TrackRoute
from ksp_cli.route_option import parse_routes


def test_unset_routes_nothing() -> None:
    # Empty is what ImportOptions already reads as "assign as before".
    assert parse_routes(None) == ()


def test_one_pair() -> None:
    assert parse_routes("3:1") == (TrackRoute(3, 1),)


def test_a_comma_list_keeps_its_order() -> None:
    # Ordered, not a mapping: the two cores are a byte-for-byte contract and
    # Swift's Dictionary iteration is nondeterministic.
    assert parse_routes("3:1,1:2") == (TrackRoute(3, 1), TrackRoute(1, 2))


def test_whitespace_around_items_is_ignored() -> None:
    assert parse_routes(" 3 : 1 , 1 : 2 ") == (TrackRoute(3, 1), TrackRoute(1, 2))


def test_a_sign_survives_to_be_refused_by_range() -> None:
    # Out of range is ImportOptions' refusal to word, not the grammar's.
    assert parse_routes("-1:2") == (TrackRoute(-1, 2),)


@pytest.mark.parametrize(
    "text", ["3", "", "3:", ":1", "3:x", "x:3", "1:2:3", "1_0:2", "2:1,", "1:2,3"]
)
def test_a_malformed_pair_names_itself(text: str) -> None:
    # ``1_0`` and a non-ASCII digit are refused although ``int`` takes both:
    # Swift's ``Int`` takes neither, and the two cores refuse the same input.
    with pytest.raises(ValueError, match="is not a source:device pair"):
        parse_routes(text)


def test_a_malformed_pair_is_quoted_whole() -> None:
    with pytest.raises(ValueError, match=r"--route: '1:2:3' is not a source:device pair"):
        parse_routes("1:2:3")


@pytest.mark.parametrize("text", ["99999999999999999999:1", "1:99999999999999999999"])
def test_a_number_too_large_to_be_a_track(text: str) -> None:
    # Python's ints are unbounded and Swift's are not, so an oversized numeral
    # is refused here rather than reaching a range message that would print it.
    with pytest.raises(ValueError, match="too large to be one"):
        parse_routes(text)
