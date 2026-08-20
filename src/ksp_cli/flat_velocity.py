"""The ``--flat-velocity`` grammar shared by ``ksp2midi``'s export.

``fresh`` or a bare number, which :class:`ksp.midi_export.ExportOptions` already range-checks.
Parsing lives here rather than in the option declaration for the same reason as
:mod:`ksp_cli.selection`: the two CLIs' output is a byte-for-byte contract.
"""

from ksp.midi_export import DEFAULT_FLAT_VELOCITY


def parse_flat_velocity(text: str | None) -> int | None:
    """Parse ``--flat-velocity``'s value into a velocity, unvalidated.

    ``None`` and ``"fresh"`` are today's "no override" and "the measured default" spellings; a
    bare numeral passes through for :class:`ExportOptions` to range-check, so both cores raise the
    identical message for ``0`` or an out-of-range value.
    """
    if text is None:
        return None
    if text == "fresh":
        return DEFAULT_FLAT_VELOCITY
    # Spelled out rather than left to ``int``, which also takes underscores and non-ASCII digits.
    # Swift's ``Int`` takes neither, and the two cores have to refuse the same input.
    if not (text.isascii() and text.isdigit()):
        raise ValueError(f"--flat-velocity: '{text}' is not 'fresh' or a velocity")
    return int(text)
