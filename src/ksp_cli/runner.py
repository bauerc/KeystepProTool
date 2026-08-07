"""Runs a Typer app and returns its exit code instead of exiting the process.

Every command here is reachable two ways -- under its own name and as a
``kspplus`` subcommand -- and both go through a ``main(argv) -> int`` that the
console entry point and the tests call directly. Typer exits the interpreter
instead of returning, so this converts the one into the other.

Typer vendors its copy of Click privately, so there is no supported way to ask
it not to exit. Catching ``SystemExit`` needs none of its internals and leaves
Typer to render usage errors itself, which is where the Rich error panel comes
from.
"""

from collections.abc import Sequence

import typer


def run(app: typer.Typer, argv: Sequence[str] | None, *, prog_name: str) -> int:
    """Invoke *app* over *argv* and give back the code it exited with.

    *prog_name* is what usage and help text calls the command, so a standalone
    entry point passes its own name and the group passes ``kspplus``.
    """
    try:
        typer.main.get_command(app).main(args=argv, prog_name=prog_name)
    except SystemExit as exit_:
        # A bare sys.exit() carries None, and argparse-era callers expect an int.
        return exit_.code if isinstance(exit_.code, int) else 0
    return 0
