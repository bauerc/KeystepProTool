"""The number one half of a ``source:...`` pair may spell, bounded for both ports."""

#: The largest number a pair may spell. Python's ints are unbounded and Swift's
#: are not, so an oversized numeral is refused by the grammar.
MAX_PAIR_NUMBER = 2**31 - 1


def pair_int(text: str, *, malformed: str, oversized: str) -> int:
    """One half of a pair, refused in the caller's own words."""
    # Spelled out rather than left to ``int``, which also takes underscores and
    # non-ASCII digits: both cores must refuse exactly the same input.
    body = text.strip()
    digits = body[1:] if body[:1] in ("+", "-") else body
    if not (digits.isascii() and digits.isdigit()):
        raise ValueError(malformed)
    # Counted before converting: past 4300 digits ``int`` raises its own message
    # about sys.set_int_max_str_digits, which is not something to show a user.
    too_long = len(digits.lstrip("0")) > len(str(MAX_PAIR_NUMBER))
    if too_long or abs(int(body)) > MAX_PAIR_NUMBER:
        raise ValueError(oversized)
    return int(body)
