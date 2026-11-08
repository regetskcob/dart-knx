import 'dart:typed_data';

import 'package:knx/knx.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime(2026, 11, 7, 12);

  Telegram t(int ga, DateTime time, {bool outgoing = false, TelegramType type = TelegramType.write}) => Telegram(
    time: time,
    source: 0x1105,
    destination: ga,
    type: type,
    data: Uint8List.fromList([1]),
    isSmall: true,
    outgoing: outgoing,
  );

  test('cyclic and overdue, events and own telegrams not', () {
    final silences = cycleSilencesOf([
      // Every 10 minutes until an hour ago.
      for (var i = 0; i < 10; i++) t(1, now.subtract(Duration(minutes: 60 + i * 10))),
      // Every 10 minutes until just now.
      for (var i = 0; i < 10; i++) t(2, now.subtract(Duration(minutes: i * 10))),
      // Only three events.
      for (var i = 0; i < 3; i++) t(3, now.subtract(Duration(hours: 5 + i))),
      // Sent by ourselves or read requests: do not count.
      for (var i = 0; i < 10; i++) t(4, now.subtract(Duration(minutes: 60 + i * 10)), outgoing: true),
      for (var i = 0; i < 10; i++) t(5, now.subtract(Duration(minutes: 60 + i * 10)), type: TelegramType.read),
    ], now);
    expect(silences.single.address, 1);
    expect(silences.single.interval, const Duration(minutes: 10));
    expect(silences.single.last, now.subtract(const Duration(minutes: 60)));
    expect(silences.single.limit, const Duration(minutes: 30));
  });

  test('at least 15 minutes, at most a 6-hour interval', () {
    // Every minute, silent for 10 minutes: below the floor of 15 minutes.
    final fast = [for (var i = 0; i < 10; i++) now.subtract(Duration(minutes: 10 + i)).microsecondsSinceEpoch];
    // Every 7 hours: not cyclic in this sense.
    final slow = [for (var i = 0; i < 10; i++) now.subtract(Duration(hours: 30 + i * 7)).microsecondsSinceEpoch];
    expect(cycleSilences({1: fast, 2: slow}, now), isEmpty);
    fast.add(now.subtract(const Duration(minutes: 16)).microsecondsSinceEpoch);
    expect(cycleSilences({1: fast}, now.add(const Duration(minutes: 6))).single.address, 1);
  });
}
