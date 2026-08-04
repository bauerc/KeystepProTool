import argparse
import sys
from pathlib import Path

# Opt for faster parsing if available in your environment
try:
    import orjson as json
except ImportError:
    import json  # type: ignore


def flatten_and_hexify(data, parent_key: str = "") -> list[str]:  # type:ignore
    """
    Recursively flattens JSON data and converts integers to hex strings.
    """
    items = []
    if isinstance(data, dict):
        for k, v in data.items():
            new_key = f"{parent_key}.{k}" if parent_key else k
            items.extend(flatten_and_hexify(v, new_key))
    elif isinstance(data, list):
        for i, v in enumerate(data):
            new_key = f"{parent_key}[{i}]"
            items.extend(flatten_and_hexify(v, new_key))
    elif isinstance(data, int):
        # Convert integers to 2-digit uppercase hex (standard for MIDI)
        # Handle negative numbers gracefully if any exist
        if data >= 0 and data <= 255:
            items.append((parent_key, f"0x{data:02X}"))
        else:
            items.append((parent_key, f"{data} (Out of standard byte range)"))
    else:
        # Keep strings, booleans, or nulls as they are for context
        items.append((parent_key, data))

    return items


def main() -> None:
    parser = argparse.ArgumentParser(description="Parse KeyStep Pro JSON to Hex")
    parser.add_argument("filepath", help="Path to the .json (or .KeyStepPro) file")
    args = parser.parse_args()

    file_path = Path(args.filepath)
    if not file_path.is_file():
        print(f"Error: File '{file_path}' not found.")
        sys.exit(1)

    # Load JSON data
    with open(file_path, "rb" if "orjson" in sys.modules else "r") as f:
        try:
            data = json.loads(f.read()) if "orjson" in sys.modules else json.load(f)
        except Exception as e:
            print(f"Failed to parse JSON: {e}")
            sys.exit(1)

    # Process and print
    flattened_data = flatten_and_hexify(data)

    print(f"--- Hexified JSON Map for: {file_path.name} ---\n")
    for key, value in flattened_data:
        print(f"{key}: {value}")


if __name__ == "__main__":
    main()
