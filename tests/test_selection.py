"""The ``--tracks`` / ``--patterns`` grammar, and what it refuses."""

import pytest

from ksp_cli.selection import parse_selection


def parse(text: str | None, limit: int = 4) -> frozenset[int]:
    return parse_selection(text, option="--tracks", limit=limit)


def test_unset_means_all() -> None:
    # Empty is what Project.select already reads as "every one of them".
    assert parse(None) == frozenset()


def test_a_single_number() -> None:
    assert parse("3") == frozenset({3})


def test_a_comma_list() -> None:
    assert parse("1,3") == frozenset({1, 3})


def test_a_range_covers_both_ends() -> None:
    assert parse("2-5", limit=16) == frozenset({2, 3, 4, 5})


def test_a_range_of_one() -> None:
    assert parse("2-2") == frozenset({2})


def test_lists_and_ranges_mix() -> None:
    assert parse("1,3-5,8", limit=16) == frozenset({1, 3, 4, 5, 8})


def test_repeats_and_overlaps_collapse() -> None:
    assert parse("1,1,1-2", limit=16) == frozenset({1, 2})


def test_whitespace_around_items_is_ignored() -> None:
    assert parse(" 1 , 3 - 4 ", limit=16) == frozenset({1, 3, 4})


@pytest.mark.parametrize("text", ["x", "", "1,", "2-", "-3", "2-3-4", "1..3", "1_0", "--5"])
def test_a_malformed_item_names_itself(text: str) -> None:
    # ``1_0`` and a non-ASCII digit are refused although ``int`` takes both: Swift's does not.
    with pytest.raises(ValueError, match="is not a number or a range"):
        parse(text, limit=16)


def test_a_malformed_item_is_quoted_in_the_message() -> None:
    with pytest.raises(ValueError) as caught:
        parse("1,x")
    assert str(caught.value) == "--tracks: 'x' is not a number or a range"


@pytest.mark.parametrize("text", ["0", "5", "1,9", "3-9"])
def test_out_of_range_names_the_number(text: str) -> None:
    with pytest.raises(ValueError, match="is out of range 1-4"):
        parse(text)


def test_the_offending_number_is_the_one_reported() -> None:
    with pytest.raises(ValueError) as caught:
        parse("1,9")
    assert str(caught.value) == "--tracks: 9 is out of range 1-4"


def test_a_range_that_ends_before_it_starts() -> None:
    with pytest.raises(ValueError) as caught:
        parse("4-2")
    assert str(caught.value) == "--tracks: '4-2' ends before it starts"


def test_a_non_ascii_digit_is_not_a_number() -> None:
    with pytest.raises(ValueError, match="is not a number or a range"):
        parse("٣")


def test_a_numeral_too_big_for_an_int64_is_still_out_of_range() -> None:
    """Swift's ``Int`` cannot hold it; both cores must still call it out of range."""
    assert str(_refusal("99999999999999999999")) == (
        "--tracks: 99999999999999999999 is out of range 1-4"
    )
    assert str(_refusal("+00009")) == "--tracks: 9 is out of range 1-4"
    # As the end of a range it is never the number reported: the walk stops at limit + 1 first.
    assert str(_refusal("3-99999999999999999999")) == "--tracks: 5 is out of range 1-4"
    assert str(_refusal("0-99999999999999999999")) == "--tracks: 0 is out of range 1-4"
    assert str(_refusal("99999999999999999999-3")) == (
        "--tracks: '99999999999999999999-3' ends before it starts"
    )


def _refusal(text: str) -> ValueError:
    with pytest.raises(ValueError) as caught:
        parse(text)
    return caught.value


def test_the_option_name_is_the_caller_s() -> None:
    with pytest.raises(ValueError) as caught:
        parse_selection("99", option="--patterns", limit=16)
    assert str(caught.value) == "--patterns: 99 is out of range 1-16"
