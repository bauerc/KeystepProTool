"""Virtual MIDI Proxy & AI-Readable SysEx Logger for KeyStep Pro & MCC.

Creates a virtual MIDI endpoint named 'KeyStep Pro' that intercepts, decodes,
and logs all SysEx traffic between Arturia MIDI Control Center (MCC) and the
physical KeyStep Pro hardware.

Outputs live human-readable terminal feeds and structured JSON Lines (.jsonl)
session captures. Supports single unified logs or separate direction logs
(MCC -> Hardware vs. Hardware -> MCC).
"""

import argparse
import json
import re
import sys
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any, Final, TextIO

import mido

REAL_DEVICE_NAME: Final = "KeyStep Pro"
ARTURIA_MANUFACTURER_ID: Final = (0x00, 0x20, 0x6B)


def unpack_7bit(data: Sequence[int] | bytes) -> bytes:
    """Unpack standard MIDI 7-bit bytes to raw 8-bit bytes (MSB group decoding)."""
    output = bytearray()
    i = 0
    while i < len(data):
        output.append(data[i] & 0x7F)
        i += 1
    return bytes(output)


def extract_ascii_strings(data: bytes, min_length: int = 3) -> list[str]:
    """Find readable ASCII sequences (e.g. parameter keys, filenames, JSON fragments)."""
    pattern = re.compile(rf"[\x20-\x7E]{{{min_length},}}")
    decoded = data.decode("latin1", errors="ignore")
    return pattern.findall(decoded)


