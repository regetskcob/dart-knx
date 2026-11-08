import 'dart:typed_data';

/// Datapoint type, e.g. 9.001. [sub] is `null` if only the main type is known.
class Dpt {
  const Dpt(this.main, [this.sub]);

  final int main;
  final int? sub;

  /// Parses "DPST-9-1", "DPT-1", "9.001" or "9.1".
  static Dpt? tryParse(String s) {
    final m = RegExp(r'(\d+)(?:[-.](\d+))?').firstMatch(s.split(',').first);
    if (m == null) return null;
    return Dpt(int.parse(m[1]!), m[2] == null ? null : int.parse(m[2]!));
  }

  @override
  bool operator ==(Object other) => other is Dpt && other.main == main && other.sub == sub;

  @override
  int get hashCode => Object.hash(main, sub);

  @override
  String toString() => sub == null ? '$main.xxx' : '$main.${sub.toString().padLeft(3, '0')}';
}

/// Decodes a 2-byte float (DPT 9.xxx).
double decodeDpt9(List<int> b) {
  var mantissa = ((b[0] & 0x07) << 8) | b[1];
  if (b[0] & 0x80 != 0) mantissa -= 2048;
  final exponent = (b[0] >> 3) & 0x0F;
  return 0.01 * mantissa * (1 << exponent);
}

/// Encodes a 2-byte float (DPT 9.xxx). `null` outside the range.
List<int>? encodeDpt9(double value) {
  final scaled = value * 100;
  for (var e = 0; e <= 15; e++) {
    final m = (scaled / (1 << e)).round();
    if (m >= -2048 && m <= 2047) {
      final raw = m & 0xFFF;
      return [((raw >> 11) & 1) << 7 | e << 3 | (raw >> 8) & 0x07, raw & 0xFF];
    }
  }
  return null;
}

/// Numeric value of a group telegram's payload for charts and thresholds, according to [dpt] or, without
/// a type, heuristically: short values as a number, 1 byte as 0…255, 2 bytes as DPT 9. [small]: the
/// value sits in the 6 bits of the APCI (1 bit, dimming …). `null` if no meaningful number can be derived
/// (e.g. text, time, empty payload).
double? dptNumericValue(Dpt? dpt, List<int> data, {required bool small}) {
  if (data.isEmpty) return null;
  if (small) return dpt == null || dpt.main <= 2 ? data[0].toDouble() : null;
  final bd = ByteData.sublistView(Uint8List.fromList(data));
  return switch ((dpt?.main, data.length)) {
    (5, 1) when dpt!.sub == 1 => data[0] * 100 / 255,
    (5 || 6 || null, 1) => dpt?.main == 6 ? bd.getInt8(0).toDouble() : data[0].toDouble(),
    (7, 2) => bd.getUint16(0).toDouble(),
    (8, 2) => bd.getInt16(0).toDouble(),
    (9 || null, 2) => decodeDpt9(data),
    (12, 4) => bd.getUint32(0).toDouble(),
    (13, 4) => bd.getInt32(0).toDouble(),
    (14, 4) => bd.getFloat32(0),
    _ => null,
  };
}

/// Unit of a DPT, e.g. "°C" for 9.001. Empty if there is none or it is not known.
String dptUnit(Dpt d) =>
    (switch (d.main) {
      5 => const {1: '%', 3: '°'}[d.sub],
      6 => d.sub == 1 ? '%' : null,
      7 => _unit7[d.sub],
      9 => _unit9[d.sub],
      13 => _unit13[d.sub],
      14 => _unit14[d.sub],
      _ => null,
    }) ??
    '';

const _unit7 = {5: 's', 6: 'min', 7: 'h', 12: 'mA', 13: 'lx', 600: 'K'};

const _unit9 = {
  1: '°C',
  2: 'K',
  3: 'K/h',
  4: 'lx',
  5: 'm/s',
  6: 'Pa',
  7: '%',
  8: 'ppm',
  9: 'm³/h',
  10: 's',
  11: 'ms',
  20: 'mV',
  21: 'mA',
  22: 'W/m²',
  24: 'kW',
  25: 'l/h',
  26: 'l/m²',
  27: '°F',
  28: 'km/h',
  29: 'g/m³',
  30: 'µg/m³',
};

const _unit13 = {10: 'Wh', 11: 'VAh', 12: 'VARh', 13: 'kWh'};

const _unit14 = {7: '°', 19: 'A', 27: 'V', 31: 'J', 33: 'Hz', 56: 'W', 68: '°C', 76: 'm³'};

