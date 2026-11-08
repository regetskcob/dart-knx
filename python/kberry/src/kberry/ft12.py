"""FT1.2 frames (IEC 60870-5-1/-2) between a host and a Weinzierl BAOS module such as the kBerry.

- Reset: ``10 40 40 16``; the module acknowledges with :data:`ACK`.
- Data: ``68 L L 68 C <data> CS 16``; L = length of C + data, CS = sum of C + data.
  C from the host is ``0x73``/``0x53`` (the frame count bit toggles with each new frame and is
  set first after a reset), from the module ``0xF3``/``0xD3``.
- Every data frame is acknowledged with the single character :data:`ACK`.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Union

ACK = 0xE5
RESET = bytes([0x10, 0x40, 0x40, 0x16])


def frame(data: bytes, *, fcb: bool) -> bytes:
    """Data frame from the host carrying ``data`` with the frame count bit ``fcb``."""
    control = 0x73 if fcb else 0x53
    checksum = (control + sum(data)) & 0xFF
    length = len(data) + 1
    return bytes([0x68, length, length, 0x68, control, *data, checksum, 0x16])


@dataclass(frozen=True)
class Ack:
    """Single-character acknowledgement."""


@dataclass(frozen=True)
class Fixed:
    """Fixed-length frame (e.g. reset); ``control`` is the control byte."""

    control: int


@dataclass(frozen=True)
class Data:
    """Data frame; ``data`` is the content without the control byte (cEMI or BAOS)."""

    control: int
    data: bytes


Event = Union[Ack, Fixed, Data]


class Decoder:
    """Splits the byte stream from the module into events.

    Unknown bytes and frames with a wrong checksum are skipped and counted in :attr:`skipped`.
    Incomplete frames stay buffered until the rest arrives.
    """

    def __init__(self) -> None:
        self._buffer = bytearray()
        self.skipped = 0

    def add(self, chunk: bytes) -> List[Event]:
        self._buffer += chunk
        buf = self._buffer
        events: List[Event] = []
        while buf:
            first = buf[0]
            if first == ACK:
                del buf[0]
                events.append(Ack())
            elif first == 0x10:
                if len(buf) < 4:
                    break
                if buf[1] == buf[2] and buf[3] == 0x16:
                    events.append(Fixed(buf[1]))
                    del buf[:4]
                else:
                    self._skip()
            elif first == 0x68:
                if len(buf) < 4:
                    break
                length = buf[1]
                if length == 0 or buf[2] != length or buf[3] != 0x68:
                    self._skip()
                    continue
                total = length + 6
                if len(buf) < total:
                    break
                if sum(buf[4 : 4 + length]) & 0xFF == buf[4 + length] and buf[total - 1] == 0x16:
                    events.append(Data(buf[4], bytes(buf[5 : 4 + length])))
                    del buf[:total]
                else:
                    self._skip()
            else:
                self._skip()
        return events

    def _skip(self) -> None:
        del self._buffer[0]
        self.skipped += 1
