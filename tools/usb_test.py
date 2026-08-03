import contextlib

import usb.backend.libusb1
import usb.core
import usb.util

# 1. Initialize backend directly using Homebrew's libusb path
LIBUSB_PATH = "/opt/homebrew/lib/libusb-1.0.dylib"
backend = usb.backend.libusb1.get_backend(find_library=lambda x: LIBUSB_PATH)

# 2. Locate KeyStep Pro (Arturia VID: 0x1c75, KSP PID: 0x0218)
dev = usb.core.find(idVendor=0x1C75, idProduct=0x0218, backend=backend)
if dev is None:
    raise ValueError("KeyStep Pro not detected. Check USB connection.")

print(f"Connected to KeyStep Pro (Bus {dev.bus}, Address {dev.address})")

# 3. Detach CoreMIDI kernel lock from Interface 2 (MIDI Streaming Interface)
INTERFACE_NUM = 2
if dev.is_kernel_driver_active(INTERFACE_NUM):
    try:
        dev.detach_kernel_driver(INTERFACE_NUM)
        print(f"Detached kernel driver from interface {INTERFACE_NUM}")
    except usb.core.USBError as e:
        print(f"Kernel detach warning: {e}")

# 4. Claim Interface 2
usb.util.claim_interface(dev, INTERFACE_NUM)

# 5. Track 2 Input -> Channel 1 SysEx payload (with USB MIDI 4-byte CIN headers)
track2_ch1_msg = bytes(
    [
        0x04,
        0xF0,
        0x00,
        0x20,  # CIN 0x04 + SysEx Start[cite: 1]
        0x04,
        0x6B,
        0x7F,
        0x42,  # Arturia Vendor ID + KeyStep Pro Model ID[cite: 1]
        0x04,
        0x02,
        0x00,
        0x41,  # Set Command (0x02) + Param Address[cite: 1]
        0x07,
        0x47,
        0x00,
        0xF7,  # Param Address + Value (0x00 = Ch 1) + SysEx End[cite: 1]
    ]
)

# 6. Write to Endpoint 0x01 OUT and release interface cleanly
ENDPOINT_OUT = 0x01
try:
    bytes_written = dev.write(ENDPOINT_OUT, track2_ch1_msg, timeout=1000)
    print(f"Successfully sent {bytes_written} bytes to Endpoint {hex(ENDPOINT_OUT)}!")
finally:
    with contextlib.suppress(Exception):
        usb.util.release_interface(dev, INTERFACE_NUM)