/// Whether [encodeForDpt] can write this DPT.
bool canEncodeDpt(Dpt dpt) => const {1, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 20, 232}.contains(dpt.main);

/// Encodes a value typed by a user for [dpt]: a number (decimal point or comma, units and other characters
/// are ignored), "hh:mm[:ss]" for DPT 10, "DD.MM.YYYY" or "YYYY-MM-DD" for DPT 11, text for DPT 16,
/// "#RRGGBB" or "r, g, b" for DPT 232. Result: either `small` (≤ 6 bit, in the APCI) or `data`. `null` for
/// invalid input or a DPT it cannot write ([canEncodeDpt]).
({int? small, List<int> data})? encodeForDpt(Dpt dpt, String input) {
  switch (dpt.main) {
    case 16:
      // Text, 14 characters ISO 8859-1; empty is allowed (e.g. clears a display).
      if (input.length > 14 || input.codeUnits.any((c) => c > 0xFF)) return null;
      return (small: null, data: [...input.codeUnits, ...List.filled(14 - input.length, 0)]);
    case 10:
      final m = RegExp(r'^\s*(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?\s*$').firstMatch(input);
      if (m == null) return null;
      final (h, min, sec) = (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3] ?? '0'));
      return h < 24 && min < 60 && sec < 60 ? (small: null, data: [h, min, sec]) : null;
    case 11:
      final de = RegExp(r'^\s*(\d{1,2})\.(\d{1,2})\.(\d{4})\s*$').firstMatch(input);
      final iso = RegExp(r'^\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*$').firstMatch(input);
      final (int y, int mo, int d) = de != null
          ? (int.parse(de[3]!), int.parse(de[2]!), int.parse(de[1]!))
          : iso != null
          ? (int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!))
          : (0, 0, 0);
      if (y < 1990 || y > 2089 || mo < 1 || mo > 12 || d < 1 || d > 31) return null;
      return (small: null, data: [d, mo, y % 100]);
    case 232:
      final hexColor = RegExp(r'^\s*#?([0-9a-fA-F]{6})\s*$').firstMatch(input);
      if (hexColor != null) {
        final v = int.parse(hexColor[1]!, radix: 16);
        return (small: null, data: [v >> 16, (v >> 8) & 0xFF, v & 0xFF]);
      }
      final rgb = input.split(RegExp(r'[,;\s]+')).where((p) => p.isNotEmpty).map(int.tryParse).toList();
      if (rgb.length == 3 && rgb.every((c) => c != null && c >= 0 && c <= 255)) {
        return (small: null, data: [for (final c in rgb) c!]);
      }
      return null;
  }
  final s = input.trim().replaceAll(',', '.').replaceAll(RegExp(r'[^\d.\-]'), '');
  final v = double.tryParse(s);
  if (v == null) return null;
  switch (dpt.main) {
    case 1:
      return v == 0 || v == 1 ? (small: v.toInt(), data: const []) : null;
    case 5:
      final raw = switch (dpt.sub) {
        1 => (v * 255 / 100).round(),
        3 => (v * 255 / 360).round(),
        _ => v.round(),
      };
      return raw >= 0 && raw <= 255 ? (small: null, data: [raw]) : null;
    case 6:
      return v >= -128 && v <= 127 ? (small: null, data: [v.round() & 0xFF]) : null;
    case 7:
      final r = v.round();
      return r >= 0 && r <= 0xFFFF ? (small: null, data: [r >> 8, r & 0xFF]) : null;
    case 8:
      final r = v.round();
      return r >= -32768 && r <= 32767 ? (small: null, data: [(r >> 8) & 0xFF, r & 0xFF]) : null;
    case 12:
      final r = v.round();
      return r >= 0 && r <= 0xFFFFFFFF
          ? (small: null, data: [for (var i = 3; i >= 0; i--) (r >> (8 * i)) & 0xFF])
          : null;
    case 13:
      final r = v.round();
      return r >= -2147483648 && r <= 2147483647
          ? (small: null, data: [for (var i = 3; i >= 0; i--) (r >> (8 * i)) & 0xFF])
          : null;
    case 20:
      final r = v.round();
      return r >= 0 && r <= 255 ? (small: null, data: [r]) : null;
    case 9:
      final b = encodeDpt9(v);
      return b == null ? null : (small: null, data: b);
    case 14:
      final bd = ByteData(4)..setFloat32(0, v);
      return (small: null, data: bd.buffer.asUint8List());
    case 17:
      final r = v.round();
      return r >= 1 && r <= 64 ? (small: null, data: [r - 1]) : null;
    default:
      return null;
  }
}
