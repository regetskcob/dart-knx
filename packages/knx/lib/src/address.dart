/// Display style of group addresses as configured in the ETS project.
enum GroupStyle {
  /// Main/middle/sub, e.g. 1/2/3 (default).
  threeLevel,

  /// Main/sub, e.g. 1/515.
  twoLevel,

  /// Free number 0–65535, e.g. 2563.
  free,
}

/// Formats a raw 16-bit group address in [style], e.g. 0x0A03 → "1/2/3".
String formatGroupAddress(int a, [GroupStyle style = GroupStyle.threeLevel]) => switch (style) {
  GroupStyle.threeLevel => '${(a >> 11) & 0x1F}/${(a >> 8) & 0x07}/${a & 0xFF}',
  GroupStyle.twoLevel => '${(a >> 11) & 0x1F}/${a & 0x7FF}',
  GroupStyle.free => '$a',
};

/// Parses "1/2/3" (3-level) or "1/234" (2-level); a plain number only with [GroupStyle.free] (otherwise
/// "5" would be ambiguous). `null` if invalid.
int? parseGroupAddress(String s, [GroupStyle style = GroupStyle.threeLevel]) {
  final p = s.trim().split('/').map(_parsePart).toList();
  if (p.any((v) => v == null)) return null;
  return switch (p) {
    [final m?, final mi?, final sub?] when m <= 31 && mi <= 7 && sub <= 255 => (m << 11) | (mi << 8) | sub,
    [final m?, final sub?] when m <= 31 && sub <= 2047 => (m << 11) | sub,
    [final free?] when style == GroupStyle.free && free <= 0xFFFF => free,
    _ => null,
  };
}

/// Formats a raw 16-bit individual address, e.g. 0x1105 → "1.1.5".
String formatIndividual(int a) => '${(a >> 12) & 0x0F}.${(a >> 8) & 0x0F}.${a & 0xFF}';

/// Parses "1.1.5" → 0x1105. `null` if invalid or `null`.
int? parseIndividual(String? s) {
  final p = (s ?? '').trim().split('.').map(_parsePart).toList();
  return switch (p) {
    [final a?, final l?, final d?] when a <= 15 && l <= 15 && d <= 255 => (a << 12) | (l << 8) | d,
    _ => null,
  };
}

/// Digits only: `int.tryParse` would also accept "-3" or "+3", and negative parts would result in a
/// completely different address after shifting.
int? _parsePart(String s) => RegExp(r'^\d{1,5}$').hasMatch(s) ? int.parse(s) : null;
