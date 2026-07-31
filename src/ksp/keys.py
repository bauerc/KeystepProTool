"""The ``.KeyStepPro`` key grammar.

All structure in these files lives in the key names -- the JSON itself is one
flat object with no nesting::

    <itemId>_<paramId>[_<idx1>][_<idx2>][_<idx3>]

Spec section 2. Centralising key construction here means the two index spaces
(step-indexed vs note-indexed) are the only thing a caller has to think about;
getting the string right is not also their problem.
"""

from functools import lru_cache
from typing import Any


@lru_cache(maxsize=4096)
def key(item: int, param: int, *indices: int) -> str:
    """Build a file key from an item, a parameter and 0-3 indices."""
    n = len(indices)
    if n == 0:
        return f"{item}_{param}"
    elif n == 1:
        return f"{item}_{param}_{indices[0]}"
    elif n == 2:
        return f"{item}_{param}_{indices[0]}_{indices[1]}"
    elif n == 3:
        return f"{item}_{param}_{indices[0]}_{indices[1]}_{indices[2]}"
    return f"{item}_{param}_" + "_".join(str(i) for i in indices)


def get_int(raw: dict[str, Any], item: int, param: int, *indices: int) -> int | None:
    """Read one integer value, or ``None`` if the key is absent.

    Absent is meaningful rather than exceptional: the key set differs between
    item types (only item 123 carries drum parameters), so callers probing a
    parameter that may not apply get ``None`` instead of a lookup error.

    Raises:
        TypeError: if the key exists but does not hold an integer. That would
            mean the file's shape differs from every sample we have, which is
            worth surfacing loudly rather than silently coercing.
    """
    k = key(item, param, *indices)

    value = raw.get(k)
    if value is None:
        return None
    if not isinstance(value, int):
        raise TypeError(f"{k} holds {type(value).__name__}, expected int")
    return value


def read_array(
    raw: dict[str, Any], item: int, param: int, *prefix: int, length: int
) -> list[int | None]:
    """Read a 1-based indexed array as a 0-based Python list.

    The trailing index in these files runs 1..N (step 1..64, or note ordinal
    1..64). The returned list is ordinary 0-based, so ``result[0]`` is the
    file's index 1. Every caller wants one convention or the other and mixing
    them is how the two index spaces get confused in the first place.
    """
    base_key = key(item, param, *prefix) + "_"

    result: list[int | None] = [None] * length
    for idx in range(length):
        k = f"{base_key}{idx + 1}"
        val = raw.get(k)
        if val is not None:
            if not isinstance(val, int):
                raise TypeError(f"{k} holds {type(val).__name__}, expected int")
            result[idx] = val

    return result
