import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:knx_io/knx_io.dart';
import 'package:test/test.dart';

/// The shared vectors in `test-vectors/ft12.json` at the repository root; the
/// Python package tests against the same file.
void main() {
  final file = File('../../test-vectors/ft12.json');
  // Only in the repository, not in the published package.
  if (!file.existsSync()) return;
  final v = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  List<int> bytes(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];
  String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  test('constants', () {
    expect(v['ack'], ft12Ack);
    expect(v['reset'], hex(ft12Reset));
  });

  for (final e in (v['encode']! as List).cast<Map<String, Object?>>()) {
    test('encode: ${e['name']}', () {
      expect(hex(ft12Frame(bytes(e['data']! as String), fcb: e['fcb']! as bool)), e['frame']);
    });
  }

  for (final d in (v['decode']! as List).cast<Map<String, Object?>>()) {
    test('decode: ${d['name']}', () {
      final decoder = Ft12Decoder();
      final events = [for (final c in d['chunks']! as List) ...decoder.add(bytes(c as String))];
      final json = [
        for (final e in events)
          switch (e) {
            Ft12AckEvent() => {'type': 'ack'},
            Ft12FixedEvent(:final control) => {'type': 'fixed', 'control': control},
            Ft12DataEvent(:final control, :final data) => {'type': 'data', 'control': control, 'data': hex(data)},
          },
      ];
      expect(json, d['events']);
      expect(decoder.skipped, d['skipped']);
    });
  }

  for (final b in (v['busmonToLData']! as List).cast<Map<String, Object?>>()) {
    test('busmonToLData: ${b['name']}', () {
      final l = busmonToLData(Uint8List.fromList(bytes(b['cemi']! as String)));
      expect(l == null ? null : hex(l), b['ldata']);
    });
  }

  test('BusmonCounters over all bus monitor frames', () {
    final c = BusmonCounters();
    final m = v['busmonCounters']! as Map<String, Object?>;
    for (final f in m['frames']! as List) {
      c.add(Uint8List.fromList(bytes(f as String)));
    }
    expect(c.toJson(), m['counters']);
  });
}
