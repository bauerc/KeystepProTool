"""The ``--tracks`` / ``--patterns`` grammar shared by ``ksp2midi``'s selection.

A comma-separated list of numbers and ``N-M`` ranges, which
:meth:`ksp.model.Project.select` already takes as a set. Parsing lives here
rather than in the option declaration so both cores refuse the same input with
the same words: Typer's own range checking and ArgumentParser's word their
messages quite differently, and the two CLIs' output is a byte-for-byte
contract.
"""

SELECTION_HELP = "numbers and N-M ranges, comma-separated (e.g. 1,3 or 2-4)"


def parse_selection(text: str | None, *, option: str, limit: int) -> frozenset[int]:
    """Parse *text* into the selected numbers, ``1`` to *limit*.

    ``None`` gives the empty set, which is how ``Project.select`` already spells
    "all of them". *option* names the flag in any message, so the user is told
    which of the two they got wrong.
    """
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
    # non-ASCII digits. Swift's ``Int`` takes neither, and the two cores have to
    # refuse the same input.
    body = text.strip()
    digits = body[1:] if body[:1] in ("+", "-") else body
    if not (digits.isascii() and digits.isdigit()):
        raise ValueError(f"{option}: '{item}' is not a number or a range")
    return int(body)
