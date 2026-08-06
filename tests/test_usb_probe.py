"""The Phase 1 probe harness, as far as it goes without a device.

These probes cannot be exercised in CI -- what they do is talk to hardware. What
can be held here is that all five are wired up and that the addresses they ask
for are the ones the design names, so a typo in an item or param number is not
discovered with the device already out on the desk.
"""

import sys
from pathlib import Path

import pytest

from ksp import sysex

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

import usb_probe


@pytest.mark.parametrize("name", ["identity", "scalar", "throughput", "prologue", "sentinel"])
def test_every_probe_is_reachable_from_the_command_line(name: str) -> None:
    args = usb_probe.build_parser().parse_args([name])
    assert args.probe == name
    assert name in usb_probe.PROBES


def test_the_handshake_flags_default_to_sending_both() -> None:
    """H1.4 is the only probe that turns them off, and it does so per variant."""
    args = usb_probe.build_parser().parse_args(["scalar"])
    assert not args.no_identity
    assert not args.no_prologue


def test_the_scalar_probe_asks_for_the_frame_the_capture_holds() -> None:
    """Frame 13, the first read of MCC's own plan."""
    assert sysex.build_read_request(usb_probe.SCALAR).hex() == "f000206b7f4201012578f7"


def test_the_throughput_probe_asks_for_a_pitch_chunk() -> None:
    """124_109_1_1_1, count 16 -- the request H1.3 re-issues at 64."""
    assert (
        sysex.build_read_request(usb_probe.THROUGHPUT).hex() == "f000206b7f420b016d037c01010110f7"
    )


def test_the_sentinel_probe_addresses_the_pattern_default_pitch() -> None:
    """One index, count 1: the same shape ``bulk_plan`` uses for 123_117_<pat>,
    which is where every 0xFF in the capture sits."""
    request = sysex.ReadRequest(
        item=usb_probe.SENTINEL_ITEM, param=usb_probe.SENTINEL_PARAM, indices=(1,), count=1
    )
    assert sysex.build_read_request(request).hex() == "f000206b7f420b0175017b0101f7"
    assert list(usb_probe.PATTERNS) == list(range(1, 17))
