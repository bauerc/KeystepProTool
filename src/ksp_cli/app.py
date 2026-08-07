"""``kspplus`` -- the three commands under one name.

Nothing is implemented here. Each command is defined in its own module and
mounted on this group by its own ``register``, so ``kspplus ksp2midi ...`` and
``ksp2midi ...`` run the same function with the same options. The standalone
names stay installed; this is a way in, not a replacement.
"""

from collections.abc import Sequence

import typer

from ksp_cli import convert, dump, export
from ksp_cli.runner import run

PROG = "kspplus"

app = typer.Typer(
    help="Convert between Standard MIDI files and Arturia KeyStep Pro projects.",
    epilog=(
        "Each subcommand is also installed under its own name, so 'kspplus ksp2midi ...' and "
        "'ksp2midi ...' are the same command. Run 'kspplus COMMAND --help' for its options."
    ),
    no_args_is_help=True,
    rich_markup_mode="rich",
)

dump.register(app)
export.register(app)
convert.register(app)


def main(argv: Sequence[str] | None = None) -> int:
    return run(app, argv, prog_name=PROG)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
