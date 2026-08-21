"""The ``--tracks`` / ``--patterns`` grammar: numbers and ``N-M`` ranges, comma-separated."""

SELECTION_HELP = "numbers and N-M ranges, comma-separated (e.g. 1,3 or 2-4)"


def parse_selection(text: str | None, *, option: str, limit: int) -> frozenset[int]:
    """Parse *text* into the selected numbers, ``1`` to *limit*.
    ``None`` gives the empty set, which is how ``Project.select`` spells "all of them"."""
    if text is None:
        return frozenset()
    selected: set[int] = set()
    for item in text.split(","):
        item = item.strip()
        start, sep, end = item.partition("-")
        first = _int(start, item, option)
        last = _int(end, item, option) if sep else first
        if last < first:
            raise ValueError(f"{option}: '{item}' ends before it starts")
        for number in range(first, last + 1):
            if not 1 <= number <= limit:
                raise ValueError(f"{option}: {number} is out of range 1-{limit}")
            selected.add(number)
    return frozenset(selected)


def _int(text: str, item: str, option: str) -> int:
    # Spelled out rather than left to ``int``, which also takes underscores and
    # non-ASCII digits: both cores must refuse exactly the same input.
    body = text.strip()
    digits = body[1:] if body[:1] in ("+", "-") else body
    if not (digits.isascii() and digits.isdigit()):
        raise ValueError(f"{option}: '{item}' is not a number or a range")
    return int(body)
