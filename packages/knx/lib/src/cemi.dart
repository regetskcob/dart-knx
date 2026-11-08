import 'dart:typed_data';

/// Minimally parsed cEMI data frame (L_Data.ind / L_Data.con) – also for individual addressing
/// (device diagnostics), not only group telegrams.
class CemiFrame {
  const CemiFrame({
    required this.code,
    required this.ctrl1,
    required this.ctrl2,
    required this.source,
    required this.destination,
    required this.tpdu,
  });

  static const ind = 0x29;
  static const con = 0x2E;
  static const req = 0x11;

  final int code;
  final int ctrl1;
  final int ctrl2;
  final int source;
  final int destination;

  /// From the TPCI byte on: TPCI, APCI, data.
  final Uint8List tpdu;

  bool get isConfirmation => code == con;

  /// For L_Data.con: the bus did not acknowledge.
  bool get confirmError => isConfirmation && ctrl1 & 0x01 != 0;

  bool get groupAddressed => ctrl2 & 0x80 != 0;

  int get tpci => tpdu.isEmpty ? 0 : tpdu[0];

  /// Control TPDU (T_Connect, T_Disconnect, T_ACK …) without APCI.
  bool get isControl => tpci & 0x80 != 0;

  /// 10-bit APCI, `null` for control TPDUs.
  int? get apci => isControl || tpdu.length < 2 ? null : ((tpdu[0] & 0x03) << 8) | tpdu[1];

  /// Payload after the APCI.
  List<int> get payload => tpdu.length > 2 ? tpdu.sublist(2) : const [];

  static CemiFrame? parse(Uint8List c) {
    if (c.length < 2 || (c[0] != ind && c[0] != con)) return null;
    final i = 2 + c[1];
    if (c.length < i + 8) return null;
    final npdu = c[i + 6];
    final end = (i + 7 + npdu + 1).clamp(i + 8, c.length);
    return CemiFrame(
      code: c[0],
      ctrl1: c[i],
      ctrl2: c[i + 1],
      source: (c[i + 2] << 8) | c[i + 3],
      destination: (c[i + 4] << 8) | c[i + 5],
      tpdu: Uint8List.fromList(c.sublist(i + 7, end)),
    );
  }
}

/// Whether [cemi] is a complete L_Data.req up to and including the TPCI. Checks the lengths before
/// anything reads into the frame: the additional info length is in the frame itself.
bool isLDataRequest(List<int> cemi) {
  if (cemi.length < 2 || cemi[0] != CemiFrame.req) return false;
  return cemi.length >= 2 + cemi[1] + 8;
}

/// Builds an L_Data.req.
///
/// [group]: group instead of individual address. [tpdu]: TPCI/APCI/data. [system]: system priority
/// (device management), otherwise low.
Uint8List buildLData({required int destination, required bool group, required List<int> tpdu, bool system = false}) {
  return Uint8List.fromList([
    CemiFrame.req, 0x00,
    // Standard frame, no repetition, broadcast, priority system/low
    system ? 0xB0 : 0xBC,
    (group ? 0x80 : 0x00) | 0x60, // hop count 6
    0x00, 0x00, // the gateway sets the source
    destination >> 8, destination & 0xFF,
    tpdu.length - 1, // NPDU length without TPCI byte
    ...tpdu,
  ]);
}
