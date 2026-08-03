import contextlib
import os
import sys
import time
from datetime import datetime

import usb.backend.libusb1
import usb.core
import usb.util

LIBUSB_PATH = "/opt/homebrew/lib/libusb-1.0.dylib"
INTERFACE_NUM = 2
ENDPOINT_OUT = 0x01
ENDPOINT_IN = 0x81

# Setup ksp_logs directory and timestamped log file
LOG_DIR = "ksp_logs"
os.makedirs(LOG_DIR, exist_ok=True)
timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
log_filename = os.path.join(LOG_DIR, f"ksp_recall_log_recall_script_{timestamp}.txt")

log_file = open(log_filename, "w")  # noqa: SIM115


def log(msg: str) -> None:
    print(msg)
    log_file.write(msg + "\n")
    log_file.flush()


backend = usb.backend.libusb1.get_backend(find_library=lambda x: LIBUSB_PATH)
dev = usb.core.find(idVendor=0x1C75, idProduct=0x0218, backend=backend)

if dev is None:
    log("Error: KeyStep Pro not found.")
    sys.exit(1)

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


def extract_sequence_bytes(response_hex_list, sent_address_bytes):  # type: ignore
    """
    Strips the Command 0x0C status byte and mirrored address header,
    returning only the extracted data payload.
    """
    # Payload format: [01 (OK)] + [MIRRORED_ADDRESS_BYTES] + [DATA_PAYLOAD]
    header_offset = 1 + len(sent_address_bytes)
    if len(response_hex_list) > header_offset:
        return response_hex_list[header_offset:]
    return []


def query_paged_memory(address_bytes):  # type: ignore
    cmd = [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x0B, 0x01, *address_bytes, 0xF7]
    dev.write(ENDPOINT_OUT, frame_sysex_packet(cmd))

    clean_sysex = []
    start = time.time()

    while (time.time() - start) < 0.2:
        try:
            data = dev.read(ENDPOINT_IN, 512, timeout=50)
            if data:
                for idx in range(0, len(data), 4):
                    pkt = data[idx : idx + 4]
                    if len(pkt) == 4 and pkt[0] != 0x00:
                        clean_sysex.extend(pkt[1:])
        except usb.core.USBTimeoutError:
            continue

    hex_str = " ".join(f"{b:02x}" for b in clean_sysex)
    for pkt in hex_str.split("f7"):
        bytes_list = [x for x in pkt.strip().split() if x]
        if len(bytes_list) >= 8 and bytes_list[6] == "0c":
            raw_payload = bytes_list[7:]
            extracted_payload = extract_sequence_bytes(raw_payload, address_bytes)
            return raw_payload, extracted_payload

    return None, None


try:
    log("--- KeyStep Pro Sequence Memory Read ---")
    log(f"Logging output to: {log_filename}\n")

    log("--- 1. Link Check ---")
    dev.write(ENDPOINT_OUT, frame_sysex_packet([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]))
    time.sleep(0.1)

    # Testing sub-page variations for Track 1 Sequence Memory
    # Sweeping through sub-page index byte 5/6 to locate pitch data
    track1_subpage_queries = [
        [0x54, 0x03, 0x79, 0x01, 0x01, 0x00, 0x10],
        [0x54, 0x03, 0x79, 0x01, 0x01, 0x01, 0x10],
        [0x54, 0x03, 0x79, 0x01, 0x01, 0x02, 0x10],
        [0x54, 0x03, 0x79, 0x01, 0x01, 0x03, 0x10],
        [0x54, 0x03, 0x79, 0x01, 0x01, 0x04, 0x10],
        [0x54, 0x03, 0x79, 0x01, 0x01, 0x05, 0x10],
    ]

    log("\n--- 2. Executing Paged Track 1 Sequence Queries ---")
    for addr in track1_subpage_queries:
        addr_hex = " ".join(f"{b:02x}" for b in addr)
        log(f"Querying Address: {addr_hex}")

        raw_resp, clean_payload = query_paged_memory(addr)
        if raw_resp and clean_payload:
            log(f"  [RAW 0x0C Response]: {' '.join(raw_resp)}")
            log(f"  [EXTRACTED PAYLOAD]: {' '.join(clean_payload)}")
        else:
            log("  [NO RESPONSE / TIMEOUT]")
        log("-" * 50)
        time.sleep(0.02)

finally:
    log("\nExecution finished.")
    log_file.close()
    with contextlib.suppress(Exception):
        usb.util.release_interface(dev, INTERFACE_NUM)
