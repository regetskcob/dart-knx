"""Tests against test-vectors/ft12.json, shared with the Dart package knx_io."""

import json
from pathlib import Path

import pytest

from kberry import ACK, RESET, Ack, BusmonCounters, Data, Decoder, Fixed, busmon_to_ldata, frame

V = json.loads((Path(__file__).resolve().parents[3] / "test-vectors" / "ft12.json").read_text())


def test_constants():
    assert V["ack"] == ACK
    assert V["reset"] == RESET.hex()


@pytest.mark.parametrize("case", V["encode"], ids=lambda c: c["name"])
def test_encode(case):
    assert frame(bytes.fromhex(case["data"]), fcb=case["fcb"]).hex() == case["frame"]


def _json(event):
    if isinstance(event, Ack):
        return {"type": "ack"}
    if isinstance(event, Fixed):
        return {"type": "fixed", "control": event.control}
    assert isinstance(event, Data)
    return {"type": "data", "control": event.control, "data": event.data.hex()}


@pytest.mark.parametrize("case", V["decode"], ids=lambda c: c["name"])
def test_decode(case):
    decoder = Decoder()
    events = [e for chunk in case["chunks"] for e in decoder.add(bytes.fromhex(chunk))]
    assert [_json(e) for e in events] == case["events"]
    assert decoder.skipped == case["skipped"]


@pytest.mark.parametrize("case", V["busmonToLData"], ids=lambda c: c["name"])
def test_busmon_to_ldata(case):
    result = busmon_to_ldata(bytes.fromhex(case["cemi"]))
    assert (None if result is None else result.hex()) == case["ldata"]


def test_busmon_counters():
    counters = BusmonCounters()
    for f in V["busmonCounters"]["frames"]:
        counters.add(bytes.fromhex(f))
    assert counters.to_dict() == V["busmonCounters"]["counters"]
