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
    // Every minute for 70 minutes, silent for 10 minutes: below the floor of 15 minutes.
    final fast = [for (var i = 0; i < 70; i++) now.subtract(Duration(minutes: 10 + i)).microsecondsSinceEpoch];
    // Every 7 hours: not cyclic in this sense.
    final slow = [for (var i = 0; i < 10; i++) now.subtract(Duration(hours: 30 + i * 7)).microsecondsSinceEpoch];
    expect(cycleSilences({1: fast, 2: slow}, now), isEmpty);
    fast.add(now.subtract(const Duration(minutes: 16)).microsecondsSinceEpoch);
    expect(cycleSilences({1: fast}, now.add(const Duration(minutes: 6))).single.address, 1);
  });

  group('bursts are not cyclic', () {
    int us(DateTime d) => d.microsecondsSinceEpoch;

    test('dimming: a telegram per second while dimming, a few times a day', () {
      final dim = [
        for (var day = 0; day < 7; day++)
          for (var burst = 0; burst < 6; burst++)
            for (var i = 0; i < 8; i++) us(now.subtract(Duration(days: day, hours: 1 + burst * 3, seconds: i))),
      ];
      expect(cycleSilences({1: dim}, now), isEmpty);
    });

    test('blinds status while moving, switching with feedback', () {
      final moving = [
        for (var day = 0; day < 7; day++)
          for (var move = 0; move < 4; move++)
            for (var i = 0; i < 5; i++) us(now.subtract(Duration(days: day, hours: 2 + move * 4, seconds: i * 17))),
      ];
      // Switched on and off a few times in a row each evening.
      final switching = [
        for (var day = 0; day < 7; day++)
          for (var i = 0; i < 12; i++) us(now.subtract(Duration(days: day, hours: 3, minutes: i * 3))),
      ];
      expect(cycleSilences({1: moving, 2: switching}, now), isEmpty);
    });

    test('a single burst in a short history', () {
      final burst = [for (var i = 0; i < 20; i++) us(now.subtract(Duration(minutes: 20, seconds: i)))];
      expect(cycleSilences({1: burst}, now), isEmpty);
    });

    test('cyclic with a gap in the recording still counts', () {
      // Every 15 minutes for 7 days, recording off for 4 of them, silent for 2 hours.
      final cyclic = [
        for (var i = 0; i < 7 * 96; i++)
          if (i < 2 * 96 || i > 6 * 96) us(now.subtract(Duration(hours: 2, minutes: 15 * i))),
      ];
      final s = cycleSilences({1: cyclic}, now).single;
      expect(s.interval, const Duration(minutes: 15));
      // Status every 30 seconds for an hour and a half, then silent.
      final status = [for (var i = 0; i < 180; i++) us(now.subtract(Duration(minutes: 30, seconds: 30 * i)))];
      expect(cycleSilences({2: status}, now).single.address, 2);
    });
  });
}
