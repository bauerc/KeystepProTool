"""The ``.KeyStepPro`` key grammar.

All structure in these files lives in the key names -- the JSON itself is one
flat object with no nesting: ``<itemId>_<paramId>[_<idx1>][_<idx2>][_<idx3>]``.
Spec 2. Reading and writing values goes through :class:`ksp.raw.RawProject`.
"""

from ksp.types import ItemId, ParamId


def key(item: ItemId, param: ParamId, *indices: int) -> str:
    """Build a file key from an item, a parameter and 0-3 indices."""
    return "_".join(str(part) for part in (item, param, *indices))
