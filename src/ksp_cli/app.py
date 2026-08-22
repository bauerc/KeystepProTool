"""``kspplus`` -- the four commands under one name, each mounted by its own ``register``."""

from collections.abc import Sequence

from ksp_cli import convert, dump, export, pull
from ksp_cli.runner import new_app, run

PROG = "kspplus"

app = new_app(
    help="Convert between Standard MIDI files and Arturia KeyStep Pro projects.",
    epilog=(
        "Each subcommand is also installed under its own name, so 'kspplus ksp2midi ...' and "
        "'ksp2midi ...' are the same command. Run 'kspplus COMMAND --help' for its options."
    ),
    no_args_is_help=True,
)

dump.register(app)
export.register(app)
convert.register(app)
pull.register(app)


def main(argv: Sequence[str] | None = None) -> int:
    return run(app, argv, prog_name=PROG)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
