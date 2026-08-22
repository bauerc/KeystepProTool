"""The lane -> MIDI note map for drum tracks."""

import json
from pathlib import Path

import pytest

from ksp.constants import DRUM_LANE_COUNT
from ksp.drum_map import (
    DEFAULT_CHROMATIC_LOW,
    DEFAULT_DRUM_CHANNEL,
    GM_DRUM_NAMES,
    DrumMap,
)
from ksp_cli.dump import parse_drum_map, resolve_drum_map


class TestDefaults:
    def test_device_has_twenty_four_lanes(self) -> None:
        """Derived, not assumed: MCC's Drum Map group defines Note 1..Note 24."""
        assert DRUM_LANE_COUNT == 24

    def test_default_matches_arturias_custom_note_defaults(self) -> None:
        """The cross-check that the default is right."""
        assert DrumMap.chromatic(DEFAULT_CHROMATIC_LOW).notes == tuple(range(36, 60))

    def test_default_low_note_is_gm_kick(self) -> None:
        assert DEFAULT_CHROMATIC_LOW == 36
        assert GM_DRUM_NAMES[36] == "Bass Drum 1"

    def test_drum_channel_default(self) -> None:
        """globalParamId 79 (Drum output) defaults to 10, unlike tracks 1-4."""
        assert DEFAULT_DRUM_CHANNEL == 10


class TestLookup:
    @pytest.mark.parametrize("lane", range(DRUM_LANE_COUNT))
    def test_chromatic_round_trip(self, lane: int) -> None:
        drum_map = DrumMap.chromatic()
        assert drum_map.lane_for_note(drum_map.note_for_lane(lane)) == lane

    @pytest.mark.parametrize("lane", range(DRUM_LANE_COUNT))
    def test_custom_round_trip(self, lane: int) -> None:
        """A scrambled map must round-trip too, or reverse lookup is order-dependent."""
        notes = [(37 * i + 5) % 128 for i in range(DRUM_LANE_COUNT)]
        drum_map = DrumMap.custom(notes)
        assert drum_map.lane_for_note(drum_map.note_for_lane(lane)) == lane

    def test_unmapped_note_returns_none(self) -> None:
        """``None`` is the answer, not a nearest-lane guess."""
        assert DrumMap.chromatic(36).lane_for_note(100) is None
        assert DrumMap.chromatic(36).lane_for_note(35) is None

    def test_duplicate_notes_warn_and_resolve_to_lowest_lane(self) -> None:
        notes = [36] * 2 + list(range(38, 38 + DRUM_LANE_COUNT - 2))
        drum_map = DrumMap.custom(notes)
        assert drum_map.lane_for_note(36) == 0
        assert drum_map.warnings
        assert "lowest" in drum_map.warnings[0]

    def test_lane_outside_the_device_is_rejected(self) -> None:
        drum_map = DrumMap.chromatic()
        assert not drum_map.has_lane(DRUM_LANE_COUNT)
        with pytest.raises(ValueError, match="outside"):
            drum_map.note_for_lane(DRUM_LANE_COUNT)


class TestValidation:
    @pytest.mark.parametrize("count", [0, 23, 25])
    def test_rejects_wrong_length(self, count: int) -> None:
        with pytest.raises(ValueError, match="exactly 24"):
            DrumMap.custom([36] * count)

    @pytest.mark.parametrize("note", [-1, 128])
    def test_rejects_notes_outside_midi_range(self, note: int) -> None:
        notes = [note] + [40] * (DRUM_LANE_COUNT - 1)
        with pytest.raises(ValueError, match="outside 0-127"):
            DrumMap.custom(notes)

    @pytest.mark.parametrize("low", [-1, 104, 120])
    def test_rejects_chromatic_low_outside_the_devices_range(self, low: int) -> None:
        with pytest.raises(ValueError, match="outside 0-103"):
            DrumMap.chromatic(low)

    def test_the_devices_highest_low_note_still_fits(self) -> None:
        """103 + 23 = 126, one short of 127."""
        assert DrumMap.chromatic(103).notes[-1] == 126


class TestRendering:
    def test_label_names_the_gm_instrument(self) -> None:
        assert DrumMap.chromatic(36).label_for_lane(0) == "lane 0 -> C1 (36) Bass Drum 1"

    def test_label_without_a_gm_name_still_renders(self) -> None:
        drum_map = DrumMap.chromatic(0)
        assert drum_map.label_for_lane(0) == "lane 0 -> C-2 (0)"

    def test_label_for_a_lane_the_device_lacks_is_not_resolved(self) -> None:
        """Better to show the raw lane than to invent a note for it."""
        assert "out of range" in DrumMap.chromatic().label_for_lane(60)

    def test_describe_says_it_is_an_assumption(self) -> None:
        """The annotation is load-bearing: this is device state we cannot read."""
        assert DrumMap.chromatic(36).describe() == "chromatic from 36 (assumed - not in file)"
        assert "assumed" in DrumMap.custom(range(36, 60)).describe()


class TestConfig:
    def test_from_dict_chromatic(self) -> None:
        assert DrumMap.from_dict({"mode": "chromatic", "low": 40}).notes[0] == 40

    def test_from_dict_custom(self) -> None:
        notes = list(range(60, 60 + DRUM_LANE_COUNT))
        assert DrumMap.from_dict({"mode": "custom", "notes": notes}).notes == tuple(notes)

    def test_from_dict_rejects_unknown_mode(self) -> None:
        with pytest.raises(ValueError, match="unknown drum map mode"):
            DrumMap.from_dict({"mode": "sideways"})

    @pytest.mark.parametrize(
        ("spec", "expected_first"),
        [("chromatic:36", 36), ("chromatic:48", 48), ("chromatic", 36)],
    )
    def test_parse_chromatic(self, spec: str, expected_first: int) -> None:
        parsed = parse_drum_map(spec)
        assert parsed is not None
        assert parsed.notes[0] == expected_first

    def test_parse_custom(self) -> None:
        notes = ",".join(str(n) for n in range(36, 36 + DRUM_LANE_COUNT))
        parsed = parse_drum_map(f"custom:{notes}")
        assert parsed is not None
        assert parsed.notes == tuple(range(36, 60))

    def test_parse_none_means_do_not_resolve(self) -> None:
        assert parse_drum_map("none") is None

    def test_parse_rejects_nonsense(self) -> None:
        with pytest.raises(ValueError, match="unknown drum map"):
            parse_drum_map("sideways:1")

    def test_parse_reports_a_bad_number(self) -> None:
        with pytest.raises(ValueError, match="not a number"):
            parse_drum_map("chromatic:kick")

    def test_flag_beats_config_file(self, tmp_path: Path) -> None:
        config = tmp_path / "drum_map.json"
        config.write_text(json.dumps({"mode": "chromatic", "low": 50}), encoding="utf-8")
        resolved = resolve_drum_map("chromatic:36", config_path=config)
        assert resolved is not None
        assert resolved.notes[0] == 36

    def test_config_file_beats_the_built_in_default(self, tmp_path: Path) -> None:
        config = tmp_path / "drum_map.json"
        config.write_text(json.dumps({"mode": "chromatic", "low": 50}), encoding="utf-8")
        resolved = resolve_drum_map(None, config_path=config)
        assert resolved is not None
        assert resolved.notes[0] == 50

    def test_falls_back_to_the_documented_default(self, tmp_path: Path) -> None:
        resolved = resolve_drum_map(None, config_path=tmp_path / "absent.json")
        assert resolved is not None
        assert resolved.notes == tuple(range(36, 60))
