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
raw_logs = {}
clean_logs = {}

try:
    # 1. Establish initial identity lock first (Verified working)
    label_0 = "0. Identity Handshake Lock"
    r, c = send_and_read(dev, [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], label_0)  # type: ignore
    raw_logs[label_0] = r
    clean_logs[label_0] = c
    time.sleep(0.2)

    # Variant A: Standard Project 1 Dump Request (Specifying Project Slot 0x00)
    label_a = "A. Project 1 Specific Dump (0x05 0x01 0x00)"
    r, c = send_and_read(
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x05, 0x01, 0x00, 0xF7],  # type: ignore
        label_a,
    )
    raw_logs[label_a] = r
    clean_logs[label_a] = c
    time.sleep(0.2)

    # Variant B: Global Parameter Request (Command 0x01 instead of 0x05)
    label_b = "B. Memory Inquire Command (0x01 0x00)"
    r, c = send_and_read(
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x01, 0x00, 0xF7],  # type: ignore
        label_b,
    )
    raw_logs[label_b] = r
    clean_logs[label_b] = c
    time.sleep(0.2)

    # Variant C: Direct Memory Dump Request (Device ID 0x00 + Command 0x1F)
    label_c = "C. Extended Memory Dump Request (0x10 0x00)"
    r, c = send_and_read(
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x00, 0x42, 0x10, 0x00, 0xF7],  # type: ignore
        label_c,
    )
    raw_logs[label_c] = r
    clean_logs[label_c] = c

    # Test 1: Standard Parameter Read (Address 25 78)
    label_1 = "Test 1: Read Parameter (0x01 0x01) at Address 25 78"
    r, c = send_and_read(  # type: ignore
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x01, 0x01, 0x25, 0x78, 0xF7],
        label_1,
    )
    raw_logs[label_1] = r
    clean_logs[label_1] = c
    time.sleep(0.1)

    # Test 2: Structured Block Read for Track 1
    label_2 = "Test 2: Read Track 1 Metadata (0x0B 0x01 0x26 ...)"
    r, c = send_and_read(  # type: ignore
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x0B, 0x01, 0x26, 0x01, 0x79, 0x01, 0x01, 0xF7],
        label_2,
    )
    raw_logs[label_2] = r
    clean_logs[label_2] = c
    time.sleep(0.1)

    # Test 3: Bulk Data Read (16 Bytes from Track 1 Sequence)
    label_3 = "Test 3: Bulk 16-byte Data Read (Track 1 Sequence)"
    r, c = send_and_read(  # type: ignore
        dev,
        [
            0xF0,
            0x00,
            0x20,
            0x6B,
            0x7F,
            0x42,
            0x0B,
            0x01,
            0x54,
            0x03,
            0x79,
            0x01,
            0x05,
            0x01,
            0x10,
            0xF7,
        ],
        label_3,
    )
    raw_logs[label_3] = r
    clean_logs[label_3] = c
    time.sleep(0.1)

    # Test 4: Bulk Data Read (16 Bytes from Track 2 Sequence)
    label_4 = "Test 4: Bulk 16-byte Data Read (Track 2 Sequence)"
    r, c = send_and_read(  # type: ignore
        dev,
        [
            0xF0,
            0x00,
            0x20,
            0x6B,
            0x7F,
            0x42,
            0x0B,
            0x01,
            0x54,
            0x03,
            0x79,
            0x02,
            0x05,
            0x01,
            0x10,
            0xF7,
        ],
        label_4,
    )
    raw_logs[label_4] = r
    clean_logs[label_4] = c
    time.sleep(0.1)

    # ---------------------------------------------------------
    # NEW TARGETED TESTS
    # ---------------------------------------------------------

    # Test 5: Targeted Parameter Read for Track 1, Pitch, Pattern 1
    label_5 = "Test 5: Read Target Track 1, Pitch, Pattern 1"
    r, c = send_and_read(  # type: ignore
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x01, 0x01, 0x7B, 0x6D, 0x01, 0xF7],
        label_5,
    )
    raw_logs[label_5] = r
    clean_logs[label_5] = c
    time.sleep(0.1)

    # Test 6: Bulk Data Read variation for Track 1, Pitch, Pattern 1
    label_6 = "Test 6: Bulk 16-byte Read for Target Track 1, Pitch, Pattern 1"
    r, c = send_and_read(  # type: ignore
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x0B, 0x01, 0x7B, 0x6D, 0x01, 0x10, 0xF7],
        label_6,
    )
    raw_logs[label_6] = r
    clean_logs[label_6] = c
    time.sleep(0.1)

    # Test 7: Full 5-Byte Address Parameter Read for 123_109_1_1_2
    label_7 = "Test 7: Read Specific Note at 123_109_1_1_2"
    r, c = send_and_read(  # type: ignore
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x01, 0x01, 0x7B, 0x6D, 0x01, 0x01, 0x02, 0xF7],
        label_7,
    )
    raw_logs[label_7] = r
    clean_logs[label_7] = c
    time.sleep(0.1)

    # Test 8: Corrected Block Read for Track 1, Pitch, Pattern 1
    label_8 = "Test 8: Block Read Track 1 Pitch Pattern 1"
    r, c = send_and_read(  # type: ignore
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x0B, 0x01, 0x7B, 0x6D, 0x01, 0x01, 0x01, 0x10, 0xF7],
        label_8,
    )
    raw_logs[label_8] = r
    clean_logs[label_8] = c
    time.sleep(0.1)

    # Test 9: Universal Device Inquiry
    label_9 = "Test 9: Universal Device Inquiry"
    r, c = send_and_read(  # type: ignore
        dev,
        [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7],
        label_9,
    )
    raw_logs[label_9] = r
    clean_logs[label_9] = c
    time.sleep(0.1)

    # Test 10: Adjusted Global Parameter Read (using verified 0x02 command structure)
    label_10 = "Test 10: Global Parameter Block Request"
    r, c = send_and_read(  # type: ignore
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x02, 0x01, 0x00, 0x00, 0x00, 0xF7],
        label_10,
    )
    raw_logs[label_10] = r
    clean_logs[label_10] = c
    time.sleep(0.1)

    # Test 11: Adjusted Track 1 Pattern Step 1 Probing (using verified 0x02 command structure)
    label_11 = "Test 11: Track 1 Pattern Step 1 Probing"
    r, c = send_and_read(  # type: ignore
        dev,
        [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x02, 0x01, 0x7B, 0x6D, 0x02, 0xF7],
        label_11,
    )
    raw_logs[label_11] = r
    clean_logs[label_11] = c
    time.sleep(0.1)
    # ---------------------------------------------------------
    # Save Output
    # ---------------------------------------------------------
    with open(LOG_FILE, "w") as f:
        f.write("--- KEYSTEP PRO RECALL RESPONSE LOG (CLEAN BYTES) ---\n")
        for test_name, c_bytes in clean_logs.items():
            clean_hex = " ".join(f"{b:02x}" for b in c_bytes)
            f.write(f'"{test_name}" : {clean_hex}\n')

        f.write("\n--- KEYSTEP PRO RECALL RESPONSE LOG (RAW PACKETS) ---\n")
        for test_name, r_packets in raw_logs.items():
            f.write(f'"{test_name}" :\n')
            for chunk in r_packets:
                f.write("  " + " ".join(f"{b:02x}" for b in chunk) + "\n")

    print(f"\nLog written to '{LOG_FILE}'.")

finally:
    with contextlib.suppress(Exception):
        usb.util.release_interface(dev, INTERFACE_NUM)
