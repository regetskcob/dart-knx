/// Upper-case hex with a space between bytes, e.g. "0C 1A" (for display).
String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

/// Upper-case hex without separators, e.g. "0C1A" (history lines, logs, JSON).
String hexOf(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

/// Parses hex like "0C 1A", "0c1a", "0C:1A" or "0x0C 0x1A". `null` if invalid or empty.
List<int>? parseHex(String s) {
  final clean = s.replaceAll(RegExp(r'[\s:,-]|0x'), '');
  if (clean.isEmpty || clean.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) {
    return null;
  }
  return [for (var i = 0; i < clean.length; i += 2) int.parse(clean.substring(i, i + 2), radix: 16)];
}
