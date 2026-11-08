# kberry

FT1.2 and cEMI for the **Weinzierl KNX BAOS 838 kBerry** and similar serial KNX modules, in
pure Python. Connects a Raspberry Pi (or any computer with a UART) to the KNX bus without a
KNX/IP gateway: send and receive group telegrams in link layer mode, or record everything
including acknowledgements in bus monitor mode.

The same protocol as the Dart package [`knx_io`](../../packages/knx_io) used in
[Busclear](https://busclear.de); both test against the shared vectors in
[`test-vectors/ft12.json`](../../test-vectors/ft12.json).

## Install

```sh
pip install 'kberry[serial]'
```

Without the `serial` extra the package has no dependencies; bring your own line (anything with
`write(bytes)`, `read() -> bytes` and `close()`).

## Example

```python
from kberry import CemiLink, SerialLine

with CemiLink(lambda baud: SerialLine("/dev/ttyAMA0", baud)) as link:
    print("connected:", link.label)       # e.g. "FT1.2 link layer 15.15.255"
    # L_Data.req: GroupValueWrite 1/2/3 = on (cEMI, source is set by the link)
    link.send(bytes.fromhex("1100bce000000a03010081"))
    while True:
        for cemi in link.receive():       # L_Data.ind / L_Data.con as raw cEMI
            print(cemi.hex())
```

Bus monitor mode: `CemiLink(..., busmonitor=True)` delivers `L_Busmon.ind` frames;
`busmon_to_ldata` turns data telegrams into `L_Data.ind`, `BusmonCounters` counts
acknowledgements, rejections and damaged frames.

For decoding cEMI into addresses and values, use a KNX library such as
[xknx](https://github.com/XKNX/xknx).

## Raspberry Pi setup

- `/boot/firmware/config.txt`: `enable_uart=1` and `dtoverlay=disable-bt` (Pi 3/4) so that
  `/dev/ttyAMA0` is the PL011 UART on GPIO 14/15.
- Turn off the serial console (`raspi-config` → Interface → Serial: no login shell, port on).
- The kBerry speaks 19200 baud 8E1 by default; `CemiLink` also tries 115200.

## What we measured on the kBerry

- **Bus monitor mode loses frames.** On a kBerry with a Pi 4, about every second data frame
  is missing in bus monitor mode, at 19200 and at 115200 baud: the sequence number in the
  status jumps, and acknowledgements arrive without the data frame before them
  (`BusmonCounters.seq_gaps`, `orphan_acks`). The link layer delivers all of them. To record
  telegrams reliably, use link layer mode; use bus monitor mode only to see acknowledgements.
- **Lost acknowledgements.** If the module misses the host's acknowledgement, it repeats the
  frame with the same control byte; the session drops the repetition.
- **Restarts.** After an ETS download or a bus voltage drop the module sends `M_Reset.ind` and
  is back in BAOS mode; `CemiLink` reports the connection as lost, connect again.

## Status

Beta. The protocol runs on a kBerry in Busclear (Dart); this Python version is so far tested
against a simulated module and the shared vectors. Reports from real hardware are welcome.
Not affiliated with Weinzierl or the KNX Association.

## Licence

BSD 3-Clause.
