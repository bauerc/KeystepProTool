import json
import sys
from pathlib import Path
from typing import Any


def transform_packet(packet: dict[str, Any]) -> dict[str, Any]:
    """Flattens Wireshark packet JSON export into a structured dictionary."""
    layers = packet.get("_source", {}).get("layers", {})

    # Wireshark wraps most field values in a single-item list.
    def get_first(key: str, default: Any = None) -> Any:
        val = layers.get(key, default)
        if isinstance(val, list) and len(val) > 0:
            return val[0]
        return val

    src = get_first("usb.src")
    dst = get_first("usb.dst")
    direction = "outbound" if src == "host" else "inbound"

    sysex_hex = get_first("usbaudio.sysex.reassembled.data")

    return {
        "frame_number": int(get_first("frame.number", 0)),
        "timestamp_sec": float(get_first("frame.time_relative", 0.0)),
        "direction": direction,
        "src": src,
        "dst": dst,
        "endpoint": get_first("usb.endpoint_address"),
        "sysex_hex": sysex_hex,
        "length_bytes": len(bytes.fromhex(sysex_hex)) if sysex_hex else 0,
    }


def convert_json_to_jsonl(input_file: str, output_file: str) -> None:
    path_in = Path(input_file)
    path_out = Path(output_file)

    if not path_in.exists():
        print(f"Error: File '{input_file}' not found.")
        sys.exit(1)

    print(f"Loading {input_file}...")
    with open(path_in, encoding="utf-8") as f:
        data = json.load(f)

    print(f"Processing {len(data)} packets into JSONL...")
    with open(path_out, "w", encoding="utf-8") as f:
        for entry in data:
            cleaned_record = transform_packet(entry)
            f.write(json.dumps(cleaned_record) + "\n")

    print(f"Done! Written to '{output_file}'.")


if __name__ == "__main__":
    infile = sys.argv[1] if len(sys.argv) > 1 else "recall_sysex.json"
    outfile = sys.argv[2] if len(sys.argv) > 2 else "recall_sysex.jsonl"

    convert_json_to_jsonl(infile, outfile)
