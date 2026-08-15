"""Reading a project file on behalf of a command.

``ksp.reader`` decides what a project is; this decides what a user is told when
the file is not one. Both reading commands stop the same way on the same two
failures, so the mapping lives here rather than once each.
"""

from pathlib import Path
from typing import Any

from ksp.lenient_json import load_path
from ksp.model import Project
from ksp.reader import load
from ksp_cli.reporting import fail

#: Shipped inside the package so the installed command is self-contained. Path
#: resolution stays in the CLI: ``ksp`` must not decide where files are.
TEMPLATE_NAME = "Default.KeyStepPro"


def default_template() -> Path:
    """MCC's factory default, as shipped with this package."""
    return Path(__file__).parent / "templates" / TEMPLATE_NAME


def load_template(path: Path | None, *, prog: str) -> dict[str, Any]:
    """The project at *path* or the shipped default, as the raw dict."""
    resolved = path or default_template()
    try:
        return load_path(resolved)
    except OSError as exc:  # its message already names the file
        fail(f"template: {exc}", prog=prog, code=1)
    except ValueError as exc:
        fail(f"template: {resolved}: {exc}", prog=prog, code=1)


def load_project(path: Path, *, prog: str) -> Project:
    """The project at *path*, or a file-or-format failure and exit 1."""
    try:
        return load(path)
    except OSError as exc:  # its message already names the file
        fail(str(exc), prog=prog, code=1)
    except ValueError as exc:
        fail(f"{path}: {exc}", prog=prog, code=1)
