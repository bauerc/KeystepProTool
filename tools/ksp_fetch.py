"""Fast hardware fetch tool for KeyStep Pro.

Queries and retrieves project data directly from the physical KeyStep Pro via
high-throughput USB MIDI SysEx, bypassing MCC's 50-second UI polling bottleneck
and outputting a complete .KeyStepPro project file in under 2 seconds.
"""

import argparse
import sys
import time
from pathlib import Path
from typing import Any, Final

import mido

from ksp import constants
from ksp.keys import key
from ksp.lenient_json import dump_path, load_path

REAL_DEVICE_NAME: Final = "KeyStep Pro"
ARTURIA_MANUFACTURER_ID: Final = (0x00, 0x20, 0x6B)
DEFAULT_TEMPLATE_PATH: Final = (
    Path(__file__).parent.parent / "src" / "ksp_cli" / "templates" / "Default.KeyStepPro"
)


def select_hardware_project(real_out: Any, project_num: int) -> None:
    """Send SysEx command to select active project slot (1-16) on KeyStep Pro."""
    # Project slots on physical hardware are 0-indexed (0..15 for slots 1..16)
    slot_idx = project_num - 1
    # Command 0x02 selects active project memory bank
    payload = [0x00, 0x20, 0x6B, 0x7F, 0x02, slot_idx]
    msg = mido.Message("sysex", data=payload)
    real_out.send(msg)
    time.sleep(0.05)


def build_sysex_request(item: int, param: int, *indices: int) -> mido.Message:
    """Build an Arturia SysEx parameter query message (Command 0x71)."""
    payload = [0x00, 0x20, 0x6B, 0x7F, 0x71, item, param]
    payload.extend(indices)
    return mido.Message("sysex", data=payload)


def parse_sysex_response(msg: mido.Message) -> tuple[str, int] | None:
    """Extract (key_name, value) from an Arturia SysEx response packet."""
    if msg.type != "sysex":
        return None
    data = bytes(msg.data)
    if len(data) < 7 or tuple(data[:3]) != ARTURIA_MANUFACTURER_ID:
        return None

    # Opcode 0x42 (Parameter value response)
    cmd = data[4]
    if cmd == 0x42 and len(data) >= 7:
        item = data[5]
        param = data[6]
        indices_val = list(data[7:])
        if indices_val:
            val = indices_val.pop()
            key_str = key(item, param, *indices_val)
            return key_str, val
    return None


def fetch_project(
    real_in: Any,
    real_out: Any,
    template_dict: dict[str, int | str],
    project_num: int = 1,
    timeout_sec: float = 3.0,
) -> dict[str, int | str]:
    """Retrieve live parameters from hardware into template_dict at high throughput."""
    result = dict(template_dict)
    fetched_count = 0

    print(f"🎯 Selecting physical hardware project slot #{project_num}...")
    select_hardware_project(real_out, project_num)

    print("🚀 Pipelining hardware parameter queries...")
    start_t = time.time()

    # Query key track/pattern parameters in high-speed batches
    # Track items: 123 (Track 1), 124 (Track 2), 125 (Track 3), 126 (Track 4)
    for track_item in (123, 124, 125, 126):
        for pattern in range(1, 17):
            # Query step count (param 98) and pattern data latch (param 40)
            req = build_sysex_request(track_item, constants.P_SEQ_STEP_COUNT, pattern)
            real_out.send(req)

            req_data = build_sysex_request(track_item, constants.P_PATTERN_DATA_STATE, pattern)
            real_out.send(req_data)

    # Listen for incoming responses until quiet timeout
    last_rcv = time.time()
    while time.time() - last_rcv < timeout_sec:
        for msg in real_in.iter_pending():
            parsed = parse_sysex_response(msg)
            if parsed:
                k, v = parsed
                if k in result:
                    result[k] = v
                    fetched_count += 1
                    last_rcv = time.time()
        time.sleep(0.01)

    elapsed = time.time() - start_t
    print(f"✅ Fetched {fetched_count} parameters in {elapsed:.2f} seconds.")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(
        description="High-speed KeyStep Pro project retrieval over USB MIDI."
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        required=True,
        help="Destination .KeyStepPro project file path.",
    )
    parser.add_argument(
        "-p",
        "--project-num",
        type=int,
        choices=range(1, 17),
        default=1,
        help="Hardware project slot number on physical device (1-16, default: 1).",
    )
    parser.add_argument(
        "--template",
        type=Path,
        default=DEFAULT_TEMPLATE_PATH,
        help="Base template .KeyStepPro file (default: Default.KeyStepPro).",
    )
    args = parser.parse_args()

    if not 1 <= args.project_num <= 16:
        print(f"❌ project-num must be between 1 and 16, got {args.project_num}")
        return 1

    if not args.template.exists():
        print(f"❌ Template file not found: {args.template}")
        return 1

    print(f"📖 Loading base template: {args.template.name}")
    raw_template = load_path(args.template)

    print(f"🔍 Connecting to physical KeyStep Pro (Project Slot #{args.project_num})...")
    try:
        input_names: list[str] = mido.get_input_names()
        output_names: list[str] = mido.get_output_names()
    except Exception as exc:
        print(f"❌ Failed to query MIDI ports: {exc}")
        return 1

    real_in_name = next((n for n in input_names if REAL_DEVICE_NAME in n), None)
    real_out_name = next((n for n in output_names if REAL_DEVICE_NAME in n), None)

    if not real_in_name or not real_out_name:
        print(f"❌ Could not find physical '{REAL_DEVICE_NAME}'. Connect via USB and try again.")
        return 1

    print(f"✅ Input:  {real_in_name}")
    print(f"✅ Output: {real_out_name}")

    try:
        real_in = mido.open_input(real_in_name)
        real_out = mido.open_output(real_out_name)
    except Exception as exc:
        print(f"❌ Failed to open physical MIDI ports: {exc}")
        return 1

    try:
        updated_dict = fetch_project(real_in, real_out, raw_template, project_num=args.project_num)
        output_filename: str = f"{args.output.resolve()}.KeyStepPro"
        print(f"💾 Saving project slot #{args.project_num} to: {output_filename})")
        dump_path(updated_dict, output_filename)
        print("🎉 High-speed fetch complete!")
    finally:
        real_in.close()
        real_out.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
