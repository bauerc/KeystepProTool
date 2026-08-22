"""Runs a Typer app and returns its exit code instead of exiting the process."""

from collections.abc import Callable, Sequence
from typing import Any

import typer


def new_app(**kwargs: Any) -> typer.Typer:
    """A Typer app on this project's settings: Rich markup, no completion."""
    return typer.Typer(add_completion=False, rich_markup_mode="rich", **kwargs)


def run(app: typer.Typer, argv: Sequence[str] | None, *, prog_name: str) -> int:
    """Invoke *app* over *argv* and give back the code it exited with.
    *prog_name* is what usage and help text calls the command."""
    try:
        typer.main.get_command(app).main(args=argv, prog_name=prog_name)
    except SystemExit as exit_:
        # A bare sys.exit() carries None, and argparse-era callers expect an int.
        return exit_.code if isinstance(exit_.code, int) else 0
    return 0


def standalone(register: Callable[[typer.Typer], None], prog: str) -> Callable[..., int]:
    """The ``main`` a command's own entry point calls, around an app of one."""
    app = new_app()
    register(app)

    def main(argv: Sequence[str] | None = None) -> int:
        return run(app, argv, prog_name=prog)

    return main
