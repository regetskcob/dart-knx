import pytest

from kberry import CemiLink, LinkError
from fake_kberry import BUSMON_FRAMES, LINK_FRAMES, FakeKberry

REQUEST_OFF = bytes([0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, 0x0A, 0x03, 0x01, 0x00, 0x80])


class Opener:
    def __init__(self, **kw):
        self.kw, self.module, self.tried = kw, None, []

    def __call__(self, baud):
        self.tried.append(baud)
        self.module = FakeKberry(line_baud=baud, **self.kw)
        return self.module


def _receive_until(link, n):
    frames = []
    for _ in range(50):
        frames += link.receive()
        if len(frames) >= n:
            break
    return frames


def test_link_layer_receives_sends_and_restores():
    opener = Opener()
    link = CemiLink(opener)
    link.connect()
    m = opener.module
    assert m.comm_mode == 0x00
    assert link.baud == 19200
    assert link.label == "FT1.2 link layer 15.15.255"
    assert _receive_until(link, 1)[0] == LINK_FRAMES[0]
    link.send(REQUEST_OFF)
    assert m.requests[-1][4:6] == bytes([0xFF, 0xFF]), "source = own address"
    assert link.receive()[0][0] == 0x2E, "the confirmation is delivered too"
    link.close()
    assert m.comm_mode == 0xF0 and m.closed


def test_negative_confirmation():
    opener = Opener()
    with CemiLink(opener) as link:
        opener.module.negative_confirm = True
        with pytest.raises(LinkError, match="NCON"):
            link.send(REQUEST_OFF)


def test_no_confirmation():
    opener = Opener()
    with CemiLink(opener, confirm_timeout=0.05) as link:
        opener.module.confirm_requests = False
        with pytest.raises(LinkError, match="does not confirm"):
            link.send(REQUEST_OFF)


def test_requested_address():
    opener = Opener()
    with CemiLink(opener, requested_address=0x11FA) as link:
        assert opener.module.address == 0x11FA
        assert link.address == 0x11FA


def test_busmonitor_raw_frames_no_sending():
    opener = Opener()
    with CemiLink(opener, busmonitor=True) as link:
        assert opener.module.comm_mode == 0x01
        assert _receive_until(link, len(BUSMON_FRAMES)) == BUSMON_FRAMES
        with pytest.raises(LinkError):
            link.send(REQUEST_OFF)
    assert opener.module.comm_mode == 0xF0


def test_module_without_busmonitor():
    opener = Opener(modes=0x0001)
    with pytest.raises(LinkError, match="no bus monitor"):
        CemiLink(opener, busmonitor=True).connect()
    assert opener.module.comm_mode == 0xF0 and opener.module.closed


def test_silent_module_tries_both_baud_rates():
    opener = Opener(baud=9600)
    with pytest.raises(LinkError, match="does not respond"):
        CemiLink(opener).connect()
    assert opener.tried == [19200, 115200]


def test_finds_115200():
    opener = Opener(baud=115200)
    with CemiLink(opener) as link:
        assert link.baud == 115200


def test_restart_loses_the_connection():
    opener = Opener()
    link = CemiLink(opener)
    link.connect()
    _receive_until(link, 1)
    opener.module.restart()
    with pytest.raises(LinkError, match="restarted"):
        for _ in range(10):
            link.receive()
    assert not link.connected and opener.module.closed


def test_repeated_frame_arrives_once():
    opener = Opener()
    with CemiLink(opener) as link:
        _receive_until(link, 1)
        opener.module.push([0x29, 0x00, 0xBC, 0xE0, 0x11, 0x06, 0x09, 0x02, 0x01, 0x00, 0x80])
        opener.module.repeat_last()
        assert len(link.receive()) == 1


def test_check_alive():
    opener = Opener()
    with CemiLink(opener) as link:
        link.check_alive()
        opener.module.mute = True
        with pytest.raises(LinkError, match="stopped responding"):
            link.check_alive()
