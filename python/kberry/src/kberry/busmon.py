"""Bus monitor frames (cEMI ``L_Busmon.ind``, 0x2B): conversion and counters."""

from __future__ import annotations

from typing import Dict, Optional

L_BUSMON_IND = 0x2B
L_DATA_IND = 0x29


def _status(cemi: bytes, start: int) -> Optional[int]:
    """Bus monitor status (additional info type 0x03), or None."""
    status = None
    i = 2
    while i + 1 < start:
        if cemi[i] == 0x03 and cemi[i + 1] >= 1 and i + 2 < start:
            status = cemi[i + 2]
        i += 2 + cemi[i + 1]
    return status


def busmon_to_ldata(cemi: bytes) -> Optional[bytes]:
    """Turns a bus monitor frame with a standard data telegram into an ``L_Data.ind``.

    Returns None for acknowledgements, extended frames, truncated frames and frames with a
    transmission error (frame, bit or parity error, overflow, lost).
    """
    if len(cemi) < 3 or cemi[0] != L_BUSMON_IND:
        return None
    info = cemi[1]
    if len(cemi) < 2 + info + 8:
        return None
    if (_status(cemi, 2 + info) or 0) & 0xF8:
        return None
    raw = cemi[2 + info :]
    # Standard frame: control field 10xx xx00.
    if raw[0] & 0xD3 != 0x90:
        return None
    length = raw[5] & 0x0F
    end = 6 + length + 1
    if len(raw) < end + 1:
        return None
    xor = 0
    for b in raw[:end]:
        xor ^= b
    if (~xor & 0xFF) != raw[end]:
        return None
    return bytes([L_DATA_IND, 0x00, raw[0], raw[5] & 0xF0, *raw[1:5], length, *raw[6:end]])


class BusmonCounters:
    """Counts what only the bus monitor shows: acknowledgements, rejected and damaged frames.

    ``orphan_acks`` (acknowledgements without a data frame directly before them) and
    ``seq_gaps`` (frames skipped by the sequence number in the status, bits 0-2) measure frames
    the module saw but did not pass on. On a kBerry about every second data frame is missing
    in bus monitor mode, while the link layer delivers all of them.
    """

    def __init__(self) -> None:
        self.data = 0
        self.acks = 0
        self.naks = 0
        self.busy = 0
        self.damaged = 0
        self.orphan_acks = 0
        self.seq_gaps = 0
        self._data_pending = False
        self._last_seq: Optional[int] = None

    def resync(self) -> None:
        """After a new connection the module counts from the start again."""
        self._last_seq = None
        self._data_pending = False

    @property
    def total(self) -> int:
        return self.data + self.acks + self.naks + self.busy + self.damaged

    def add(self, cemi: bytes) -> None:
        """Records an ``L_Busmon.ind``."""
        if len(cemi) < 3 or cemi[0] != L_BUSMON_IND:
            return
        start = 2 + cemi[1]
        if len(cemi) <= start:
            self.damaged += 1
            return
        status = _status(cemi, start)
        if status is not None:
            seq = status & 0x07
            last = self._last_seq
            # The same number again: this interface does not number its frames.
            if last is not None and seq != last:
                self.seq_gaps += (seq - last - 1) & 0x07
            self._last_seq = seq
        if (status or 0) & 0xF8:
            self.damaged += 1
            self._data_pending = False
            return
        if len(cemi) == start + 1:
            code = cemi[start]
            if code == 0xCC:
                self.acks += 1
                if not self._data_pending:
                    self.orphan_acks += 1
            elif code == 0x0C:
                self.naks += 1
            elif code == 0xC0:
                self.busy += 1
            elif code == 0x00:
                self.naks += 1
                self.busy += 1
            else:
                self.damaged += 1
            self._data_pending = False
            return
        raw = cemi[start:]
        xor = 0
        for b in raw[:-1]:
            xor ^= b
        if len(raw) >= 2 and (~xor & 0xFF) == raw[-1]:
            self.data += 1
            self._data_pending = True
        else:
            self.damaged += 1
            self._data_pending = False

    def to_dict(self) -> Dict[str, int]:
        """Same keys as ``BusmonCounters.toJson`` in the Dart package ``knx_io``."""
        return {
            "data": self.data,
            "acks": self.acks,
            "naks": self.naks,
            "busy": self.busy,
            "damaged": self.damaged,
            "orphanAcks": self.orphan_acks,
            "seqGaps": self.seq_gaps,
        }
