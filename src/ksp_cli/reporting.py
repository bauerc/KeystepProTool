"""Printing diagnostics and failures, and the --verbose flag both tools share."""

import sys
from collections.abc import Iterable
from pathlib import Path
from typing import Annotated, NoReturn, TextIO

import typer

from ksp.diagnostics import Report

VERBOSE_HELP = "list every diagnostic instead of one summary line per kind"

#: The panel the commands with grouped help put their reporting options in.
OUTPUT_PANEL = "Output"

#: Every command takes -v, so the flag is declared once and annotated in.
Verbose = Annotated[bool, typer.Option("-v", "--verbose", help=VERBOSE_HELP)]
VerboseInPanel = Annotated[
    bool, typer.Option("-v", "--verbose", help=VERBOSE_HELP, rich_help_panel=OUTPUT_PANEL)
]


def fail(message: str, *, prog: str, code: int) -> NoReturn:
    """Say why the command is stopping, then stop it with *code*.
    The codes are load-bearing: 1 for a file or format failure, 2 for a usage one."""
    print(f"{prog}: {message}", file=sys.stderr)
    raise typer.Exit(code)


def refuse_existing(destinations: Iterable[Path], *, force: bool, prog: str) -> None:
    """Stop before overwriting any of *destinations*, naming every one that is there."""
    if force:
        return
    existing = [str(path) for path in destinations if path.exists()]
    if existing:
        fail(f"{', '.join(existing)} already exists (use --force to overwrite)", prog=prog, code=1)


def print_report(
    report: Report,
    *,
    prog: str,
    verbose: bool = False,
    stream: TextIO | None = None,
) -> None:
    """Write *report* to stderr, collapsed unless *verbose*."""
    stream = sys.stderr if stream is None else stream
    for line in report.render(verbose=verbose):
        print(f"{prog}: warning: {line}", file=stream)
    note = report.note(verbose=verbose)
    if note is not None:
        # No "warning:" prefix: this is about the report, not a finding.
        print(f"{prog}: {note}", file=stream)
