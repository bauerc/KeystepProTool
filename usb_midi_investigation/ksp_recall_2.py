import contextlib
import time

import usb.backend.libusb1
import usb.core
import usb.util

LIBUSB_PATH = "/opt/homebrew/lib/libusb-1.0.dylib"
LOG_FILE = "ksp_recall_2_log.txt"

INTERFACE_NUM = 2
ENDPOINT_OUT = 0x01
ENDPOINT_IN = 0x81

backend = usb.backend.libusb1.get_backend(find_library=lambda x: LIBUSB_PATH)
dev = usb.core.find(idVendor=0x1C75, idProduct=0x0218, backend=backend)

if dev is None:
    raise ValueError("KeyStep Pro not found.")

if dev.is_kernel_driver_active(INTERFACE_NUM):
    with contextlib.suppress(usb.core.USBError):
        dev.detach_kernel_driver(INTERFACE_NUM)

usb.util.claim_interface(dev, INTERFACE_NUM)


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
                packet = [cn_shift | cin] + chunk + [0x00] * (2 - idx)  # type: ignore
                i += idx + 1
            else:
                cin = 0x04
                packet = [cn_shift | cin, *chunk]
                i += 3
        else:
            chunk = sysex_bytes[i:]
            cin = 0x05 + len(chunk) - 1
            packet = [cn_shift | cin] + chunk + [0x00] * (3 - len(chunk))  # type: ignore
            i += len(chunk)
        framed.extend(packet)
    return bytes(framed)


def send_and_read(dev, sysex_bytes, timeout_sec=1.5):  # type: ignore
    dev.write(ENDPOINT_OUT, frame_sysex_packet(sysex_bytes))
    raw_packets, clean_sysex = [], []
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

    return raw_packets, clean_sysex


all_raw = []
all_clean = []

try:
    print("--- STEP 1: Handshake ---")
    r, c = send_and_read(dev, [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], timeout_sec=0.5)  # type: ignore
    all_raw.extend(r)
    all_clean.extend(c)

    print("--- STEP 2: Initiate Dump Mode (Scenario A) ---")
    # Sending the exact packet that produced the 9-byte ACK
    r, c = send_and_read(
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x05, 0x01, 0x00, 0xF7],
        timeout_sec=0.5,  # type: ignore
    )
    all_raw.extend(r)
    all_clean.extend(c)

    ack_hex = " ".join(f"{b:02x}" for b in c)
    print(f"Received ACK from KSP: {ack_hex}")

    print("\n--- STEP 3: Requesting Sequence Data Blocks (Tracks 1-4 & RAM Buffer) ---")
    # Paging through sub-addresses 0x00 to 0x08 following the ACK
    for sub_addr in range(0x00, 0x06):
        # Format: [0xF0, Arturia_ID, Target, KSP_ID, Cmd_0x05, Dump_0x02, SubAddress, EOX]
        cmd = [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x05, 0x02, sub_addr, 0xF7]
        print(f"Fetching Block {hex(sub_addr)}...")

        r, c = send_and_read(dev, cmd, timeout_sec=1.5)  # type: ignore
        all_raw.extend(r)
        all_clean.extend(c)
        print(f"  -> Returned {len(c)} bytes.")
        time.sleep(0.1)

    # ---------------------------------------------------------
    # Save Output
    # ---------------------------------------------------------
    clean_hex = " ".join(f"{b:02x}" for b in all_clean)
    print(f"\nTotal Captured: {len(all_clean)} bytes.")

    with open(LOG_FILE, "w") as f:
        f.write("--- KEYSTEP PRO RECALL RESPONSE LOG ---\n")
        f.write(f"Cleaned SysEx Bytes:\n{clean_hex}\n\n")
        f.write("--- RAW USB PACKETS ---\n")
        for chunk in all_raw:
            f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")

    print(f"Log updated in '{LOG_FILE}'.")

finally:
    with contextlib.suppress(Exception):
        usb.util.release_interface(dev, INTERFACE_NUM)
