/// Connections to a KNX bus for the Dart VM (uses `dart:io`), all behind one interface,
/// [BusLink]: KNXnet/IP tunnelling over UDP or TCP (also IP Secure), KNXnet/IP routing, and
/// serial FT1.2 with cEMI, e.g. the Weinzierl KNX BAOS 838 kBerry on a Raspberry Pi.
///
/// Frames are cEMI as built and parsed by `package:knx`.
library;

export 'src/ft12.dart';
export 'src/ft12_link.dart';
export 'src/kberry.dart';
export 'src/link.dart';
