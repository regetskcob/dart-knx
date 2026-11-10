import 'dart:typed_data';

import 'package:knx/knx.dart';
import 'package:test/test.dart';

final t0 = DateTime.utc(2026, 11, 8, 12);

Telegram tg(int ms, {int src = 0x1105, int ga = 0x0A03, int value = 1, int hop = 6, bool repeated = false}) => Telegram(
  time: t0.add(Duration(milliseconds: ms)),
  source: src,
  destination: ga,
  type: TelegramType.write,
  data: Uint8List.fromList([value]),
  isSmall: true,
  hopCount: hop,
  repeated: repeated,
);

void main() {
  group('TapMerger', () {
    test('single tap point passes through at once', () {
      final m = TapMerger();
      expect(m.add(0, tg(0)), hasLength(1));
      expect(m.pending, isFalse);
    });

    test('forwarded telegram becomes one entry with a sighting', () {
      final m = TapMerger(taps: 2);
      expect(m.add(0, tg(0)), isEmpty);
      final out = m.add(1, tg(3, hop: 5));
      expect(out, hasLength(1));
      expect(out.single.tap, 0);
      expect(out.single.sightings, [const Sighting(1, Duration(milliseconds: 3), 5)]);
      expect(out.single.taps.toList(), [0, 1]);
    });

    test('the sender\'s line wins over arrival: highest hop count, time of the earliest', () {
      // Measured 10 Nov 2026: sender on line 1.2, the KNX IP interface behind the coupler (hop 5)
      // reports some 40 ms before the kBerry on the sender's own line (hop 6).
      final m = TapMerger(taps: 2);
      expect(m.add(1, tg(0, hop: 5)), isEmpty);
      final out = m.add(0, tg(40, hop: 6));
      expect(out, hasLength(1));
      expect(out.single.tap, 0);
      expect(out.single.hopCount, 6);
      expect(out.single.time, t0, reason: 'order in the history stays');
      expect(out.single.sightings, [const Sighting(1, Duration.zero, 5)]);
      expect(out.single.taps.toList(), [0, 1]);
    });

    test('equal hop counts: the first sighting stays the origin', () {
      final m = TapMerger(taps: 2);
      m.add(1, tg(0));
      final out = m.add(0, tg(2));
      expect(out.single.tap, 1);
      expect(out.single.sightings, [const Sighting(0, Duration(milliseconds: 2), 6)]);
    });

    test('three tap points: origin from the middle, the others keep their offsets', () {
      final m = TapMerger(taps: 3);
      m.add(2, tg(0, hop: 4));
      m.add(1, tg(10, hop: 6));
      final out = m.add(0, tg(30, hop: 5));
      expect(out.single.tap, 1);
      expect(out.single.time, t0);
      expect(out.single.sightings, [
        const Sighting(2, Duration.zero, 4),
        const Sighting(0, Duration(milliseconds: 30), 5),
      ]);
    });

    test('filtered telegram leaves after the window with one tap point', () {
      final m = TapMerger(taps: 2);
      m.add(1, tg(0));
      expect(m.flush(t0.add(const Duration(milliseconds: 50))), isEmpty);
      final out = m.flush(t0.add(const Duration(milliseconds: 100)));
      expect(out.single.tap, 1);
      expect(out.single.sightings, isEmpty);
    });

    test('double press: identical telegrams match in order', () {
      final m = TapMerger(taps: 2);
      m.add(0, tg(0));
      m.add(0, tg(5));
      final a = m.add(1, tg(2));
      final b = m.add(1, tg(7));
      expect(a.single.time, t0);
      expect(a.single.sightings.single.offset, const Duration(milliseconds: 2));
      expect(b.single.time, t0.add(const Duration(milliseconds: 5)));
      expect(b.single.sightings.single.offset, const Duration(milliseconds: 2));
    });

    test('repeat stays its own entry', () {
      final m = TapMerger(taps: 2);
      m.add(0, tg(0));
      m.add(0, tg(20, repeated: true));
      final out = m.add(1, tg(21, repeated: true));
      // The first entry is not complete yet, so nothing leaves before it.
      expect(out, isEmpty);
      final rest = m.flush(t0.add(const Duration(milliseconds: 200)));
      expect(rest, hasLength(2));
      expect(rest[0].sightings, isEmpty);
      expect(rest[1].repeated, isTrue);
      expect(rest[1].sightings.single.tap, 1);
    });

    test('outside the window: two entries', () {
      final m = TapMerger(taps: 2);
      m.add(0, tg(0));
      final out = [...m.add(1, tg(150)), ...m.flushAll()];
      expect(out, hasLength(2));
      expect(out.every((t) => t.sightings.isEmpty), isTrue);
    });

    test('tap point with its own wider window (VPN)', () {
      final m = TapMerger(taps: 2, windows: {1: const Duration(milliseconds: 250)});
      m.add(0, tg(0));
      final out = m.add(1, tg(180));
      expect(out.single.sightings.single.tap, 1);
    });

    test('wider window also counts when the VPN tap point arrives first', () {
      final m = TapMerger(taps: 2, windows: {1: const Duration(milliseconds: 250)});
      m.add(1, tg(0));
      final out = m.add(0, tg(180));
      expect(out.single.tap, 1);
      expect(out.single.sightings.single.tap, 0);
    });

    test('tap point drops mid-window: entry still leaves', () {
      final m = TapMerger(taps: 3);
      m.add(0, tg(0));
      m.add(1, tg(2));
      m.taps = 2; // tap point 2 disconnected
      final out = m.flush(t0.add(const Duration(milliseconds: 2)));
      expect(out.single.taps.toList(), [0, 1]);
    });

    test('order of first sighting is kept', () {
      final m = TapMerger(taps: 2);
      m.add(0, tg(0, ga: 1));
      m.add(0, tg(1, ga: 2));
      expect(m.add(1, tg(2, ga: 2)), isEmpty, reason: 'ga 1 is still open');
      final out = m.add(1, tg(3, ga: 1));
      expect(out.map((t) => t.destination), [1, 2]);
    });
  });

  test('tap and sightings survive JSON', () {
    final t = tg(0).atTap(2, sightings: [const Sighting(0, Duration(microseconds: 1500), 5)]);
    final back = Telegram.fromJson(t.toJson());
    expect(back.tap, 2);
    expect(back.sightings, t.sightings);
    expect(Telegram.fromJson(tg(0).toJson()).toJson().containsKey('tp'), isFalse);
  });
}
