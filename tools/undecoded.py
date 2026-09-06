"""Which addresses the read plan fetches and the reader never looks up.

Splits them into the families no reader path touches at all and the ones that are
merely empty in the corpus, because only the first kind is safe to stop fetching.
"""

import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from ksp.bulk_fast import iter_requests
from ksp.lenient_json import load_path, strip_trailing_commas
from ksp.reader import read_project
from ksp.sysex import ReadRequest

#: Arturia's own parameter names, for the report. Absent on a machine without MCC.
VENDOR = Path("/Library/Arturia/MIDI Control Center/Resources/KeyStepPro.json")


class Tracking(dict[str, Any]):
    """A project dict that records every key the reader asks for."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.touched: set[str] = set()
        self.iterated = 0

    def __getitem__(self, key: str) -> Any:
        self.touched.add(key)
        return super().__getitem__(key)

    def get(self, key: str, default: Any = None) -> Any:
        self.touched.add(key)
        return super().get(key, default)

    def __contains__(self, key: object) -> bool:
        self.touched.add(str(key))
        return super().__contains__(key)

    # An iteration would read values without naming them, which the instrument cannot see;
    # the count is reported so a reader that starts iterating invalidates the result loudly.
    def __iter__(self) -> Any:
        self.iterated += 1
        return super().__iter__()

    def keys(self) -> Any:
        self.iterated += 1
        return super().keys()

    def items(self) -> Any:
        self.iterated += 1
        return super().items()


def addresses(request: ReadRequest) -> list[str]:
    """The keys one request fills, walking its last index by ``count``."""
    base = f"{request.item}_{request.param}"
    if request.count is None:
        return [base]
    lead = "".join(f"_{index}" for index in request.indices[:-1])
    last = request.indices[-1]
    return [f"{base}{lead}_{last + step}" for step in range(request.count)]


def vendor_names() -> dict[int, str]:
    if not VENDOR.exists():
        return {}
    text = VENDOR.read_text(encoding="utf-8", errors="replace")
    names: dict[int, str] = {}
    for field in json.loads(strip_trailing_commas(text)).get("fields", []):
        names.setdefault(field["paramId"], field.get("name", "?"))
    return names


def main(paths: list[str]) -> int:
    touched: set[str] = set()
    iterated = 0
    decoded = 0
    for path in paths:
        try:
            raw = load_path(path)
        except (OSError, ValueError):
            continue
        tracking = Tracking(raw)
        try:
            read_project(tracking, path)
        except ValueError:
            continue
        touched |= tracking.touched
        iterated += tracking.iterated
        decoded += 1

    if not decoded:
        print("no projects decoded", file=sys.stderr)
        return 1
    if iterated:
        print(
            f"the reader iterated {iterated} times -- the count below is a floor", file=sys.stderr
        )

    names = vendor_names()
    everused = {
        (int(key.split("_")[0]), int(key.split("_")[1]))
        for key in touched
        if key[:1].isdigit() and "_" in key
    }
    structural: dict[tuple[int, int], list[int]] = defaultdict(lambda: [0, 0])
    content: dict[tuple[int, int], list[int]] = defaultdict(lambda: [0, 0])
    for request in iter_requests():
        keys = addresses(request)
        if any(key in touched for key in keys):
            continue
        family = (request.item, request.param)
        target = content if family in everused else structural
        target[family][0] += 1
        target[family][1] += len(keys)

    for label, group in (("structural", structural), ("content-dependent", content)):
        asked = sum(count for count, _ in group.values())
        filled = sum(addrs for _, addrs in group.values())
        print(f"{label}: {asked} requests, {filled} addresses, {len(group)} families")

    print(f"\n{decoded} projects, {len(touched)} keys read\n")
    for (item, param), (asked, filled) in sorted(structural.items()):
        print(f"  {item}_{param:<4} x{asked:<4} {filled:5d} addr  {names.get(param, '')}")
    return 0


if __name__ == "__main__":
    files = sys.argv[1:] or [str(p) for p in sorted(Path("project_files").glob("*.KeyStepPro"))]
    raise SystemExit(main(files))
