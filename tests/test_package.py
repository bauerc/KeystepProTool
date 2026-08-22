"""Proves the ``src/`` layout is installed correctly."""

from pathlib import Path

import ksp


def test_ksp_resolves_under_src_not_repo_root() -> None:
    """``ksp`` resolves via the installed distribution, never from the cwd."""
    assert ksp.__file__ is not None
    parents = Path(ksp.__file__).resolve().parents
    assert parents[1].name in {"src", "site-packages"}, (
        f"unexpected import location: {ksp.__file__}"
    )
