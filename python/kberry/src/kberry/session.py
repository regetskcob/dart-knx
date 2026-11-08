"""FT1.2 session with the module: reset, frames with acknowledgement and frame count bit,
and the cEMI property services (``M_PropRead``, ``M_PropWrite``)."""

from __future__ import annotations

import time
from typing import Callable, List, Optional, Protocol

from .ft12 import ACK, RESET, Ack, Data, Decoder, Event, frame

#: cEMI server object and its communication mode property (PID 52).
CEMI_SERVER = 0x0008
PID_COMM_MODE = 0x34
PID_MEDIUM_MODES = 0x40
#: Device object, serial number (PID 11), subnet (PID 57) and device address (PID 58).
DEVICE = 0x0000
PID_SERIAL = 0x0B
PID_SUBNET = 0x39
PID_DEVICE_ADDRESS = 0x3A

#: Values of PID 52.
MODE_LINK_LAYER = 0x00
MODE_BUSMONITOR = 0x01
MODE_BAOS = 0xF0


class Line(Protocol):
    """Serial line to the module. ``read`` waits only briefly (about 100 ms) and may return b''."""

    def write(self, data: bytes) -> None: ...

    def read(self) -> bytes: ...

    def close(self) -> None: ...


class SerialLine:
    """A serial port via pyserial: 8E1, raw, reads with a 100 ms timeout."""

    def __init__(self, device: str, baud: int = 19200) -> None:
        try:
            import serial  # type: ignore[import-not-found]
        except ImportError as e:  # pragma: no cover - depends on the environment
            raise ImportError("SerialLine needs pyserial: pip install 'kberry[serial]'") from e
        self._port = serial.Serial(
            device,
            baudrate=baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_EVEN,
            stopbits=serial.STOPBITS_ONE,
            timeout=0.1,
        )

    def write(self, data: bytes) -> None:
        self._port.write(data)

    def read(self) -> bytes:
        return self._port.read(256)

    def close(self) -> None:
        self._port.close()


class Session:
    """One FT1.2 session over a :class:`Line`. Reads only while someone waits."""

    def __init__(self, line: Line, clock: Callable[[], float] = time.monotonic) -> None:
        self.line = line
        self.decoder = Decoder()
        self._events: List[Event] = []
        self._fcb = True
        self._last: Optional[Data] = None
        self._clock = clock

    def _fill(self) -> None:
        chunk = self.line.read()
        if not chunk:
            return
        for event in self.decoder.add(chunk):
            if isinstance(event, Data):
                # Every data frame from the module requires an acknowledgement.
                self.line.write(bytes([ACK]))
                # Our acknowledgement got lost: the module repeats the frame unchanged.
                if self._last is not None and event == self._last:
                    continue
                self._last = event
            self._events.append(event)

    def poll(self) -> List[Event]:
        """Reads once (at most about 100 ms) and returns all events nobody picked up yet."""
        self._fill()
        events, self._events = self._events, []
        return events

    def _wait_for(self, test: Callable[[Event], bool], timeout: float) -> Optional[Event]:
        end = self._clock() + timeout
        while True:
            for i, event in enumerate(self._events):
                if test(event):
                    return self._events.pop(i)
            if self._clock() >= end:
                return None
            self._fill()

    def reset(self) -> bool:
        """Sends the FT1.2 reset; True if the module acknowledged."""
        self._events.clear()
        self.line.write(RESET)
        ok = self._wait_for(lambda e: isinstance(e, Ack), 0.6) is not None
        self._fcb = True
        self._last = None
        return ok

    def send(self, data: bytes) -> bool:
        """Sends a data frame, waits for the acknowledgement, retries once."""
        for _ in range(2):
            self.line.write(frame(data, fcb=self._fcb))
            if self._wait_for(lambda e: isinstance(e, Ack), 0.5) is not None:
                self._fcb = not self._fcb
                return True
        return False

    def ask(self, request: bytes, code: int, timeout: float = 1.5) -> Optional[bytes]:
        """Sends ``request`` and waits for the answer with message code ``code``."""
        if not self.send(request):
            return None
        event = self._wait_for(lambda e: isinstance(e, Data) and e.data[:1] == bytes([code]), timeout)
        return event.data if isinstance(event, Data) else None

    def read_property(self, object_type: int, pid: int) -> Optional[bytes]:
        """``M_PropRead.req`` for instance 1, one element from index 1; None on error."""
        con = self.ask(bytes([0xFC, object_type >> 8, object_type & 0xFF, 0x01, pid, 0x10, 0x01]), 0xFB)
        # A count of 0 in the confirmation means error; an error code follows.
        if con is None or len(con) < 7 or con[5] >> 4 == 0:
            return None
        return con[7:]

    def write_property(self, object_type: int, pid: int, value: bytes) -> bool:
        """``M_PropWrite.req`` like :meth:`read_property`; True if the module took the value."""
        request = bytes([0xF6, object_type >> 8, object_type & 0xFF, 0x01, pid, 0x10, 0x01]) + bytes(value)
        con = self.ask(request, 0xF5)
        return con is not None and len(con) >= 7 and con[5] >> 4 != 0

    def write_comm_mode(self, mode: int) -> bool:
        """PID 52: :data:`MODE_LINK_LAYER`, :data:`MODE_BUSMONITOR` or back to :data:`MODE_BAOS`."""
        return self.write_property(CEMI_SERVER, PID_COMM_MODE, bytes([mode]))
