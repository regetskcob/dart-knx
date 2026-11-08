import 'dart:typed_data';

import 'package:knx/knx.dart';
import 'package:test/test.dart';

void main() {
  group('addresses', () {
    test('signed parts are rejected (they would wrap to another address)', () {
      expect(parseGroupAddress('1/2/3'), (1 << 11) | (2 << 8) | 3);
      expect(parseGroupAddress('1/2/-3'), isNull);
      expect(parseGroupAddress('-1/0/0'), isNull);
      expect(parseGroupAddress('+1/0/0'), isNull);
      expect(parseIndividual('1.1.-1'), isNull);
      expect(parseIndividual('1.1.10'), 0x110A);
      expect(parseIndividual(null), isNull);
    });

    test('two- and three-level, free only in free style', () {
      expect(formatGroupAddress(0x0A03), '1/2/3');
      expect(formatGroupAddress(0x0A03, GroupStyle.twoLevel), '1/515');
      expect(formatGroupAddress(0x0A03, GroupStyle.free), '2563');
      expect(parseGroupAddress('1/515'), 0x0A03);
      expect(parseGroupAddress('2563'), isNull);
      expect(parseGroupAddress('2563', GroupStyle.free), 0x0A03);
      expect(parseGroupAddress('32/0/0'), isNull);
      expect(formatIndividual(0x1105), '1.1.5');
      expect(parseIndividual('16.0.0'), isNull);
    });
  });

  test('hex: readable, compact and tolerant when parsing', () {
    expect(hex([0x0C, 0x1A]), '0C 1A');
    expect(hexOf([0x0C, 0x1A]), '0C1A');
    expect(parseHex('0c 1a'), [0x0C, 0x1A]);
    expect(parseHex('0x0C:0x1A'), [0x0C, 0x1A]);
    expect(parseHex('0C1'), isNull);
    expect(parseHex(''), isNull);
  });

  test('parses GroupValueResponse', () {
    final t = Telegram.fromCemi(
      Uint8List.fromList([0x29, 0x00, 0xBC, 0xE0, 0x11, 0x05, 0x0A, 0x03, 0x03, 0x00, 0x40, 0x0C, 0x1A]),
    )!;
    expect(t.type, TelegramType.response);
    expect(t.sourceText, '1.1.5');
    expect(t.data, [0x0C, 0x1A]);
    expect(t.isSmall, isFalse);
  });

  test('ignores individually addressed frames', () {
    final t = Telegram.fromCemi(Uint8List.fromList([0x29, 0x00, 0xBC, 0x60, 0x11, 0x05, 0x11, 0x06, 0x01, 0x00, 0x81]));
    expect(t, isNull);
  });

  test('reads priority, repetition, hop count and confirmation', () {
    // 0x9C: standard, repeated (bit 5 = 0), priority low; 0xD0: group, hop 5
    final rep = Telegram.fromCemi(
      Uint8List.fromList([0x29, 0x00, 0x9C, 0xD0, 0x11, 0x05, 0x0A, 0x03, 0x01, 0x00, 0x81]),
    )!;
    expect(rep.repeated, isTrue);
    expect(rep.hopCount, 5);
    expect(rep.unusualHop, isTrue);
    expect(rep.priority, TelegramPriority.low);

    final normal = Telegram.fromCemi(
      Uint8List.fromList([0x29, 0x00, 0xBC, 0xE0, 0x11, 0x05, 0x0A, 0x03, 0x01, 0x00, 0x81]),
    )!;
    expect(normal.repeated, isFalse);
    expect(normal.hopCount, 6);

    // L_Data.con with confirmation error (bit 0)
    final con = Telegram.fromCemi(
      Uint8List.fromList([0x2E, 0x00, 0xBD, 0xE0, 0x11, 0x26, 0x0A, 0x03, 0x01, 0x00, 0x81]),
    )!;
    expect(con.outgoing, isTrue);
    expect(con.confirmError, isTrue);
    expect(con.repeated, isFalse);
  });

  test('JSON line: compact and lossless round trip', () {
    final raw = Uint8List.fromList([0x2E, 0x00, 0xB1, 0xD0, 0x11, 0x05, 0x0A, 0x03, 0x03, 0x00, 0x80, 0x0C, 0x1A]);
    final t = Telegram.fromCemi(raw, time: DateTime.utc(2026, 11, 3))!;
    final json = t.toJson();
    expect(json, {
      't': DateTime.utc(2026, 11, 3).microsecondsSinceEpoch,
      's': 0x1105,
      'd': 0x0A03,
      'y': 2,
      'x': '0C1A',
      'o': true,
      'p': 0,
      'h': 5,
      'ce': true,
      'r': '2E00B1D011050A030300800C1A',
    });
    final back = Telegram.fromJson(json);
    expect(back.toJson(), json);
    expect(back.raw, raw);
  });

  test('builds group telegrams and L_Data.req', () {
    expect(buildGroupRequest(0x0A03, TelegramType.read), [0x11, 0, 0xBC, 0xE0, 0, 0, 0x0A, 0x03, 1, 0, 0x00]);
    expect(buildGroupRequest(0x0A03, TelegramType.write, small: 1), [
      0x11,
      0,
      0xBC,
      0xE0,
      0,
      0,
      0x0A,
      0x03,
      1,
      0,
      0x81,
    ]);
    expect(buildGroupRequest(0x0A03, TelegramType.response, data: [0x0C, 0x1A]), [
      0x11, 0, 0xBC, 0xE0, 0, 0, 0x0A, 0x03, 3, 0, 0x40, 0x0C, 0x1A, //
    ]);
    final req = buildLData(destination: 0x1105, group: false, tpdu: [0x80], system: true);
    expect(req, [0x11, 0, 0xB0, 0x60, 0, 0, 0x11, 0x05, 0, 0x80]);
    expect(isLDataRequest(req), isTrue);
    expect(isLDataRequest(req.sublist(0, 9)), isFalse);
    expect(isLDataRequest([0x11, 0xFF, 0, 0]), isFalse);
  });

  test('cEMI frames also for individual addresses and control TPDUs', () {
    // L_Data.ind 1.1.5 → 1.1.6, A_PropertyValue_Response (0x3D6)
    final f = CemiFrame.parse(
      Uint8List.fromList([0x29, 0x00, 0xB0, 0x60, 0x11, 0x05, 0x11, 0x06, 0x02, 0x43, 0xD6, 0x01]),
    )!;
    expect(f.groupAddressed, isFalse);
    expect(f.apci, 0x3D6);
    expect(f.payload, [0x01]);
    // T_Disconnect
    final c = CemiFrame.parse(Uint8List.fromList([0x29, 0x00, 0xB0, 0x60, 0x11, 0x05, 0x11, 0x06, 0x00, 0x81]))!;
    expect(c.isControl, isTrue);
    expect(c.apci, isNull);
    expect(CemiFrame.parse(Uint8List.fromList([0x11, 0x00])), isNull);
  });

  test('KNXnet/IP frames', () {
    final f = knxFrame(KnxIpService.tunnelAck, [4, 1, 0, 0]);
    expect(f, [0x06, 0x10, 0x04, 0x21, 0x00, 0x0A, 4, 1, 0, 0]);
    expect(serviceOf(f), KnxIpService.tunnelAck);
    expect(serviceOf([0x06, 0x11, 0x04, 0x21, 0, 6]), isNull);
    expect(tunnelCri(), [4, 0x04, 0x02, 0]);
    expect(tunnelCri(address: 0x11FF), [6, 0x04, 0x02, 0, 0x11, 0xFF]);
  });
}
