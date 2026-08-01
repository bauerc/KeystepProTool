"""The diagnostics record, and how it collapses.

The point of the module is that one problem affecting forty notes reads as one
line by default and forty lines on request, without either view inventing or
losing anything. These tests pin both directions.
"""

import pytest

from ksp.diagnostics import (
    SUMMARIES,
    Code,
    Collector,
    Diagnostic,
    Report,
    Severity,
    Site,
)

# --- Sites and messages ---------------------------------------------------


@pytest.mark.parametrize(
    ("site", "expected"),
    [
        (Site(), ""),
        (Site(track=1), "track 1"),
        (Site(pattern=9), "pattern 9"),
        (Site(pattern=9, kind="drum"), "pattern 9 (drum)"),
        (Site(track=1, pattern=9, kind="drum"), "track 1 pattern 9 (drum)"),
        (Site(pattern=9, slot=1), "pattern 9 slot 1"),
        (Site(kind="drum"), "(drum)"),
    ],
)
def test_site_describes_itself(site: Site, expected: str) -> None:
    assert site.describe() == expected


def test_message_prefixes_the_site() -> None:
    entry = Diagnostic(Code.GATE_SHORTENED, "a gate was shortened", site=Site(track=1, pattern=2))
    assert entry.message == "track 1 pattern 2: a gate was shortened"


def test_message_omits_an_empty_site() -> None:
    assert Diagnostic(Code.TIME_SHIFT_NOT_APPLIED, "shift not applied").message == (
        "shift not applied"
    )


def test_at_fills_in_site_parts_without_losing_the_rest() -> None:
    """The export knows the track; the reader that raised this did not."""
    entry = Diagnostic(Code.FLAG_WITHOUT_NOTE, "detail", site=Site(pattern=9, kind="drum"))
    assert entry.at(track=3).site == Site(track=3, pattern=9, kind="drum")


# --- Collection -----------------------------------------------------------


def test_exact_repeats_are_dropped() -> None:
    collector = Collector()
    for _ in range(3):
        collector.add(Code.TIME_SHIFT_NOT_APPLIED, "shift not applied")
    assert len(collector.report()) == 1


def test_the_same_code_at_different_sites_survives() -> None:
    """Otherwise the counts would under-report, which is worse than noise."""
    collector = Collector()
    collector.add(Code.DISABLED_STEP_OFF, "2 notes", site=Site(pattern=1), subjects=2)
    collector.add(Code.DISABLED_STEP_OFF, "2 notes", site=Site(pattern=5), subjects=2)
    assert len(collector.report()) == 2


def test_insertion_order_is_kept() -> None:
    collector = Collector()
    collector.add(Code.GATE_SHORTENED, "first")
    collector.add(Code.TIME_SHIFT_NOT_APPLIED, "second")
    assert collector.report().messages == ("first", "second")


# --- Grouping and rendering -----------------------------------------------


@pytest.fixture
def report() -> Report:
    collector = Collector()
    collector.add(
        Code.DISABLED_STEP_OFF,
        "5 disabled note(s), step turned off",
        site=Site(track=1, pattern=5, kind="drum"),
        subjects=5,
    )
    collector.add(
        Code.DISABLED_STEP_OFF,
        "2 disabled note(s), step turned off",
        site=Site(track=1, pattern=9, kind="drum"),
        subjects=2,
    )
    collector.add(Code.TIME_SHIFT_NOT_APPLIED, "notes carry a non-zero time shift")
    return collector.report()


def test_grouping_is_by_code_in_first_appearance_order(report: Report) -> None:
    assert [g.code for g in report.grouped()] == [
        Code.DISABLED_STEP_OFF,
        Code.TIME_SHIFT_NOT_APPLIED,
    ]


def test_a_group_counts_sites_and_subjects(report: Report) -> None:
    group = report.grouped()[0]
    assert (group.sites, group.subjects) == (2, 7)


def test_the_default_view_is_one_line_per_code(report: Report) -> None:
    lines = report.render()
    assert len(lines) == 2
    assert lines[0] == (
        "2 patterns hold disabled notes (7 notes, step turned off); they do not play on the device"
    )


def test_a_group_of_one_keeps_its_own_message(report: Report) -> None:
    """Collapsing a single occurrence would lose its site for no gain."""
    assert report.render()[1] == "notes carry a non-zero time shift"


def test_verbose_is_every_occurrence(report: Report) -> None:
    assert report.render(verbose=True) == report.messages
    assert len(report.render(verbose=True)) == 3


def test_verbose_is_a_superset_of_the_default(report: Report) -> None:
    """The default must never say something verbose does not support."""
    assert len(report.render(verbose=True)) >= len(report.render())


def test_the_note_says_how_much_was_hidden(report: Report) -> None:
    assert report.note() == "3 warnings collapsed into 2 kinds; --verbose for detail"


def test_no_note_when_nothing_collapsed() -> None:
    collector = Collector()
    collector.add(Code.GATE_SHORTENED, "one")
    collector.add(Code.TIME_SHIFT_NOT_APPLIED, "two")
    assert collector.report().note() is None


def test_no_note_when_verbose(report: Report) -> None:
    assert report.note(verbose=True) is None


def test_an_empty_report_renders_to_nothing() -> None:
    empty = Report()
    assert not empty
    assert empty.render() == ()
    assert empty.note() is None


def test_merge_concatenates_and_deduplicates() -> None:
    """Exporting several files must not repeat a caveat once per file."""
    first = Collector()
    first.add(Code.DRUM_MAP_ASSUMED, "chromatic from 36")
    second = Collector()
    second.add(Code.DRUM_MAP_ASSUMED, "chromatic from 36")
    second.add(Code.GATE_SHORTENED, "shortened", site=Site(pattern=2))
    merged = first.report().merge(second.report())
    assert len(merged) == 2


# --- The table ------------------------------------------------------------


def test_every_code_has_a_summary() -> None:
    """A missing entry would raise KeyError the first time it collapsed."""
    assert set(SUMMARIES) == set(Code)


@pytest.mark.parametrize("code", list(Code))
def test_every_summary_renders(code: Code) -> None:
    """Catches a template naming a placeholder the formatter does not supply."""
    collector = Collector()
    for pattern in (1, 2):
        collector.add(code, "detail", site=Site(pattern=pattern), subjects=3)
    headline = collector.report().grouped()[0].headline
    assert headline
    assert "{" not in headline


def test_counted_nouns_are_singular_at_one() -> None:
    collector = Collector()
    collector.add(Code.FLAG_WITHOUT_NOTE, "a", site=Site(pattern=1), subjects=1)
    collector.add(Code.FLAG_WITHOUT_NOTE, "b", site=Site(pattern=1, slot=2), subjects=1)
    headline = collector.report().grouped()[0].headline
    assert headline.startswith("2 steps across 2 patterns")


def test_severity_defaults_to_warning() -> None:
    assert Diagnostic(Code.GATE_SHORTENED, "x").severity is Severity.WARNING


def test_to_dict_is_serialisable() -> None:
    entry = Diagnostic(
        Code.DISABLED_STEP_OFF, "detail", site=Site(track=1, pattern=9, kind="drum"), subjects=2
    )
    assert entry.to_dict() == {
        "code": "disabled-step-off",
        "severity": "warning",
        "site": {"track": 1, "pattern": 9, "kind": "drum", "slot": None},
        "detail": "detail",
        "subjects": 2,
    }
