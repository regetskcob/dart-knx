"""Bus connection over an FT1.2 module with cEMI, without a KNX/IP gateway."""

from __future__ import annotations

import time
from typing import Callable, Iterable, List, Optional, Sequence

from .ft12 import Data
from .session import (
    CEMI_SERVER,
    DEVICE,
    MODE_BAOS,
    MODE_BUSMONITOR,
    MODE_LINK_LAYER,
    PID_COMM_MODE,
    PID_DEVICE_ADDRESS,
    PID_MEDIUM_MODES,
    PID_SUBNET,
    Line,
    Session,
)

L_DATA_REQ = 0x11
L_DATA_CON = 0x2E
L_DATA_IND = 0x29
L_BUSMON_IND = 0x2B
M_RESET_IND = 0xF0


class LinkError(Exception):
    """The connection failed or was lost."""


def format_individual(address: int) -> str:
    return f"{address >> 12}.{(address >> 8) & 0x0F}.{address & 0xFF}"


class CemiLink:
    """Link layer (send and receive ``L_Data``) or bus monitor (raw frames with
    acknowledgements, listen only) over a kBerry or another FT1.2 module with cEMI.

    ``connect`` switches the module via PID 52 and ``close`` switches it back to BAOS mode.
    Single-threaded: :meth:`receive` reads frames, :meth:`send` waits for the confirmation and
    keeps frames that arrive meanwhile for the next :meth:`receive`.

    ``open_line`` opens the line at a baud rate, e.g. ``lambda baud: SerialLine("/dev/ttyAMA0", baud)``.
    """

    def __init__(
        self,
        open_line: Callable[[int], Line],
        *,
        busmonitor: bool = False,
        requested_address: Optional[int] = None,
        bauds: Sequence[int] = (19200, 115200),
        confirm_timeout: float = 3.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._open = open_line
        self.busmonitor = busmonitor
        self.requested_address = requested_address
        self.bauds = tuple(bauds)
        self.confirm_timeout = confirm_timeout
        self._clock = clock
        self._session: Optional[Session] = None
        self._pending: List[bytes] = []
        self.baud: Optional[int] = None
        self.address: Optional[int] = None

    @property
    def label(self) -> str:
        mode = "bus monitor" if self.busmonitor else "link layer"
        return f"FT1.2 {mode}" + ("" if self.address is None else f" {format_individual(self.address)}")

    @property
    def connected(self) -> bool:
        return self._session is not None

    def connect(self) -> None:
        session = None
        for baud in self.bauds:
            try:
                line = self._open(baud)
            except Exception as e:
                raise LinkError(f"FT1.2: cannot open the line ({e})") from e
            candidate = Session(line, self._clock)
            if candidate.reset():
                session, self.baud = candidate, baud
                break
            line.close()
        if session is None:
            raise LinkError("FT1.2 module does not respond (bus voltage, wiring, UART?)")
        self._session = session
        try:
            # PEI identify: with cEMI, Weinzierl modules respond with 11 bytes.
            if session.ask(bytes([0xA7]), 0xA8) is None:
                raise LinkError("FT1.2 module: no answer to identify")
            modes = session.read_property(CEMI_SERVER, PID_MEDIUM_MODES)
            if modes:
                mask = int.from_bytes(modes, "big")
                if not mask & (0x02 if self.busmonitor else 0x01):
                    mode = "bus monitor" if self.busmonitor else "link layer"
                    raise LinkError(f"FT1.2 module has no {mode} mode")
            if self.requested_address is not None and not self.busmonitor:
                self._write_address(session, self.requested_address)
            self.address = self._read_address(session)
            if not session.write_comm_mode(MODE_BUSMONITOR if self.busmonitor else MODE_LINK_LAYER):
                raise LinkError("FT1.2 module rejects the mode switch (PID 52)")
        except BaseException:
            self._restore(session)
            self._session = None
            raise

    @staticmethod
    def _read_address(s: Session) -> Optional[int]:
        subnet = s.read_property(DEVICE, PID_SUBNET)
        device = s.read_property(DEVICE, PID_DEVICE_ADDRESS)
        if not subnet or not device:
            return None
        return (subnet[0] << 8) | device[0]

    def _write_address(self, s: Session, address: int) -> None:
        if self._read_address(s) == address:
            return
        if not (
            s.write_property(DEVICE, PID_SUBNET, bytes([address >> 8]))
            and s.write_property(DEVICE, PID_DEVICE_ADDRESS, bytes([address & 0xFF]))
        ):
            raise LinkError(f"FT1.2 module does not take the address {format_individual(address)}")

    @staticmethod
    def _restore(s: Session) -> None:
        try:
            s.write_comm_mode(MODE_BAOS)
        except Exception:
            pass
        try:
            s.line.close()
        except Exception:
            pass

    def _session_or_raise(self) -> Session:
        if self._session is None:
            raise LinkError("Not connected")
        return self._session

    def _frames(self, events: Iterable[object]) -> List[bytes]:
        frames = []
        for event in events:
            if not isinstance(event, Data) or not event.data:
                continue
            code = event.data[0]
            if code in (L_DATA_IND, L_BUSMON_IND, L_DATA_CON):
                frames.append(event.data)
            elif code == M_RESET_IND:
                # Restarted (ETS download, bus voltage) and back in BAOS mode.
                self.close()
                raise LinkError("FT1.2 module restarted")
        return frames

    def receive(self) -> List[bytes]:
        """cEMI frames received since the last call (reads at most about 100 ms)."""
        s = self._session_or_raise()
        frames, self._pending = self._pending, []
        try:
            events = s.poll()
        except OSError as e:
            self.close()
            raise LinkError(f"FT1.2: read error ({e})") from e
        return frames + self._frames(events)

    def check_alive(self) -> None:
        """Raises :class:`LinkError` if the module stopped responding or left the mode.
        Call it now and then without traffic, e.g. every 30 seconds."""
        s = self._session_or_raise()
        mode = s.read_property(CEMI_SERVER, PID_COMM_MODE)
        if not mode:
            self.close()
            raise LinkError("FT1.2 module stopped responding")
        if mode[0] != (MODE_BUSMONITOR if self.busmonitor else MODE_LINK_LAYER):
            self.close()
            raise LinkError("FT1.2 module left the operating mode")

    def send(self, cemi: bytes) -> None:
        """Sends an ``L_Data.req`` and waits for its ``L_Data.con``.

        The source is set to the own address. Raises :class:`LinkError` if the module does not
        take the frame, nobody acknowledged it on the bus (NCON) or no confirmation came.
        """
        s = self._session_or_raise()
        if self.busmonitor:
            raise LinkError("FT1.2 bus monitor mode cannot send")
        if len(cemi) < 10 or cemi[0] != L_DATA_REQ:
            raise LinkError("Invalid frame")
        frame = bytearray(cemi)
        i = 2 + frame[1]
        if self.address is not None:
            frame[i + 2], frame[i + 3] = self.address >> 8, self.address & 0xFF
        target = (frame[i + 4], frame[i + 5])
        if not s.send(bytes(frame)):
            self.close()
            raise LinkError("FT1.2 module does not acknowledge")
        end = self._clock() + self.confirm_timeout
        while self._clock() < end:
            for f in self._frames(s.poll()):
                self._pending.append(f)
                j = 2 + f[1] if len(f) > 1 else 0
                if f[0] == L_DATA_CON and len(f) >= j + 6 and (f[j + 4], f[j + 5]) == target:
                    if f[j] & 0x01:
                        raise LinkError("Telegram not acknowledged on the bus (NCON)")
                    return
        raise LinkError("FT1.2 module does not confirm the telegram")

    def close(self) -> None:
        """Back to BAOS mode and close the line."""
        s, self._session = self._session, None
        if s is not None:
            self._restore(s)

    def __enter__(self) -> "CemiLink":
        self.connect()
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()
