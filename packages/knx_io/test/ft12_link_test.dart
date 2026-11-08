import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:knx_io/knx_io.dart';
import 'package:test/test.dart';

import 'fake_gateway.dart' show until;
import 'fake_kberry.dart';

/// L_Data.req: GroupValueWrite to 1/2/3, value 0, source 0.0.0.
final requestOff = Uint8List.fromList([0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, 0x0A, 0x03, 0x01, 0x00, 0x80]);

/// L_Busmon.ind with status and timestamp: 1.1.5 → 1/1/1 writes 1, valid checksum.
final busmonWrite = [
  0x2B, 0x07, 0x03, 0x01, 0x00, 0x04, 0x02, 0x12, 0x34, //
  0xBC, 0x11, 0x05, 0x09, 0x01, 0xE1, 0x00, 0x81, 0x3F,
];

void main() {
  late FakeKberry module;
  Ft12CemiLink link({bool busmonitor = false, int? address, FakeKberry? fake}) => Ft12CemiLink(
    open: (baud) async => module = fake ?? FakeKberry(lineBaud: baud),
    busmonitor: busmonitor,
    requestedAddress: address,
    keepalive: const Duration(milliseconds: 100),
    confirmTimeout: const Duration(milliseconds: 300),
  );

  group('Ft12CemiLink', () {
    test('link layer: delivers L_Data.ind, sends with its own address, restores on close', () async {
      final l = link();
      final frames = <Uint8List>[];
      l.frames.listen(frames.add);
      await l.connect();
      expect(module.commMode, 0x00);
      expect(l.baud, 19200);
      expect(l.address, 0xFFFF);
      expect(l.label, 'FT1.2 link layer 15.15.255');
      await until(() => frames.isNotEmpty);
      expect(frames.first, module.linkFrames.first);

      await l.send(requestOff);
      final sent = module.requests.single;
      expect(sent.sublist(4, 6), [0xFF, 0xFF], reason: 'source = own address');
      await until(() => frames.length == 2);
      expect(frames.last[0], 0x2E, reason: 'the confirmation is delivered like from a tunnel');

      await l.close();
      expect(module.commMode, 0xF0, reason: 'back in BAOS mode');
      expect(module.closed, isTrue);
      expect(await l.lost, 'Disconnected');
    });

    test('negative confirmation (NCON) fails the send', () async {
      final l = link();
      await l.connect();
      module.negativeConfirm = true;
      await expectLater(
        l.send(requestOff),
        throwsA(isA<LinkException>().having((e) => e.message, 'message', contains('NCON'))),
      );
      module.negativeConfirm = false;
      await l.send(requestOff);
      await l.close();
    });

    test('writes the requested address into the device object', () async {
      final l = link(address: 0x11FA);
      await l.connect();
      expect(module.address, 0x11FA);
      expect(l.address, 0x11FA);
      await l.close();
    });

    test('bus monitor: raw frames with acknowledgements, sending rejected', () async {
      final l = link(busmonitor: true);
      final frames = <Uint8List>[];
      l.frames.listen(frames.add);
      await l.connect();
      expect(module.commMode, 0x01);
      await until(() => frames.length == module.busmonFrames.length);
      expect(frames.every((f) => f[0] == 0x2B), isTrue);
      await expectLater(l.send(requestOff), throwsA(isA<LinkException>()));
      await l.close();
      expect(module.commMode, 0xF0);
    });

    test('module without bus monitor: clear error, module stays in BAOS mode', () async {
      final l = link(busmonitor: true, fake: FakeKberry(modes: 0x0001));
      await expectLater(
        l.connect(),
        throwsA(isA<LinkException>().having((e) => e.message, 'message', contains('bus monitor'))),
      );
      expect(module.commMode, 0xF0);
      expect(module.closed, isTrue);
    });

    test('silent module: tries both baud rates, then fails', () async {
      final tried = <int>[];
      final l = Ft12CemiLink(
        open: (baud) async {
          tried.add(baud);
          return FakeKberry(baud: 9600, lineBaud: baud);
        },
      );
      await expectLater(l.connect(), throwsA(isA<LinkException>()));
      expect(tried, [19200, 115200]);
    });

    test('finds 115200 baud', () async {
      final l = Ft12CemiLink(open: (baud) async => module = FakeKberry(baud: 115200, lineBaud: baud));
      await l.connect();
      expect(l.baud, 115200);
      await l.close();
    });

    test('M_Reset.ind: connection lost, line released', () async {
      final l = link();
      await l.connect();
      module.restart();
      expect(await l.lost.timeout(const Duration(seconds: 2)), 'FT1.2 module restarted');
      await until(() => module.closed);
    });

    test('module stops responding: keep-alive fails', () async {
      final l = link();
      await l.connect();
      module.mute = true;
      expect(await l.lost.timeout(const Duration(seconds: 5)), contains('stopped responding'));
      await until(() => module.closed);
    });

    test('read error: connection lost', () async {
      final fake = _BreakingKberry();
      final l = link(fake: fake);
      await l.connect();
      fake.broken = true;
      expect(await l.lost.timeout(const Duration(seconds: 2)), contains('read error'));
    });

    test('repeated frame (lost acknowledgement) arrives once', () async {
      final l = link();
      final frames = <Uint8List>[];
      l.frames.listen(frames.add);
      await l.connect();
      await until(() => frames.length == 1);
      module
        ..push([0x29, 0x00, 0xBC, 0xE0, 0x11, 0x06, 0x09, 0x02, 0x01, 0x00, 0x80])
        ..repeatLast();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(frames, hasLength(2));
      await l.close();
    });

    test('no confirmation: send fails, connection stays', () async {
      final l = link();
      await l.connect();
      module.confirmRequests = false;
      await expectLater(l.send(requestOff), throwsA(isA<LinkException>()));
      expect(module.requests, hasLength(1));
      await l.close();
    });

    test('new link waits until the old one released the line', () async {
      final first = link();
      await first.connect();
      final old = module;
      unawaited(first.close());
      final second = link();
      await second.connect();
      expect(old.closed, isTrue);
      expect(old.commMode, 0xF0);
      await second.close();
    });
  });

  test('a link waits until another user of the line (occupy) is done', () async {
    final probe = KberryProbe((baud) async => FakeKberry(lineBaud: baud));
    var probeDone = false;
    Ft12CemiLink.occupy(
      '/dev/ttyTEST',
      probe.run(listen: const Duration(milliseconds: 80)).then((_) => probeDone = true),
    );
    final l = Ft12CemiLink(
      device: '/dev/ttyTEST',
      open: (baud) async => module = FakeKberry(lineBaud: baud),
    );
    await l.connect();
    expect(probeDone, isTrue, reason: 'connected only after the probe');
    await l.close();
  });

  group('busmonToLData', () {
    test('data telegram becomes L_Data.ind like from a tunnel', () {
      expect(busmonToLData(Uint8List.fromList(busmonWrite)), [
        0x29, 0x00, 0xBC, 0xE0, 0x11, 0x05, 0x09, 0x01, 0x01, 0x00, 0x81, //
      ]);
      // A repetition (bit 5 cleared) stays recognisable.
      final repeated = List.of(busmonWrite)
        ..[9] = 0x9C
        ..[17] = 0x1F;
      final cemi = busmonToLData(Uint8List.fromList(repeated))!;
      expect(cemi[2] & 0x20, 0, reason: 'repeat flag kept in control field 1');
    });

    test('acknowledgements, damaged and truncated frames: nothing', () {
      expect(busmonToLData(Uint8List.fromList([0x2B, 0x00, 0xCC])), isNull);
      expect(busmonToLData(Uint8List.fromList(List.of(busmonWrite)..[17] = 0x3A)), isNull, reason: 'checksum');
      expect(busmonToLData(Uint8List.fromList(List.of(busmonWrite)..[4] = 0x80)), isNull, reason: 'frame error');
      expect(busmonToLData(Uint8List.fromList(busmonWrite.sublist(0, 15))), isNull);
      expect(busmonToLData(Uint8List.fromList([0x29, 0x00, 0xBC])), isNull);
    });
  });
}

class _BreakingKberry extends FakeKberry {
  bool broken = false;
  @override
  Future<Uint8List> read() async {
    if (broken) throw const FileSystemException('I/O error');
    return super.read();
  }
}
