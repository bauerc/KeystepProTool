import contextlib
import time

import usb.backend.libusb1
import usb.core
import usb.util

# --- CONFIGURATION ---
LIBUSB_PATH = "/opt/homebrew/lib/libusb-1.0.dylib"
SEQUENCE_FILE = "outbound_sysex_sequence.txt"
CLEAN_LOG_FILE = "ksp_clean_bytes_log.txt"
RAW_LOG_FILE = "ksp_raw_packets_log.txt"

INTERFACE_NUM = 2
ENDPOINT_OUT = 0x01
ENDPOINT_IN = 0x81

# Flag to disable routine print statements (set to True to suppress)
DISABLE_PRINT = True

# --- MANDATORY START STATEMENT ---
print("Starting KeyStep Pro handshake replay script...")
script_start_time = time.time()

# --- USB SETUP ---
try:
    backend = usb.backend.libusb1.get_backend(find_library=lambda x: LIBUSB_PATH)
    dev = usb.core.find(idVendor=0x1C75, idProduct=0x0218, backend=backend)

    if dev is None:
        print("FAILURE: KeyStep Pro not found.")
        raise ValueError("KeyStep Pro not found.")

    if dev.is_kernel_driver_active(INTERFACE_NUM):
        with contextlib.suppress(usb.core.USBError):
            dev.detach_kernel_driver(INTERFACE_NUM)

    usb.util.claim_interface(dev, INTERFACE_NUM)
except Exception as e:
    print(f"FAILURE: Initialization error occurred: {e}")
    raise


# --- FUNCTIONS ---
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


def send_and_read(dev, sysex_bytes, label):  # type: ignore
    if not DISABLE_PRINT:
        print(f"\n---> Testing Scenario: {label}")
        print(f"Sending: {' '.join(f'{b:02x}' for b in sysex_bytes)}")

    dev.write(ENDPOINT_OUT, frame_sysex_packet(sysex_bytes))

    raw_packets = []
    clean_sysex = []

    # Read continuously until the device stops sending data (short timeout)
    while True:
        try:
            data = dev.read(ENDPOINT_IN, 512, timeout=2)
            if data:
                raw_packets.append(data)
                for idx in range(0, len(data), 4):
                    pkt = data[idx : idx + 4]
                    if len(pkt) == 4 and pkt[0] != 0x00:
                        clean_sysex.extend(pkt[1:])
        except usb.core.USBTimeoutError:
            # Buffer is empty, exit immediately without waiting out a fixed window
            break

    if not DISABLE_PRINT:
        if clean_sysex:
            print(f" SUCCESS! Received {len(clean_sysex)} bytes.")
        else:
            print(" No response.")

    return raw_packets, clean_sysex


# --- MAIN REPLAY ROUTINE WITH INCREMENTAL FILE STREAMING ---
try:
    if not DISABLE_PRINT:
        print("Reading sequence file...")
    with open(SEQUENCE_FILE) as f:
        lines = f.readlines()

    # Open two distinct files simultaneously
    with open(CLEAN_LOG_FILE, "w") as clean_f, open(RAW_LOG_FILE, "w") as raw_f:
        clean_f.write("--- KEYSTEP PRO HANDSHAKE REPLAY LOG (CLEAN BYTES) ---\n")
        raw_f.write("--- KEYSTEP PRO HANDSHAKE REPLAY LOG (RAW PACKETS) ---\n")

        for line_idx, line in enumerate(lines):
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
                try:
                    r, c = send_and_read(dev, sysex_bytes, label)
                except Exception as e:
                    print(f"FAILURE: Error during send_and_read for '{label}': {e}")
                    raise

                # Stream output directly to memory buffers/files
                clean_hex = " ".join(f"{b:02x}" for b in c)
                clean_f.write(f'"{label}" : {clean_hex}\n')

                raw_f.write(f'"{label}" :\n')
                for chunk in r:
                    raw_f.write("  " + " ".join(f"{b:02x}" for b in chunk) + "\n")

                # Flush less frequently to maintain safety without lagging disk I/O
                if line_idx % 100 == 0:
                    clean_f.flush()
                    raw_f.flush()

    if not DISABLE_PRINT:
        print(f"\nReplay complete. Logs written to '{CLEAN_LOG_FILE}' and '{RAW_LOG_FILE}'.")

except Exception as e:
    print(f"FAILURE: An unexpected error occurred during execution: {e}")
    raise

finally:
    with contextlib.suppress(Exception):
        usb.util.release_interface(dev, INTERFACE_NUM)

    # --- MANDATORY TOTAL RUNTIME STATEMENT ---
    total_runtime = time.time() - script_start_time
    print(f"Total runtime: {total_runtime:.4f} seconds")
