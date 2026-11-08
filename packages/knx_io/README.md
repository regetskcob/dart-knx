# knx_io

KNX bus connections for Dart, all behind one interface, `BusLink`:

- **KNXnet/IP tunnelling** over UDP or TCP (`KnxIpTunnel`), also **IP Secure**; requested tunnel
  address with fallback for tunnelling v1 gateways.
- **KNXnet/IP routing** (`RoutingLink`).
- **Serial FT1.2 with cEMI** (`Ft12CemiLink`), e.g. the Weinzierl KNX BAOS 838 **kBerry** on a
  Raspberry Pi: link layer (send and receive) or bus monitor (raw frames including
  acknowledgements). `KberryProbe` checks a module step by step, `BusmonCounters` counts what only
  the bus monitor shows.

Frames are cEMI as built and parsed by [`knx`](../knx). Uses `dart:io`, so it runs on the Dart VM
(servers, desktop, Raspberry Pi), not on the web. Used in production by
[Busclear](https://busclear.de).

## Example

```dart
import 'package:knx/knx.dart';
import 'package:knx_io/knx_io.dart';

Future<void> main() async {
  final link = KnxIpTunnel(host: '192.168.1.10');
  // or: Ft12CemiLink(open: (baud) => TtyLine.open('/dev/ttyAMA0', baud));
  link.frames.listen((cemi) => print(Telegram.fromCemi(cemi)));
  await link.connect();
  await link.send(buildGroupRequest(parseGroupAddress('1/2/3')!, TelegramType.write, small: 1));
}
```

`LinkException.problem` gives a stable reason (`noResponse`, `network`, `noFreeTunnel`,
`tunnelAddress`, `unsupported`, `secureAuth`, `secureDevice`, `routing`) for your own messages.

## kBerry notes

`TtyLine` configures the port with `stty` (Linux, macOS). What we measured on a kBerry, for
example that bus monitor mode loses about every second data frame while the link layer delivers
all of them, is in the [Python package's README](../../python/kberry/README.md#what-we-measured-on-the-kberry).
The same protocol is available for Python as [`kberry`](../../python/kberry); both test against
[`test-vectors/ft12.json`](../../test-vectors/ft12.json).

## Status

Pre-1.0. Not affiliated with or certified by the KNX Association or Weinzierl.

## Licence

BSD 3-Clause (`LICENSE`).
