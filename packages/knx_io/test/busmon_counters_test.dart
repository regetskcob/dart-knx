import 'dart:typed_data';

import 'package:knx_io/knx_io.dart';
import 'package:test/test.dart';

void main() {
  group('BusmonCounters', () {
    Uint8List frame(List<int> raw, {int status = 0}) => Uint8List.fromList([0x2B, 3, 0x03, 1, status, ...raw]);
    // Standard frame 1.1.5 → 1/2/3 with a valid checksum.
    final data = () {
      final body = [0xBC, 0x11, 0x05, 0x0A, 0x03, 0xE1, 0x00, 0x81];
      return [...body, ~body.fold<int>(0, (a, b) => a ^ b) & 0xFF];
    }();

    test('counts data, acknowledgements, rejections and damaged frames', () {
      final c = BusmonCounters()
        ..add(frame(data))
        ..add(frame([0xCC]))
        ..add(frame(data))
        ..add(frame([0x0C]))
        ..add(frame([0xC0]))
        ..add(frame(data, status: 0x80))
        ..add(frame([...data.sublist(0, 8), 0x00]));
      expect(c.toJson(), {'data': 2, 'acks': 1, 'naks': 1, 'busy': 1, 'damaged': 2, 'orphanAcks': 0, 'seqGaps': 0});
    });

    test('an acknowledgement without a data frame before it is noticed', () {
      final c = BusmonCounters()
        ..add(frame([0xCC]))
        ..add(frame(data))
        ..add(frame([0xCC]))
        ..add(frame([0xCC]));
      expect(c.orphanAcks, 2);
      expect(c.acks, 3);
    });

    test('gaps in the sequence number, as measured on a kBerry', () {
      // Data frame 0, ACK 1, data frame 2 missing, ACK 3, …, across the wrap 7 → 0.
      final c = BusmonCounters()
        ..add(frame(data, status: 0))
        ..add(frame([0xCC], status: 1))
        ..add(frame([0xCC], status: 3))
        ..add(frame(data, status: 6))
        ..add(frame([0xCC], status: 7))
        ..add(frame([0xCC], status: 1));
      expect(c.seqGaps, 4, reason: '2, 4, 5 und 0 fehlen');
      expect(c.orphanAcks, 2);
      expect(c.data, 2);
    });

    test('after reconnecting the sequence number starts again', () {
      final c = BusmonCounters()
        ..add(frame(data, status: 5))
        ..resync()
        ..add(frame([0xCC], status: 0));
      expect(c.seqGaps, 0);
      expect(c.orphanAcks, 1, reason: 'kein Datenrahmen aus der alten Verbindung');
    });

    test('interfaces without numbering (always 0) have no gaps', () {
      final c = BusmonCounters();
      for (var i = 0; i < 5; i++) {
        c.add(frame(data));
      }
      expect(c.seqGaps, 0);
    });
  });
}
