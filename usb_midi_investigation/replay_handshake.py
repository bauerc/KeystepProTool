import contextlib
import time

import usb.backend.libusb1
import usb.core
import usb.util

# --- CONFIGURATION ---
LIBUSB_PATH = "/opt/homebrew/lib/libusb-1.0.dylib"
SEQUENCE_FILE = "outbound_sysex_sequence.txt"
LOG_FILE = "ksp_handshake_replay_log.txt"

INTERFACE_NUM = 2
ENDPOINT_OUT = 0x01
ENDPOINT_IN = 0x81

# --- USB SETUP ---
backend = usb.backend.libusb1.get_backend(find_library=lambda x: LIBUSB_PATH)
dev = usb.core.find(idVendor=0x1C75, idProduct=0x0218, backend=backend)

if dev is None:
    raise ValueError("KeyStep Pro not found.")

if dev.is_kernel_driver_active(INTERFACE_NUM):
    with contextlib.suppress(usb.core.USBError):
        dev.detach_kernel_driver(INTERFACE_NUM)

usb.util.claim_interface(dev, INTERFACE_NUM)


# --- YOUR FUNCTIONS ---
def frame_sysex_packet(sysex_bytes: bytes, cable_num: int = 0) -> bytes:
    cn_shift = (cable_num & 0x0F) << 4
    framed = []
    i = 0
    length = len(sysex_bytes)

    while i < length:
        remaining = length - i
        if remaining >= 3:
            chunk = sysex_bytes[i : i + 3]
            if 0xF7 in chunk:
                idx = chunk.index(0xF7)
                cin = 0x05 + idx
                packet = [cn_shift | cin] + list(chunk) + [0x00] * (2 - idx)
                i += idx + 1
            else:
                cin = 0x04
                packet = [cn_shift | cin, *list(chunk)]
                i += 3
        else:
            chunk = sysex_bytes[i:]
            cin = 0x05 + len(chunk) - 1
            packet = [cn_shift | cin] + list(chunk) + [0x00] * (3 - len(chunk))
            i += len(chunk)
        framed.extend(packet)
    return bytes(framed)


def send_and_read(dev, sysex_bytes, label, timeout_sec=2.0):  # type: ignore
    print(f"\n---> Testing Scenario: {label}")
    print(f"Sending: {' '.join(f'{b:02x}' for b in sysex_bytes)}")

    dev.write(ENDPOINT_OUT, frame_sysex_packet(sysex_bytes))

    raw_packets = []
    clean_sysex = []
    start = time.time()

    while (time.time() - start) < timeout_sec:
        try:
            data = dev.read(ENDPOINT_IN, 512, timeout=100)
            if data:
                raw_packets.append(data)
                for idx in range(0, len(data), 4):
                    pkt = data[idx : idx + 4]
                    if len(pkt) == 4 and pkt[0] != 0x00:
                        clean_sysex.extend(pkt[1:])
        except usb.core.USBTimeoutError:
            continue

    if clean_sysex:
        print(f" SUCCESS! Received {len(clean_sysex)} bytes.")
    else:
        print(" No response.")

    return raw_packets, clean_sysex


# --- MAIN REPLAY ROUTINE ---
raw_logs = {}
clean_logs = {}

try:
    print("Reading sequence file...")
    with open(SEQUENCE_FILE) as f:
        lines = f.readlines()

    for line in lines:
        line = line.strip()
        # Skip comments and empty lines
        if not line or line.startswith("#"):
            continue

        # Parse the output format "Frame 5497 | f0 00 20 ..."
        if "|" in line:
            label, hex_data = line.split("|")
            label = label.strip()
            hex_data = hex_data.strip()

            # Convert hex string to byte array
            sysex_bytes = bytes.fromhex(hex_data)

            # Execute
            r, c = send_and_read(dev, sysex_bytes, label, timeout_sec=0.5)
            raw_logs[label] = r
            clean_logs[label] = c

            # Brief pause between sequential commands to allow the device buffer to clear
            time.sleep(0.1)

    # --- SAVE OUTPUT ---
    with open(LOG_FILE, "w") as f:
        f.write("--- KEYSTEP PRO HANDSHAKE REPLAY LOG (CLEAN BYTES) ---\n")
        for test_name, c_bytes in clean_logs.items():
            clean_hex = " ".join(f"{b:02x}" for b in c_bytes)
            f.write(f'"{test_name}" : {clean_hex}\n')

        f.write("\n--- KEYSTEP PRO HANDSHAKE REPLAY LOG (RAW PACKETS) ---\n")
        for test_name, r_packets in raw_logs.items():
            f.write(f'"{test_name}" :\n')
            for chunk in r_packets:
                f.write("  " + " ".join(f"{b:02x}" for b in chunk) + "\n")

    print(f"\nReplay complete. Log written to '{LOG_FILE}'.")

finally:
    with contextlib.suppress(Exception):
        usb.util.release_interface(dev, INTERFACE_NUM)
