"""The ``--flat-velocity`` grammar: ``fresh`` or a bare number, range-checked downstream."""

from ksp.midi_export import DEFAULT_FLAT_VELOCITY


def parse_flat_velocity(text: str | None) -> int | None:
    """Parse ``--flat-velocity``'s value into a velocity, unvalidated.
    A bare numeral passes through for :class:`ExportOptions` to range-check."""
    if text is None:
        return None
    if text == "fresh":
        return DEFAULT_FLAT_VELOCITY
    # Spelled out rather than left to ``int``, which also takes underscores and
    # non-ASCII digits: both cores must refuse exactly the same input.
    if not (text.isascii() and text.isdigit()):
        raise ValueError(f"--flat-velocity: '{text}' is not 'fresh' or a velocity")
    return int(text)
