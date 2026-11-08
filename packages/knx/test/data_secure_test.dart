import 'dart:convert';
import 'dart:typed_data';

import 'package:knx/knx.dart';
import 'package:knx/secure.dart';
import 'package:test/test.dart';

/// Examples from the xknx tests (MIT), keys from their `SecureTest.knxkeys`.
void main() {
  // Group key of 0/4/0 (1024) and last sequence numbers of senders 4.0.9 and 5.0.1 from
  // SecureTest.knxkeys.
  final groupKey = fromHex('dfdf23a59fbb40404091d1c162087e8b');
  DataSecure secureTest({int? sequenceStart}) => DataSecure(
    groupKeys: {1024: groupKey},
    sequenceNumbers: {0x4009: 155806854915, 0x5001: 0},
    sequenceStart: sequenceStart,
  );

  test('decrypts a group response (A+C)', () {
    final ds = secureTest();
    final cemi = fromHex('29003ce0400904001103f110002446cfef4ac085e7092ab062b44d');
    expect(DataSecure.isSecure(cemi), isTrue);
    final (result, plain) = ds.receive(cemi);
    expect(result, SecureResult.decrypted);
    final t = Telegram.fromCemi(plain)!;
    expect(t.type, TelegramType.response);
    expect(t.source, 0x4009);
    expect(t.destination, 0x0400);
    expect(t.data, [116, 41, 41]);
    // same sequence number again → dropped
    expect(ds.receive(cemi).$1, SecureResult.invalid);
  });

  test('unknown key and tampered MAC', () {
    final ds = secureTest();
    final noKey = fromHex('29003ce0400904011103f110002446cfef4ac085e7092ab062b44d');
    expect(ds.receive(noKey).$1, SecureResult.noKey);
    final tampered = fromHex('29003ce0400904001103f110002446cfef4ac085e7092ab062b44e');
    expect(ds.receive(tampered).$1, SecureResult.invalid);
  });

  test('encrypts own read and write like xknx', () {
    var ds = secureTest(sequenceStart: 160170101607);
    final read = buildGroupRequest(0x0400, TelegramType.read);
    expect(ds.send(read, source: 0x5001), fromHex('1100bce0500104000e03f11000254ae1cb67cd184afe5744'));

    ds = secureTest(sequenceStart: 160170101607);
    final write = buildGroupRequest(0x0400, TelegramType.write, data: [255, 0, 5]);
    final secured = ds.send(write, source: 0x5001);
    expect(secured, fromHex('11003ce0500104001103f11000254ae1cb67cd98e577b519be47bb'));

    // And back: the own telegram decrypts again.
    final receiver = secureTest();
    final incoming = Uint8List.fromList(secured)..[0] = 0x29;
    final (result, plain) = receiver.receive(incoming);
    expect(result, SecureResult.decrypted);
    expect(Telegram.fromCemi(plain)!.data, [255, 0, 5]);
  });

  test('plain telegrams stay unchanged', () {
    final ds = secureTest();
    final plain = fromHex('2900bce011050a03010081');
    expect(ds.receive(plain).$1, SecureResult.plain);
    final req = buildGroupRequest(0x0A03, TelegramType.write, small: 1);
    expect(ds.send(req, source: 0x5001), req);
  });

  test('keys from a JSON map (as Busclear stores them)', () {
    final ds = DataSecure.fromJson({
      'groupKeys': {'1024': base64.encode(groupKey)},
      'sequence': {'${0x4009}': 155806854915},
    });
    final (_, plain) = ds.receive(fromHex('29003ce0400904001103f110002446cfef4ac085e7092ab062b44d'));
    final line = Telegram.fromCemi(plain, time: DateTime(2026))!.toJson();
    expect(line['y'], 1); // response
    expect(line['x'], '742929');
  });
}
