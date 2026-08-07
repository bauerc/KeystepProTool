"""Printing diagnostics, and the --verbose flag both tools share.

``ksp`` decides what to say; this decides where it goes and how much of it.
The default is one line per kind of problem, because a real project raises the
same finding in a dozen patterns and the one-off warnings are the ones worth
reading.
"""

import sys
from typing import Annotated, TextIO

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
