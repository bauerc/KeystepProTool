"""Regenerate tests/fixtures/bulk_fast_requests.txt, the plan both cores are held to.

KSPKit carries its own transcription of bulk_plan's table, so nothing in Swift would
notice a regenerated Python one. Re-run this after tools/gen_bulk_plan.py, then run the
tests: test_bulk_fast holds the Python plan to this file and BulkFastTests the Swift.
"""

from pathlib import Path

from ksp.bulk_fast import iter_requests
from ksp.sysex import ReadRequest

TARGET = Path("tests/fixtures/bulk_fast_requests.txt")


def line(request: ReadRequest) -> str:
    """One request as ``<item> <param> <indices|-> <count|->``."""
    indices = ",".join(str(index) for index in request.indices) or "-"
    count = "-" if request.count is None else str(request.count)
    return f"{request.item} {request.param} {indices} {count}"


def render() -> str:
    return "".join(line(request) + "\n" for request in iter_requests())


if __name__ == "__main__":
    TARGET.write_text(render())
    print(f"wrote {TARGET}")
