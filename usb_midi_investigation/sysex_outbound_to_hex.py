import json
import os

# --- CONFIGURATION ---
INPUT_JSONL = "usb_midi_investigation/sysex_until_project_1_track_1_pattern_1.jsonl"
OUTPUT_FILE = "outbound_sysex_sequence.txt"
START_FRAME = 1


def process_jsonl() -> None:
    extracted_messages = []

    if not os.path.exists(INPUT_JSONL):
        print(f"Error: {INPUT_JSONL} not found. Please check the file path.")
        return

    with open(INPUT_JSONL) as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue

            try:
                data = json.loads(line)

                # Pull keys based on your specific JSON structure
                frame_num = data.get("frame_number")
                direction = data.get("direction")
                sysex_hex = data.get("sysex_hex")

                # Skip if essential keys are missing
                if frame_num is None or not sysex_hex:
                    continue

                # Filter for frames >= START_FRAME and outbound messages
                if int(frame_num) >= START_FRAME and direction == "outbound":
                    extracted_messages.append({"frame": int(frame_num), "hex": sysex_hex})

            except json.JSONDecodeError:
                print(f"Error decoding JSON on line {line_num}")
                continue

    if not extracted_messages:
        print(
            "\nNo messages extracted. Double-check that your file contains messages"
            " where 'direction' is exactly 'outbound'."
        )
        return

    # Write to readable output file
    with open(OUTPUT_FILE, "w") as f:
        f.write(f"# Outbound SysEx extracted from frame {START_FRAME} onwards\n")
        f.write("# Format: [Frame Number] | [Clean SysEx Bytes]\n\n")

        for msg in extracted_messages:
            # Clean up the hex string and add spaces for readability/PyUSB parsing
            raw_hex = msg["hex"].replace(" ", "").replace(":", "").replace("0x", "")
            spaced_hex = " ".join(raw_hex[i : i + 2] for i in range(0, len(raw_hex), 2))

            f.write(f"Frame {msg['frame']} | {spaced_hex}\n")

    print(f"\nSUCCESS! Extracted {len(extracted_messages)} outbound messages to '{OUTPUT_FILE}'.")


if __name__ == "__main__":
    process_jsonl()
