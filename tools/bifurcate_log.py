"""Bifurcation & Protocol Classifier for KeyStep Pro SysEx Capture Logs.

Takes a capture log (.jsonl) and accurately classifies each packet into
MCC -> Hardware vs. Hardware -> MCC based on Arturia SysEx opcodes and payloads.
Fixes logs where MCC connected directly to physical MIDI endpoints.
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def classify_direction(entry: dict[str, Any]) -> str:
    """Classify packet direction based on Arturia SysEx protocol structure."""
    if entry.get("type") != "sysex":
        return str(entry.get("direction", "UNKNOWN"))

    sysex = entry.get("sysex", {})
    raw_hex = str(sysex.get("raw_hex", ""))
    payload_hex = str(sysex.get("payload_hex", ""))

    # Universal Identity Request / Reply
    if raw_hex.startswith("7E 7F 06 02"):
        return "HW_TO_MCC"
    if raw_hex.startswith("7E 7F 06 01"):
        return "MCC_TO_HW"

    # Arturia Proprietary SysEx (00 20 6B ...)
    if sysex.get("is_arturia"):
        # ACK (1C 00) or NACK (1D 00) from hardware
        if payload_hex.startswith("1C") or payload_hex.startswith("1D"):
            return "HW_TO_MCC"

        # Parameter query/set commands from MCC typically carry 5+ payload bytes (item, param, val)
        if sysex.get("payload_bytes", 0) >= 5:
            return "MCC_TO_HW"

    # Generic fallback
    if raw_hex.startswith("00 00 66"):
        return "MCC_TO_HW"

    return str(entry.get("direction", "UNKNOWN"))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Bifurcate and classify KeyStep Pro SysEx capture files."
    )
    parser.add_argument("input_log", type=Path, help="Input capture log (.jsonl)")
    parser.add_argument(
        "--output-prefix",
        "-o",
        type=Path,
        default=None,
        help="Output prefix (default: input file stem)",
    )
    args = parser.parse_args()

    if not args.input_log.exists():
        print(f"❌ Input log not found: {args.input_log}")
        return 1

    prefix = args.output_prefix or args.input_log.parent / args.input_log.stem
    path_mcc = Path(f"{prefix}_mcc_to_hw.jsonl")
    path_hw = Path(f"{prefix}_hw_to_mcc.jsonl")

    path_mcc.parent.mkdir(parents=True, exist_ok=True)

    mcc_count = 0
    hw_count = 0

    print(f"📖 Reading: {args.input_log.resolve()}")
    with (
        args.input_log.open("r", encoding="utf-8") as fin,
        path_mcc.open("w", encoding="utf-8") as fmcc,
        path_hw.open("w", encoding="utf-8") as fhw,
    ):
        for line in fin:
            line_str = line.strip()
            if not line_str:
                continue

            entry = json.loads(line_str)
            direction = classify_direction(entry)
            entry["direction"] = direction
            new_line = json.dumps(entry) + "\n"

            if direction == "MCC_TO_HW":
                fmcc.write(new_line)
                mcc_count += 1
            else:
                fhw.write(new_line)
                hw_count += 1

    print("✅ Bifurcation complete!")
    print(f"  - MCC ➔ Hardware ({mcc_count} packets): {path_mcc.resolve()}")
    print(f"  - Hardware ➔ MCC ({hw_count} packets): {path_hw.resolve()}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
