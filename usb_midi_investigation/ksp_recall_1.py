import contextlib
import time

import usb.backend.libusb1
import usb.core
import usb.util

LIBUSB_PATH = "/opt/homebrew/lib/libusb-1.0.dylib"
LOG_FILE = "ksp_recall_1_log.txt"

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


def send_and_read(dev, sysex_bytes, label, timeout_sec=2.0):  # type: ignore
    print(f"\n---> Testing Scenario: {label}")
    print(f"Sending: {' '.join(f'{b:02x}' for b in sysex_bytes)}")

    # Send
    dev.write(ENDPOINT_OUT, frame_sysex_packet(sysex_bytes))

    # Listen
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


# ---------------------------------------------------------
# Test Sequences
# ---------------------------------------------------------
all_raw = []
all_clean = []

try:
    # 1. Establish initial identity lock first (Verified working)
    r, c = send_and_read(dev, [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], "0. Identity Handshake Lock")  # type: ignore
    all_raw.extend(r)
    all_clean.extend(c)
    time.sleep(0.2)

    # Variant A: Standard Project 1 Dump Request (Specifying Project Slot 0x00)
    r, c = send_and_read(
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x05, 0x01, 0x00, 0xF7],  # type: ignore
        "A. Project 1 Specific Dump (0x05 0x01 0x00)",
    )
    all_raw.extend(r)
    all_clean.extend(c)
    time.sleep(0.2)

    # Variant B: Global Parameter Request (Command 0x01 instead of 0x05)
    r, c = send_and_read(
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x01, 0x00, 0xF7],  # type: ignore
        "B. Memory Inquire Command (0x01 0x00)",
    )
    all_raw.extend(r)
    all_clean.extend(c)
    time.sleep(0.2)

    # Variant C: Direct Memory Dump Request (Device ID 0x00 + Command 0x1F)
    r, c = send_and_read(
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x00, 0x42, 0x10, 0x00, 0xF7],  # type: ignore
        "C. Extended Memory Dump Request (0x10 0x00)",
    )
    all_raw.extend(r)
    all_clean.extend(c)

    # ---------------------------------------------------------
    # Save Output
    # ---------------------------------------------------------
    clean_hex = " ".join(f"{b:02x}" for b in all_clean)
    with open(LOG_FILE, "w") as f:
        f.write("--- KEYSTEP PRO RECALL RESPONSE LOG ---\n")
        f.write(f"Cleaned SysEx Bytes:\n{clean_hex}\n\n")
        f.write("--- RAW USB PACKETS ---\n")
        for chunk in all_raw:
            f.write(" ".join(f"{b:02x}" for b in chunk) + "\n")

    print(f"\nLog written to '{LOG_FILE}'.")

finally:
    with contextlib.suppress(Exception):
        usb.util.release_interface(dev, INTERFACE_NUM)
