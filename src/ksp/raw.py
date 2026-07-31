"""Typed access to the flat key/value dict a ``.KeyStepPro`` file parses to.

Wraps the dict so the key grammar lives in one place and callers deal in
(item, param, indices) rather than strings. Read-only for now: M3 adds
``set_int`` here, and M4's targeted mutation goes through it, so the writer
addresses keys exactly the way the reader does instead of re-deriving them.
"""

from dataclasses import dataclass
from typing import Any

from ksp.keys import key
from ksp.types import ItemId, ParamId


@dataclass(frozen=True)
class RawProject:
    """A parsed project file, addressed by item and parameter."""

    data: dict[str, Any]

    def __contains__(self, name: str) -> bool:
        return name in self.data

    def text(self, name: str) -> str | None:
        """A top-level string field such as ``device`` or ``version``."""
        value = self.data.get(name)
        return value if isinstance(value, str) else None

    def get_int(self, item: ItemId, param: ParamId, *indices: int) -> int | None:
        """One integer value, or ``None`` if the key is absent.

        Absent is meaningful rather than exceptional -- the key set differs
        between item types, so probing a parameter that may not apply gives
        ``None`` instead of a lookup error.
        """
        name = key(item, param, *indices)
        value = self.data.get(name)
        if value is None:
            return None
        if not isinstance(value, int):
            # The file's shape differs from every sample we have; surface it
            # rather than silently coercing.
            raise TypeError(f"{name} holds {type(value).__name__}, expected int")
        return value

    def int_at(self, item: ItemId, param: ParamId, *indices: int, default: int) -> int:
        """Like :meth:`get_int`, substituting *default* for an absent key."""
        value = self.get_int(item, param, *indices)
        return default if value is None else value

    def array(self, item: ItemId, param: ParamId, *prefix: int, length: int) -> list[int | None]:
        """A 1-based indexed array as a 0-based list, so ``result[0]`` is index 1.

        Every caller wants one convention or the other, and mixing them is how
        the two index spaces get confused. Spec 4.
        """
        return [self.get_int(item, param, *prefix, i) for i in range(1, length + 1)]


def as_raw(source: "RawProject | dict[str, Any]") -> RawProject:
    """Accept either a wrapper or a bare parsed dict."""
    return source if isinstance(source, RawProject) else RawProject(source)
