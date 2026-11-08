import 'dart:typed_data';

import 'package:knx/knx.dart';
import 'package:test/test.dart';

Telegram _write(List<int> data, {int? small}) => Telegram(
  time: DateTime(2026, 11, 8),
  source: 0x1105,
  destination: 0x0A03,
  type: TelegramType.write,
  data: Uint8List.fromList(data),
  isSmall: small != null,
);

void main() {
  test('no values: no guess', () {
    expect(guessDpt(const []), isNull);
  });

  test('two-byte float with a temperature name', () {
    final g = guessDpt([
      _write([0x0C, 0x1A]),
    ], name: 'Temperatur Wohnen')!;
    expect(g.dpt, const Dpt(9, 1));
    expect(g.fromName, isTrue);
  });

  test('one bit on a blind is up/down', () {
    final g = guessDpt([
      _write([1], small: 1),
    ], name: 'Rollladen Küche')!;
    expect(g.dpt, const Dpt(1, 8));
  });

  test('candidates by payload length', () {
    expect(dptCandidates(4), contains(const Dpt(14, 56)));
  });
}
