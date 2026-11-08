# knx

KNX protocol building blocks in pure Dart. No Flutter, no `dart:io`: the same code runs on the
Dart VM, in Flutter apps and on the web.

Used in production by [Busclear](https://busclear.de), a KNX bus monitor for Home Assistant,
Raspberry Pi and the apps. For bus connections (KNXnet/IP tunnel, routing, serial FT1.2 with
the Weinzierl kBerry) see [`knx_io`](../knx_io).

## Contents

`package:knx/knx.dart`

- Group and individual addresses: parse and format, 3-level, 2-level and free style.
- cEMI: L_Data frames (`CemiFrame`, `buildLData`, `isLDataRequest`), group telegrams (`Telegram`,
  `TelegramType`, `TelegramPriority`, `buildGroupRequest`) and a compact JSON line format for
  recordings (`Telegram.toJson`, `Telegram.fromJson`).
- KNXnet/IP: service identifiers (`KnxIpService`), status codes (`KnxIpStatus`), frame header,
  HPAI and tunnel CRI.
- Datapoint types: `Dpt`, DPT 9 float, numeric values (`dptNumericValue`), units (`dptUnit`),
  encoding typed input (`encodeForDpt`).
- Guessing the datapoint type of a group address from overheard telegrams and its name
  (`guessDpt`, `dptCandidates`), for installations without an ETS project.
- Silence rule for cyclic senders (`cycleSilences`) and merging the same telegram seen at several
  tap points (`tap_merge`).
- Hex helpers.

`package:knx/secure.dart`, KNX Secure after AN158/AN159 (uses `pointycastle`)

- AES-128-CCM in KNX block formatting, key derivation, X25519.
- IP Secure session: handshake and secure wrapper (`IpSecureSession`).
- Data Secure for group telegrams (`DataSecure`).

## Example

```dart
import 'package:knx/knx.dart';

void main() {
  final ga = parseGroupAddress('1/2/3', GroupStyle.threeLevel)!;
  // L_Data.req: switch on (DPT 1.001) to 1/2/3.
  final cemi = buildGroupRequest(ga, TelegramType.write, small: 1);
  print(hexOf(cemi));
}
```

## Status

Pre-1.0: names may still change between minor versions; the changelog says what to do.
Not affiliated with or certified by the KNX Association.

## Licence

BSD 3-Clause (`LICENSE`). The KNX Secure code follows the structure of
[xknx](https://github.com/XKNX/xknx) (MIT) and is checked against its test vectors; see `NOTICE`.
