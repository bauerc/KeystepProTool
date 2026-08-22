"""Diff tool for comparing two AI-readable KeyStep Pro SysEx capture files (.jsonl).

Identifies exact byte changes, sequence differences, and command payloads between
two capture sessions (e.g. before/after tweaking a hardware setting or pushing a project).
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    """Load JSON Lines capture log."""
    entries = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    return entries


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compare two .jsonl SysEx capture logs to find exact protocol diffs."
    )
    parser.add_argument("baseline", type=Path, help="Baseline capture log (.jsonl)")
    parser.add_argument("comparison", type=Path, help="Comparison capture log (.jsonl)")
    args = parser.parse_args()

    if not args.baseline.exists():
        print(f"❌ File not found: {args.baseline}")
        return 1
    if not args.comparison.exists():
        print(f"❌ File not found: {args.comparison}")
        return 1

    base_entries = load_jsonl(args.baseline)
    comp_entries = load_jsonl(args.comparison)

    print(f"📊 Baseline ({args.baseline.name}):   {len(base_entries)} packets")
    print(f"📊 Comparison ({args.comparison.name}): {len(comp_entries)} packets\n")

    base_sysex = [e for e in base_entries if e.get("type") == "sysex"]
    comp_sysex = [e for e in comp_entries if e.get("type") == "sysex"]

    print(f"--- SysEx Packets Count: Baseline={len(base_sysex)}, Comparison={len(comp_sysex)} ---")

    limit = min(len(base_sysex), len(comp_sysex))
    diff_count = 0

    for i in range(limit):
        b_info = base_sysex[i]["sysex"]
        c_info = comp_sysex[i]["sysex"]

        b_hex = b_info.get("raw_hex", "")
        c_hex = c_info.get("raw_hex", "")

        if b_hex != c_hex:
            diff_count += 1
            direction = base_sysex[i]["direction"]
            cmd = b_info.get("command_id", "RAW")
            print(f"\n⚡ Diff found at packet #{i + 1} [{direction}] Command {cmd}:")
            print(f"  - Baseline:   {b_hex}")
            print(f"  + Comparison: {c_hex}")

            b_bytes = bytes.fromhex(b_hex)
            c_bytes = bytes.fromhex(c_hex)
            if len(b_bytes) == len(c_bytes):
                changes = [
                    f"offset {idx}: 0x{b:02X} -> 0x{c:02X}"
                    for idx, (b, c) in enumerate(zip(b_bytes, c_bytes, strict=True))
                    if b != c
                ]
                print(f"    Changes ({len(changes)} bytes): {', '.join(changes)}")

    if len(base_sysex) != len(comp_sysex):
        print(
            f"\n⚠️ Packet length mismatch: {abs(len(base_sysex) - len(comp_sysex))} extra packets."
        )

    if diff_count == 0 and len(base_sysex) == len(comp_sysex):
        print("\n✅ Streams are identical!")

    return 0


if __name__ == "__main__":
    sys.exit(main())
