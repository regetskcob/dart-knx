import 'dart:typed_data';

import 'package:knx_io/knx_io.dart';
import 'package:test/test.dart';

import 'fake_kberry.dart';

void main() {
  group('FT1.2', () {
    test('frame as in the Weinzierl manual (read serial number)', () {
      expect(ft12Frame([0xFC, 0x00, 0x00, 0x01, 0x0B, 0x10, 0x01], fcb: false), [
        0x68,
        0x08,
        0x08,
        0x68,
        0x53,
        0xFC,
        0x00,
        0x00,
        0x01,
        0x0B,
        0x10,
        0x01,
        0x6C,
        0x16,
      ]);
      expect(ft12Frame([0xA7], fcb: true).sublist(4, 5), [0x73]);
    });

    test('decoder splits answer, acknowledgement and reset, also in pieces', () {
      final decoder = Ft12Decoder();
      final answer = [
        0x68, 0x0E, 0x0E, 0x68, 0xD3, 0xFB, 0x00, 0x00, 0x01, 0x0B, 0x10, 0x01, //
        0x00, 0xC5, 0x00, 0x00, 0x00, 0x00, 0xB0, 0x16,
      ];
      final events = [
        ...decoder.add([0xE5, ...answer.sublist(0, 7)]),
        ...decoder.add([...answer.sublist(7), 0x10, 0x40, 0x40, 0x16]),
      ];
      expect(events, hasLength(3));
      expect(events[0], isA<Ft12AckEvent>());
      final data = events[1] as Ft12DataEvent;
      expect(data.control, 0xD3);
      expect(data.data.sublist(7), [0x00, 0xC5, 0x00, 0x00, 0x00, 0x00]);
      expect((events[2] as Ft12FixedEvent).control, 0x40);
      expect(decoder.skipped, 0);
    });

    test('decoder skips garbage and wrong checksums', () {
      final decoder = Ft12Decoder();
      final events = decoder.add([0x00, 0xFF, 0x68, 0x02, 0x02, 0x68, 0x73, 0xA7, 0x00, 0x16, 0xE5]);
      expect(events.single, isA<Ft12AckEvent>());
      expect(decoder.skipped, greaterThan(0));
    });
  });

  group('KberryProbe', () {
    const listen = Duration(milliseconds: 60);

    test('module with bus monitor: all steps ok, acknowledgements counted', () async {
      late FakeKberry module;
      final steps = <String>[];
      final report = await KberryProbe(
        (baud) async => module = FakeKberry(lineBaud: baud),
        onStep: steps.add,
      ).run(listen: listen);
      final byId = {for (final s in report['steps']! as List) (s as Map)['id']: s};
      expect(byId.keys, kberrySteps);
      expect(steps, kberrySteps);
      expect(report['baud'], 19200);
      for (final id in kberrySteps) {
        expect(byId[id]!['status'], 'ok', reason: id);
      }
      expect(byId['serial']!['serial'], '00C500000000');
      expect(byId['modes']!['busmonitor'], true);
      expect(byId['commMode']!['mode'], 0xF0);
      expect(byId['linkLayer']!['frames'], 1);
      final busmon = byId['busmonitor']!;
      expect(busmon['frames'], 5);
      expect(busmon['ack'], 2);
      expect(busmon['nak'], 1);
      expect(busmon['data'], 2);
      expect(busmon['repeated'], 1);
      expect(busmon['errors'], 1);
      expect(busmon['timestamps'], 1);
      // The fake data frames carry a wrong checksum, so both ACKs follow a damaged frame.
      expect(busmon['orphanAcks'], 2);
      expect(busmon['seqGaps'], 0);
      expect(module.commMode, 0xF0, reason: 'back in BAOS mode at the end');
      expect(module.hostAcks, greaterThan(5), reason: 'every data frame acknowledged');
      expect(module.closed, isTrue);
    });

    test('finds 115200 baud when 19200 stays silent', () async {
      final report = await KberryProbe((baud) async => FakeKberry(baud: 115200, lineBaud: baud)).run(listen: listen);
      expect(report['baud'], 115200);
      final reset = (report['steps']! as List).first as Map;
      expect(reset['status'], 'ok');
      expect((reset['tried'] as List).map((t) => (t as Map)['ok']), [false, true]);
    });

    test('no answer: reset fails, the rest is skipped', () async {
      final report = await KberryProbe((baud) async => FakeKberry(baud: 9600, lineBaud: baud)).run(listen: listen);
      final steps = [for (final s in report['steps']! as List) (s as Map)['status']];
      expect(steps.first, 'fail');
      expect(steps.skip(1), everyElement('skip'));
      expect(steps, hasLength(kberrySteps.length));
    });

    test('no bus monitor: warning for the modes, failure when switching', () async {
      final report = await KberryProbe((baud) async => FakeKberry(lineBaud: baud, modes: 0x0001, rejectBusmon: true))
          .run(listen: listen);
      final byId = {for (final s in report['steps']! as List) (s as Map)['id']: s};
      expect(byId['modes']!['status'], 'warn');
      expect(byId['modes']!['busmonitor'], false);
      expect(byId['busmonitor']!['status'], 'fail');
      expect(byId['restore']!['status'], 'ok');
    });

    test('read error during reset: line is closed', () async {
      final line = BrokenLine();
      final report = await KberryProbe((baud) async => line).run(listen: listen);
      final first = (report['steps']! as List).first as Map;
      expect(first['status'], 'fail');
      expect(first['error'], contains('I/O error'));
      expect(line.closed, isTrue);
    });

    test('abort while listening: module back in BAOS mode', () async {
      late FlakyKberry module;
      final report = await KberryProbe((baud) async => module = FlakyKberry(lineBaud: baud)).run(listen: listen);
      final byId = {for (final s in report['steps']! as List) (s as Map)['id']: s};
      expect(byId['linkLayer']!['status'], 'fail');
      expect(byId['busmonitor']!['status'], 'skip');
      expect(module.commMode, 0xF0);
      expect(module.closed, isTrue);
    });

    test('device cannot be opened', () async {
      final report = await KberryProbe((baud) async => throw StateError('no device')).run(listen: listen);
      final first = (report['steps']! as List).first as Map;
      expect(first['status'], 'fail');
      expect(first['error'], contains('no device'));
    });
  });

  test('bus monitor frames without additional info and truncated', () {
    final counts = classifyBusmon([
      Uint8List.fromList([0x2B, 0x00, 0xC0]),
      Uint8List.fromList([0x2B, 0x00, 0x00]),
      Uint8List.fromList([0x2B]),
      Uint8List.fromList([0x2B, 0x05, 0x03]),
    ]);
    expect(counts['busy'], 1);
    expect(counts['nakBusy'], 1);
    expect(counts['other'], 2);
  });
}
