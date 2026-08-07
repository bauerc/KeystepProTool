"""Proves the ``src/`` layout is installed correctly.

With a ``src/`` layout an import can only succeed if the package was actually
installed into the environment, never by accidentally picking up the working
directory. That distinction matters here: M3 asserts byte-identical output,
and a test importing the wrong copy of the code could pass for the wrong
reason.
"""

from pathlib import Path

import ksp


def test_ksp_resolves_under_src_not_repo_root() -> None:
    """``ksp`` resolves via the installed distribution, never from the cwd.

    ``uv sync`` installs the project editable, so the resolved path points at
    ``src/ksp`` rather than into ``site-packages``. Either is fine; what must
    never happen is resolution from the repository root, which is what the
    ``src/`` layout exists to prevent.
    """
    assert ksp.__file__ is not None
    parents = Path(ksp.__file__).resolve().parents
    assert parents[1].name in {"src", "site-packages"}, (
        f"unexpected import location: {ksp.__file__}"
    )
