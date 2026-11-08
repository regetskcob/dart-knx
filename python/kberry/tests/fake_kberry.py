"""Simulated kBerry behind a serial line, a port of test/fake_kberry.dart in knx_io."""

from kberry.ft12 import ACK, Ack, Data, Decoder, Fixed

LINK_FRAMES = [bytes([0x29, 0x00, 0xBC, 0xE0, 0x11, 0x05, 0x09, 0x01, 0x01, 0x00, 0x81])]
BUSMON_FRAMES = [
    bytes([0x2B, 0x07, 0x03, 0x01, 0x00, 0x04, 0x02, 0x12, 0x34, 0xBC, 0x11, 0x05, 0x09, 0x01, 0xE1, 0x00, 0x81, 0x3F]),
    bytes([0x2B, 0x00, 0xCC]),
]


class FakeKberry:
    def __init__(self, baud=19200, line_baud=19200, modes=0x0003, reject_busmon=False):
        self.baud, self.line_baud, self.modes, self.reject_busmon = baud, line_baud, modes, reject_busmon
        self._decoder = Decoder()
        self._out = bytearray()
        self.comm_mode = 0xF0
        self.address = 0xFFFF
        self.host_acks = 0
        self.closed = False
        self.mute = False
        self.requests = []
        self.confirm_requests = True
        self.negative_confirm = False
        self._fcb = True
        self._last = b""

    def _send(self, data):
        control = 0xF3 if self._fcb else 0xD3
        self._fcb = not self._fcb
        n = len(data) + 1
        self._last = bytes([0x68, n, n, 0x68, control, *data, (control + sum(data)) & 0xFF, 0x16])
        self._out += self._last

    def push(self, data):
        self._send(bytes(data))

    def repeat_last(self):
        self._out += self._last

    def restart(self):
        self.comm_mode = 0xF0
        self._send(b"\xf0")

    def write(self, data):
        if self.line_baud != self.baud or self.mute:
            return
        for event in self._decoder.add(data):
            if isinstance(event, Ack):
                self.host_acks += 1
            elif isinstance(event, Fixed):
                self._out.append(ACK)
            elif isinstance(event, Data):
                self._out.append(ACK)
                self._answer(event.data)

    def _answer(self, d):
        code = d[0]
        if code == 0xA7:
            self._send(bytes([0xA8, *range(10)]))
        elif code == 0xFC:
            obj, pid = (d[1] << 8) | d[2], d[4]
            head = bytes([0xFB]) + d[1:7]
            values = {
                (0, 0x0B): bytes([0x00, 0xC5, 0, 0, 0, 0]),
                (8, 0x40): bytes([self.modes >> 8, self.modes & 0xFF]),
                (8, 0x34): bytes([self.comm_mode]),
                (0, 0x39): bytes([self.address >> 8]),
                (0, 0x3A): bytes([self.address & 0xFF]),
            }
            if (obj, pid) in values:
                self._send(head + values[(obj, pid)])
            else:
                self._send(head[:5] + bytes([0x00, 0x01, 0x07]))
        elif code == 0xF6 and d[1] == 0 and d[2] == 0:
            if d[4] == 0x39:
                self.address = (d[7] << 8) | (self.address & 0xFF)
            if d[4] == 0x3A:
                self.address = (self.address & 0xFF00) | d[7]
            self._send(bytes([0xF5]) + d[1:7])
        elif code == 0xF6:
            value = d[7]
            head = bytes([0xF5]) + d[1:7]
            if value == 0x01 and self.reject_busmon:
                self._send(head[:5] + bytes([0x00, 0x01, 0x06]))
                return
            self.comm_mode = value
            self._send(head)
            for f in LINK_FRAMES if value == 0x00 else BUSMON_FRAMES if value == 0x01 else []:
                self._send(f)
        elif code == 0x11 and self.comm_mode == 0x00:
            self.requests.append(bytes(d))
            if self.confirm_requests:
                con = bytearray(d)
                con[0] = 0x2E
                if self.negative_confirm:
                    con[2 + con[1]] |= 0x01
                self._send(bytes(con))

    def read(self):
        data, self._out = bytes(self._out), bytearray()
        return data

    def close(self):
        self.closed = True
