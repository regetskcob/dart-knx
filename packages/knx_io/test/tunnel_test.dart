import 'dart:typed_data';

import 'package:knx_io/knx_io.dart';
import 'package:test/test.dart';

import 'fake_gateway.dart';

/// L_Data.req: GroupValueWrite to 1/2/3, value 0.
final _request = Uint8List.fromList([0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, 0x0A, 0x03, 0x01, 0x00, 0x80]);

void main() {
  late FakeGateway gw;
  setUp(() async => gw = await FakeGateway.start());
  tearDown(() => gw.close());

  for (final tcp in [false, true]) {
    test('${tcp ? 'TCP' : 'UDP'} tunnel: connects, receives, sends, closes', () async {
      final tunnel = KnxIpTunnel(host: '127.0.0.1', port: gw.port, tcp: tcp);
      final frames = <Uint8List>[];
      tunnel.frames.listen(frames.add);
      await tunnel.connect();
      expect(tunnel.address, 0x1126);
      expect(tunnel.label, '${tcp ? 'TCP' : 'UDP'} tunnel 1.1.38');

      gw.indicate(const [0x29, 0x00, 0xBC, 0xE0, 0x11, 0x05, 0x0A, 0x03, 0x01, 0x00, 0x81]);
      await until(() => frames.isNotEmpty);
      expect(frames.first[0], 0x29);

      await tunnel.send(_request);
      await until(() => gw.requests.isNotEmpty);
      expect(gw.requests.single.sublist(6, 8), [0x0A, 0x03]);

      await tunnel.close();
      expect(await tunnel.lost, 'Disconnected');
    });
  }

  test('no free tunnel: LinkException with a problem code', () async {
    gw.full = true;
    final tunnel = KnxIpTunnel(host: '127.0.0.1', port: gw.port);
    await expectLater(
      tunnel.connect(),
      throwsA(isA<LinkException>().having((e) => e.problem, 'problem', 'noFreeTunnel')),
    );
  });

  test('requested address on a v1 gateway falls back to any address', () async {
    gw.v1Only = true;
    final tunnel = KnxIpTunnel(host: '127.0.0.1', port: gw.port, requestedAddress: 0x11F0);
    await tunnel.connect();
    expect(tunnel.address, 0x1126);
    expect(gw.connects, 2);
    await tunnel.close();
  });
}
