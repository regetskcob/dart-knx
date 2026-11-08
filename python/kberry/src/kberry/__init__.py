"""FT1.2 and cEMI for the Weinzierl KNX BAOS 838 kBerry and similar serial KNX modules.

Pure Python; :class:`SerialLine` needs pyserial (``pip install 'kberry[serial]'``).
The same protocol as the Dart package ``knx_io``, tested against the same vectors.
"""

from .busmon import BusmonCounters, busmon_to_ldata
from .ft12 import ACK, RESET, Ack, Data, Decoder, Event, Fixed, frame
from .link import CemiLink, LinkError
from .session import (
    MODE_BAOS,
    MODE_BUSMONITOR,
    MODE_LINK_LAYER,
    Line,
    SerialLine,
    Session,
)

__all__ = [
    "ACK",
    "RESET",
    "Ack",
    "BusmonCounters",
    "CemiLink",
    "Data",
    "Decoder",
    "Event",
    "Fixed",
    "Line",
    "LinkError",
    "MODE_BAOS",
    "MODE_BUSMONITOR",
    "MODE_LINK_LAYER",
    "SerialLine",
    "Session",
    "busmon_to_ldata",
    "frame",
]

__version__ = "0.1.0"
