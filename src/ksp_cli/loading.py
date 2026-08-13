"""Reading a project file on behalf of a command.

``ksp.reader`` decides what a project is; this decides what a user is told when
the file is not one. Both reading commands stop the same way on the same two
failures, so the mapping lives here rather than once each.
"""

from pathlib import Path

from ksp.model import Project
from ksp.reader import load
from ksp_cli.reporting import fail


def load_project(path: Path, *, prog: str) -> Project:
    """The project at *path*, or a file-or-format failure and exit 1."""
    try:
        return load(path)
    except OSError as exc:  # its message already names the file
        fail(str(exc), prog=prog, code=1)
    except ValueError as exc:
        fail(f"{path}: {exc}", prog=prog, code=1)
