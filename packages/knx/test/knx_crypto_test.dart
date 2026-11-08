import 'dart:typed_data';

import 'package:knx/secure.dart';
import 'package:test/test.dart';

/// Examples from KNX AN159 (IP Secure) and RFC 7748 (X25519).
void main() {
  test('CBC-MAC: SessionResponse und RoutingIndication (AN159)', () {
    expect(
      cbcMac(
        deriveDeviceAuthentication('trustme'),
        fromHex(
          '06 10 09 52 00 38 00 01 b7 52 be 24 64 59 26 0f'
          '6b 0c 48 01 fb d5 a6 75 99 f8 3b 40 57 b3 ef 1e'
          '79 e4 69 ac 17 23 4e 15',
        ),
      ),
      fromHex('da 3d c6 af 79 89 6a a6 ee 75 73 d6 99 50 c2 83'),
    );
    expect(
      cbcMac(
        fromHex('00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f'),
        fromHex('06 10 09 50 00 37 00 00'),
        payload: fromHex('06 10 05 30 00 11 29 00 bc d0 11 59 0a de 01 00 81'),
        block0: fromHex('c0 c1 c2 c3 c4 c5 00 fa 12 34 56 78 af fe 00 11'),
      ),
      fromHex('bd 0a 29 4b 95 25 54 b2 35 39 20 4c 22 71 d2 6b'),
    );
  });

  test('CTR: encrypt and decrypt (AN159)', () {
    final key = fromHex('00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f');
    final counter0 = fromHex('c0 c1 c2 c3 c4 c5 00 fa 12 34 56 78 af fe ff 00');
    final (data, mac) = ctr(
      key,
      counter0,
      fromHex('bd 0a 29 4b 95 25 54 b2 35 39 20 4c 22 71 d2 6b'),
      fromHex('06 10 05 30 00 11 29 00 bc d0 11 59 0a de 01 00 81'),
    );
    expect(data, fromHex('b7 ee 7e 8a 1c 2f 7b ba be c7 75 fd 6e 10 d0 bc 4b'));
    expect(mac, fromHex('72 12 a0 3a aa e4 9d a8 56 89 77 4c 1d 2b 4d a4'));
    final (plain, macTr) = ctr(key, counter0, mac, data);
    expect(plain, fromHex('06 10 05 30 00 11 29 00 bc d0 11 59 0a de 01 00 81'));
    expect(macTr, fromHex('bd 0a 29 4b 95 25 54 b2 35 39 20 4c 22 71 d2 6b'));
  });

  test('derive passwords (AN159)', () {
    expect(deriveDeviceAuthentication('trustme'), fromHex('e1 58 e4 01 20 47 bd 6c c4 1a af bc 5c 04 c1 fc'));
    expect(deriveUserPassword('secret'), fromHex('03 fc ed b6 66 60 25 1e c8 1a 1a 71 69 01 69 6a'));
  });

  test('X25519 (RFC 7748 and AN159 keys)', () {
    expect(
      x25519(
        fromHex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4'),
        fromHex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c'),
      ),
      fromHex('c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552'),
    );
    final base = List<int>.filled(32, 0)..[0] = 9;
    expect(
      x25519(
        fromHex('b8 fa bd 62 66 5d 8b 9e 8a 9d 8b 1f 4b ca 42 c8 c2 78 9a 61 10 f5 0e 9d d7 85 b3 ed e8 83 f3 78'),
        base,
      ),
      fromHex('0a a2 27 b4 fd 7a 32 31 9b a9 96 0a c0 36 ce 0e 5c 45 07 b5 ae 55 16 1f 10 78 b1 dc fb 3c b6 31'),
    );
    final (private, public) = x25519KeyPair();
    expect(private, hasLength(32));
    expect(public, hasLength(32));
  });

  test('IP Secure handshake as in the AN159 example', () async {
    final session = IpSecureSession(
      userId: 1,
      userPassword: 'secret',
      deviceAuthentication: 'trustme',
      serialNumber: fromHex('00 fa 12 34 56 78'),
      messageTag: fromHex('af fe'),
      keyPair: (
        fromHex('b8 fa bd 62 66 5d 8b 9e 8a 9d 8b 1f 4b ca 42 c8 c2 78 9a 61 10 f5 0e 9d d7 85 b3 ed e8 83 f3 78'),
        fromHex('0a a2 27 b4 fd 7a 32 31 9b a9 96 0a c0 36 ce 0e 5c 45 07 b5 ae 55 16 1f 10 78 b1 dc fb 3c b6 31'),
      ),
    );
    final sent = <List<int>>[];
    final done = session.handshake(sent.add);
    await Future<void>.delayed(Duration.zero);
    expect(sent.single.sublist(0, 6), [0x06, 0x10, 0x09, 0x51, 0x00, 0x2E]);
    // SESSION_RESPONSE
    expect(
      session.handle(
        Uint8List.fromList([
          ...fromHex('06 10 09 52 00 38 00 01'),
          ...fromHex('bd f0 99 90 99 23 14 3e f0 a5 de 0b 3b e3 68 7b c5 bd 3c f5 f9 e6 f9 01 69 9c d8 70 ec 1f f8 24'),
          ...fromHex('a9 22 50 5a aa 43 61 63 57 0b d5 49 4c 2d f2 a3'),
        ]),
      ),
      isNull,
    );
    await Future<void>.delayed(Duration.zero);
    // SESSION_AUTHENTICATE, encrypted
    expect(
      sent.last,
      fromHex(
        '06 10 09 50 00 3e 00 01 00 00 00 00 00 00 00 fa 12 34 56 78 af fe'
        '79 15 a4 f3 6e 6e 42 08 d2 8b 4a 20 7d 8f 35 c0 d1 38 c2 6a 7b 5e 71 69'
        '52 db a8 e7 e4 bd 80 bd 7d 86 8a 3a e7 87 49 de',
      ),
    );
    // SESSION_STATUS ok, encrypted
    session.handle(
      fromHex(
        '06 10 09 50 00 2e 00 01 00 00 00 00 00 00 00 fa aa aa aa aa af fe'
        '26 15 6d b5 c7 49 88 8f a3 73 c3 e0 b4 bd e4 49 7c 39 5e 4b 1c 2f 46 a1',
      ),
    );
    await done;
    expect(session.established, isTrue);

    // own frame there and back
    final plain = fromHex('06 10 04 20 00 15 04 01 00 00 29 00 bc e0 11 05 0a 03 01 00 81');
    final wrapped = session.wrap(plain);
    expect(wrapped.sublist(0, 4), [0x06, 0x10, 0x09, 0x50]);
  });

  test('IP Secure: wrong device code is detected', () async {
    final session = IpSecureSession(
      userId: 1,
      userPassword: 'secret',
      deviceAuthentication: 'falsch',
      keyPair: (
        fromHex('b8 fa bd 62 66 5d 8b 9e 8a 9d 8b 1f 4b ca 42 c8 c2 78 9a 61 10 f5 0e 9d d7 85 b3 ed e8 83 f3 78'),
        fromHex('0a a2 27 b4 fd 7a 32 31 9b a9 96 0a c0 36 ce 0e 5c 45 07 b5 ae 55 16 1f 10 78 b1 dc fb 3c b6 31'),
      ),
    );
    final done = session.handshake((_) {});
    session.handle(
      Uint8List.fromList([
        ...fromHex('06 10 09 52 00 38 00 01'),
        ...fromHex('bd f0 99 90 99 23 14 3e f0 a5 de 0b 3b e3 68 7b c5 bd 3c f5 f9 e6 f9 01 69 9c d8 70 ec 1f f8 24'),
        ...fromHex('a9 22 50 5a aa 43 61 63 57 0b d5 49 4c 2d f2 a3'),
      ]),
    );
    await expectLater(done, throwsA(isA<IpSecureException>().having((e) => e.reason, 'reason', 'device')));
  });

  test('IP Secure: gateway key with an all-zero secret is rejected', () async {
    final session = IpSecureSession(userId: 1, userPassword: 'secret');
    final done = session.handshake((_) {});
    // Public key 0 is a low-order point: the shared secret would be all zeros.
    session.handle(Uint8List.fromList([...fromHex('06 10 09 52 00 38 00 01'), ...List.filled(32 + 16, 0)]));
    await expectLater(done, throwsA(isA<IpSecureException>().having((e) => e.reason, 'reason', 'key')));
    expect(session.established, isFalse);
  });
}
