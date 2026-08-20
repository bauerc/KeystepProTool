"""The ``--flat-velocity`` grammar, and what it refuses."""

import pytest

from ksp.midi_export import DEFAULT_FLAT_VELOCITY
from ksp_cli.flat_velocity import parse_flat_velocity


def test_absent_means_the_stored_velocity() -> None:
    assert parse_flat_velocity(None) is None


def test_fresh_is_the_measured_default() -> None:
    assert parse_flat_velocity("fresh") == DEFAULT_FLAT_VELOCITY


def test_a_number_passes_through_unvalidated() -> None:
    # Range-checking is ExportOptions' job, not this function's -- 0 and 999 are both accepted
    # here so the two cores raise the identical message for them.
    assert parse_flat_velocity("64") == 64
    assert parse_flat_velocity("0") == 0
    assert parse_flat_velocity("999") == 999


@pytest.mark.parametrize("text", ["x", "", "loud", "1.5", "-5", "+5", "1_0"])
def test_a_malformed_value_names_itself(text: str) -> None:
    # ``1_0`` is refused although ``int`` takes it: Swift's ``Int`` does not, and the two cores
    # refuse the same input.
    with pytest.raises(ValueError, match="is not 'fresh' or a velocity"):
        parse_flat_velocity(text)


def test_a_non_ascii_digit_is_not_a_velocity() -> None:
    with pytest.raises(ValueError, match="is not 'fresh' or a velocity"):
        parse_flat_velocity("٣")


def test_the_value_is_quoted_in_the_message() -> None:
    with pytest.raises(ValueError) as caught:
        parse_flat_velocity("loud")
    assert str(caught.value) == "--flat-velocity: 'loud' is not 'fresh' or a velocity"
