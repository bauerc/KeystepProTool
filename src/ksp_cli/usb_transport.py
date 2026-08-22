"""Raw USB transport for the SysEx read protocol: the one place pyusb may appear."""

import time
from functools import partial
from types import TracebackType
from typing import Any, Final

from ksp import sysex

VENDOR_ID: Final = 0x1C75
PRODUCT_ID: Final = 0x0218
INTERFACE: Final = 2
EP_OUT: Final = 0x01
EP_IN: Final = 0x81

#: Tried in order when pyusb's own search finds no backend.
LIBUSB_PATHS: Final = (
    "/opt/homebrew/lib/libusb-1.0.dylib",
    "/usr/local/lib/libusb-1.0.dylib",
)

#: Long enough for the device to answer, short enough that a wrong interface
#: or a busy MCC is a failure rather than a hang.
DEFAULT_TIMEOUT_MS: Final = 1000

#: Payload bytes carried by each SysEx code index number.
_CIN_LENGTHS: Final = {0x04: 3, 0x05: 1, 0x06: 2, 0x07: 3}
_CIN_TERMINAL: Final = frozenset((0x05, 0x06, 0x07))

_PACKET = 4
_READ_CHUNK = 512


class TransportError(Exception):
    pass


def frame_sysex(payload: bytes, cable: int = 0) -> bytes:
    """A SysEx message as 4-byte USB-MIDI packets."""
    high = (cable & 0x0F) << 4
    packets = bytearray()
    offset = 0
    while offset < len(payload):
        chunk = payload[offset : offset + 3]
        if sysex.END in chunk:
            tail = chunk.index(sysex.END) + 1
            chunk = chunk[:tail]
            cin = 0x04 + tail  # 1, 2 or 3 remaining bytes -> 0x05, 0x06, 0x07
        else:
            cin = 0x04
        packets.append(high | cin)
        packets.extend(chunk.ljust(3, b"\x00"))
        offset += len(chunk)
    return bytes(packets)


def deframe(packets: bytes) -> list[bytes]:
    """The complete SysEx messages carried by a run of USB-MIDI packets.
    The code index number says how many of a packet's three bytes are real."""
    frames: list[bytes] = []
    current = bytearray()
    for offset in range(0, len(packets) - _PACKET + 1, _PACKET):
        packet = packets[offset : offset + _PACKET]
        cin = packet[0] & 0x0F
        length = _CIN_LENGTHS.get(cin)
        if length is None:  # padding, or channel MIDI sharing the endpoint
            continue
        current.extend(packet[1 : 1 + length])
        if cin in _CIN_TERMINAL:
            frames.append(bytes(current))
            current.clear()
    return frames


class UsbMidiTransport:
    """Interface 2 of an attached KeyStep Pro, as request-in reply-out."""

    def __init__(self, timeout_ms: int = DEFAULT_TIMEOUT_MS) -> None:
        self.timeout_ms = timeout_ms
        self._device: Any = None
        self._detached = False

    def __enter__(self) -> "UsbMidiTransport":
        self.open()
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()

    def open(self) -> None:
        core, util, backend = _import_pyusb()
        device = core.find(idVendor=VENDOR_ID, idProduct=PRODUCT_ID, backend=backend)
        if device is None:
            raise TransportError(
                f"no KeyStep Pro at {VENDOR_ID:#06x}:{PRODUCT_ID:#06x} "
                "-- is it plugged in over USB and powered on?"
            )

        # macOS reports the class driver as active but refuses to detach it, and
        # claiming the interface works anyway; only a real detach is undone on close.
        try:
            if device.is_kernel_driver_active(INTERFACE):
                device.detach_kernel_driver(INTERFACE)
                self._detached = True
        except (NotImplementedError, core.USBError):
            pass

        try:
            util.claim_interface(device, INTERFACE)
        except core.USBError as error:
            raise TransportError(
                f"cannot claim interface {INTERFACE}: {error}. "
                "macOS binds this interface to its own USB-MIDI driver and will "
                "not release it, so the probes need root: re-run under sudo. "
                "Close MIDI Control Center first -- it holds the device too."
            ) from error

        self._device = device
        self._drain()

    def close(self) -> None:
        if self._device is None:
            return
        _, util, _ = _import_pyusb()
        util.release_interface(self._device, INTERFACE)
        if self._detached:
            self._device.attach_kernel_driver(INTERFACE)
            self._detached = False
        util.dispose_resources(self._device)
        self._device = None

    def send(self, payload: bytes) -> None:
        """Write one message and expect nothing back, as the prologue needs."""
        self._require_open().write(EP_OUT, frame_sysex(payload), timeout=self.timeout_ms)

    def exchange(self, request: bytes) -> bytes:
        """Write one request and return its reply, consuming the trailing ack."""
        self.send(request)
        frames = self._read_frames()
        replies = [frame for frame in frames if frame != sysex.ACK]
        if not replies:
            raise TransportError(f"no reply to {request.hex()}")
        if len(replies) > 1:
            raise TransportError(
                f"{len(replies)} replies to {request.hex()}: "
                + ", ".join(frame.hex() for frame in replies)
            )
        return replies[0]

    def _read_frames(self) -> list[bytes]:
        """Read until the device's ack arrives, or the timeout expires.
        Traffic is strictly serialized, so the ack ends the transaction."""
        core, _, _ = _import_pyusb()
        device = self._require_open()
        packets = bytearray()
        deadline = time.monotonic() + self.timeout_ms / 1000
        while time.monotonic() < deadline:
            try:
                packets.extend(device.read(EP_IN, _READ_CHUNK, timeout=self.timeout_ms))
            except core.USBTimeoutError:
                break
            frames = deframe(bytes(packets))
            if sysex.ACK in frames:
                return frames
        frames = deframe(bytes(packets))
        if not frames:
            raise TransportError(f"timed out after {self.timeout_ms} ms waiting for a reply")
        return frames

    def _drain(self) -> None:
        """Discard anything left in the endpoint from an earlier run."""
        core, _, _ = _import_pyusb()
        while True:
            try:
                self._require_open().read(EP_IN, _READ_CHUNK, timeout=2)
            except core.USBTimeoutError:
                return

    def _require_open(self) -> Any:
        if self._device is None:
            raise TransportError("transport is not open")
        return self._device


def _at(path: str, _name: str) -> str:
    """A ``find_library`` that ignores the name and answers with one path."""
    return path


def _import_pyusb() -> tuple[Any, Any, Any]:
    """pyusb and a working backend, imported late so the extra stays optional."""
    try:
        import usb.backend.libusb1
        import usb.core
        import usb.util
    except ImportError as error:
        raise TransportError(
            "reading over USB needs pyusb: install keysteppro-tool[usb]"
        ) from error

    backend = usb.backend.libusb1.get_backend()
    for path in LIBUSB_PATHS:
        if backend is not None:
            break
        backend = usb.backend.libusb1.get_backend(find_library=partial(_at, path))
    if backend is None:
        raise TransportError(
            "no libusb backend found; install libusb (brew install libusb) "
            f"or place it at one of {', '.join(LIBUSB_PATHS)}"
        )
    return usb.core, usb.util, backend