def decode_sysex(raw_data: tuple[int, ...] | list[int] | bytes) -> dict[str, Any]:
    """Decode raw SysEx packet into structured metadata for AI consumption."""
    raw_bytes = bytes(raw_data)
    info: dict[str, Any] = {
        "raw_hex": " ".join(f"{b:02X}" for b in raw_bytes),
        "total_bytes": len(raw_bytes) + 2,  # Including F0 and F7
    }

    if len(raw_bytes) >= 3 and tuple(raw_bytes[:3]) == ARTURIA_MANUFACTURER_ID:
        info["is_arturia"] = True
        info["manufacturer"] = "Arturia"
        if len(raw_bytes) > 3:
            info["device_id"] = f"0x{raw_bytes[3]:02X}"
        if len(raw_bytes) > 4:
            info["command_id"] = f"0x{raw_bytes[4]:02X}"
        payload = raw_bytes[5:]
    else:
        info["is_arturia"] = False
        payload = raw_bytes

    info["payload_bytes"] = len(payload)
    info["payload_hex"] = " ".join(f"{b:02X}" for b in payload)

    ascii_strings = extract_ascii_strings(payload)
    if ascii_strings:
        info["ascii_strings"] = ascii_strings

    return info


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Intercept, decode, and log KeyStep Pro SysEx traffic for AI analysis."
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=None,
        help="Path to save unified JSON Lines log (or base path if --split is set).",
    )
    parser.add_argument(
        "--split",
        "-s",
        action="store_true",
        help="Split log into <stem>_mcc_to_hw.jsonl and <stem>_hw_to_mcc.jsonl.",
    )
    parser.add_argument(
        "--out-mcc-to-hw",
        type=Path,
        default=None,
        help="Explicit output path for MCC -> Hardware traffic log.",
    )
    parser.add_argument(
        "--out-hw-to-mcc",
        type=Path,
        default=None,
        help="Explicit output path for Hardware -> MCC traffic log.",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Print full decoded payload details to stdout.",
    )
    args = parser.parse_args()

    mcc_to_hw_file: TextIO | None = None
    hw_to_mcc_file: TextIO | None = None
    unified_file: TextIO | None = None

    if args.split and args.output:
        stem = args.output.stem
        parent = args.output.parent
        ext = args.output.suffix or ".jsonl"

        path_mcc = parent / f"{stem}_mcc_to_hw{ext}"
        path_hw = parent / f"{stem}_hw_to_mcc{ext}"

        parent.mkdir(parents=True, exist_ok=True)
        mcc_to_hw_file = path_mcc.open("a", encoding="utf-8")
        hw_to_mcc_file = path_hw.open("a", encoding="utf-8")
        print(f"📝 Logging MCC ➔ HW traffic to: {path_mcc.resolve()}")
        print(f"📝 Logging HW ➔ MCC traffic to: {path_hw.resolve()}")
    else:
        if args.out_mcc_to_hw:
            args.out_mcc_to_hw.parent.mkdir(parents=True, exist_ok=True)
            mcc_to_hw_file = args.out_mcc_to_hw.open("a", encoding="utf-8")
            print(f"📝 Logging MCC ➔ HW traffic to: {args.out_mcc_to_hw.resolve()}")

        if args.out_hw_to_mcc:
            out_hw = args.out_hw_to_mcc
            out_hw.parent.mkdir(parents=True, exist_ok=True)
            hw_to_mcc_file = out_hw.open("a", encoding="utf-8")
            print(f"📝 Logging HW ➔ MCC traffic to: {out_hw.resolve()}")

        if args.output and not (mcc_to_hw_file or hw_to_mcc_file):
            args.output.parent.mkdir(parents=True, exist_ok=True)
            unified_file = args.output.open("a", encoding="utf-8")
            print(f"📝 Logging unified session to: {args.output.resolve()}")

    print("🔍 Searching for physical KeyStep Pro USB MIDI ports...")
    try:
        input_names: list[str] = mido.get_input_names()
        output_names: list[str] = mido.get_output_names()
    except Exception as exc:
        print(f"❌ Failed to query MIDI ports: {exc}")
        return 1

    real_in_name = next((n for n in input_names if REAL_DEVICE_NAME in n), None)
    real_out_name = next((n for n in output_names if REAL_DEVICE_NAME in n), None)

    if not real_in_name or not real_out_name:
        print(f"❌ Could not find physical '{REAL_DEVICE_NAME}'. Plug it in and try again.")
        print(f"Available inputs:  {input_names}")
        print(f"Available outputs: {output_names}")
        return 1

    print(f"✅ Connected to physical input:  {real_in_name}")
    print(f"✅ Connected to physical output: {real_out_name}")

    try:
        real_in = mido.open_input(real_in_name)
        real_out = mido.open_output(real_out_name)
    except Exception as exc:
        print(f"❌ Failed to open physical KeyStep Pro ports: {exc}")
        return 1

    print(f"🚀 Creating Virtual MIDI Port: '{REAL_DEVICE_NAME}'...")
    try:
        virtual_in = mido.open_input(REAL_DEVICE_NAME, virtual=True)
        virtual_out = mido.open_output(REAL_DEVICE_NAME, virtual=True)
    except Exception as exc:
        print(f"❌ Failed to create virtual MIDI port: {exc}")
        real_in.close()
        real_out.close()
        return 1

    start_time = time.time()

    def record_packet(reported_direction: str, msg: Any) -> None:
        elapsed_ms = round((time.time() - start_time) * 1000, 2)
        is_sysex = msg.type == "sysex"
        direction = reported_direction

        sysex_info: dict[str, Any] = {}
        if is_sysex:
            sysex_info = decode_sysex(msg.data)
            raw_hex = sysex_info.get("raw_hex", "")
            payload_hex = sysex_info.get("payload_hex", "")

            if (
                raw_hex.startswith("7E 7F 06 02")
                or payload_hex.startswith("1C")
                or payload_hex.startswith("1D")
            ):
                direction = "HW_TO_MCC"
            elif (
                raw_hex.startswith("7E 7F 06 01")
                or sysex_info.get("payload_bytes", 0) >= 5
                or raw_hex.startswith("00 00 66")
            ):
                direction = "MCC_TO_HW"

        record: dict[str, Any] = {
            "timestamp_ms": elapsed_ms,
            "direction": direction,
            "type": msg.type,
        }

        if is_sysex:
            record["sysex"] = sysex_info

            cmd = sysex_info.get("command_id", "RAW")
            strings = sysex_info.get("ascii_strings", [])
            ascii_summary = f" | ASCII: {strings}" if strings else ""
            print(
                f"[{elapsed_ms:8.1f} ms] [{direction}] SysEx Cmd: {cmd} "
                f"({sysex_info['total_bytes']} bytes){ascii_summary}"
            )
            if args.verbose:
                print(f"  F0 {sysex_info['raw_hex']} F7")
        else:
            record["msg"] = str(msg)
            if args.verbose:
                print(f"[{elapsed_ms:8.1f} ms] [{direction}] {msg}")

        line = json.dumps(record) + "\n"

        if unified_file:
            unified_file.write(line)
            unified_file.flush()

        if direction == "MCC_TO_HW" and mcc_to_hw_file:
            mcc_to_hw_file.write(line)
            mcc_to_hw_file.flush()

        if direction == "HW_TO_MCC" and hw_to_mcc_file:
            hw_to_mcc_file.write(line)
            hw_to_mcc_file.flush()

    def handle_mcc_to_hardware(msg: Any) -> None:
        record_packet("MCC_TO_HW", msg)
        real_out.send(msg)

    def handle_hardware_to_mcc(msg: Any) -> None:
        record_packet("HW_TO_MCC", msg)
        virtual_out.send(msg)

    virtual_in.callback = handle_mcc_to_hardware
    real_in.callback = handle_hardware_to_mcc

    print("\n📡 Proxy active! Open Arturia MIDI Control Center now.")
    print("Press Ctrl+C to exit.\n")

    try:
        while True:
            time.sleep(0.5)
    except KeyboardInterrupt:
        print("\nStopping KeyStep Pro proxy...")
    finally:
        for f in (unified_file, mcc_to_hw_file, hw_to_mcc_file):
            if f is not None:
                f.close()
        virtual_in.close()
        virtual_out.close()
        real_in.close()
        real_out.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
