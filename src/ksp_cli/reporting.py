"""Printing diagnostics, and the --verbose flag both tools share.

``ksp`` decides what to say; this decides where it goes and how much of it.
The default is one line per kind of problem, because a real project raises the
same finding in a dozen patterns and the one-off warnings are the ones worth
reading.
"""

import argparse
import sys
from typing import TextIO

from ksp.diagnostics import Report

VERBOSE_HELP = "list every diagnostic instead of one summary line per kind"


def add_verbose_option(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("-v", "--verbose", action="store_true", help=VERBOSE_HELP)


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
