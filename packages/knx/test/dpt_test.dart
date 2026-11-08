import 'package:knx/knx.dart';
import 'package:test/test.dart';

void main() {
  test('parse and show DPT', () {
    expect(Dpt.tryParse('DPST-9-1'), const Dpt(9, 1));
    expect(Dpt.tryParse('DPT-1'), const Dpt(1));
    expect(Dpt.tryParse('9.001'), const Dpt(9, 1));
    expect(Dpt.tryParse('x'), isNull);
    expect(const Dpt(9, 1).toString(), '9.001');
    expect(const Dpt(9).toString(), '9.xxx');
  });

  group('encoding', () {
    test('text (16): also empty, at most 14 characters', () {
      expect(encodeForDpt(const Dpt(16, 0), '')!.data, List.filled(14, 0));
      expect(encodeForDpt(const Dpt(16, 0), 'Hallo')!.data.take(5), 'Hallo'.codeUnits);
      expect(encodeForDpt(const Dpt(16, 0), 'x' * 15), isNull);
    });

    test('time, date, colour, HVAC', () {
      expect(encodeForDpt(const Dpt(10, 1), '14:47')!.data, [14, 47, 0]);
      expect(encodeForDpt(const Dpt(10, 1), '25:00'), isNull);
      expect(encodeForDpt(const Dpt(11, 1), '31.12.2024')!.data, [31, 12, 24]);
      expect(encodeForDpt(const Dpt(11, 1), '2024-12-31')!.data, [31, 12, 24]);
      expect(encodeForDpt(const Dpt(232, 600), '#FF8000')!.data, [255, 128, 0]);
      expect(encodeForDpt(const Dpt(232, 600), '1, 2, 3')!.data, [1, 2, 3]);
      expect(encodeForDpt(const Dpt(20, 102), '3')!.data, [3]);
    });

    test('integers 8, 12, 13', () {
      expect(encodeForDpt(const Dpt(8, 1), '-2')!.data, [0xFF, 0xFE]);
      expect(encodeForDpt(const Dpt(12, 1), '65536')!.data, [0, 1, 0, 0]);
      expect(encodeForDpt(const Dpt(13, 1), '-1')!.data, [0xFF, 0xFF, 0xFF, 0xFF]);
      expect(canEncodeDpt(const Dpt(19, 1)), isFalse);
    });

    test('limits per family', () {
      expect(encodeForDpt(const Dpt(1, 1), '1'), (small: 1, data: const <int>[]));
      expect(encodeForDpt(const Dpt(1, 1), '2'), isNull);
      expect(encodeForDpt(const Dpt(5, 1), '100')!.data, [255]);
      expect(encodeForDpt(const Dpt(5, 1), '101'), isNull);
      expect(encodeForDpt(const Dpt(5, 3), '360')!.data, [255]);
      expect(encodeForDpt(const Dpt(5, 10), '255')!.data, [255]);
      expect(encodeForDpt(const Dpt(5, 10), '256'), isNull);
      expect(encodeForDpt(const Dpt(6, 10), '-128')!.data, [0x80]);
      expect(encodeForDpt(const Dpt(6, 10), '128'), isNull);
      expect(encodeForDpt(const Dpt(7, 1), '65535')!.data, [0xFF, 0xFF]);
      expect(encodeForDpt(const Dpt(7, 1), '65536'), isNull);
      expect(encodeForDpt(const Dpt(8, 1), '-32768')!.data, [0x80, 0x00]);
      expect(encodeForDpt(const Dpt(8, 1), '32768'), isNull);
      expect(encodeForDpt(const Dpt(9, 1), '21,5 °C')!.data, encodeDpt9(21.5));
      expect(encodeForDpt(const Dpt(9, 1), '700000'), isNull);
      expect(encodeForDpt(const Dpt(12, 1), '4294967295')!.data, [0xFF, 0xFF, 0xFF, 0xFF]);
      expect(encodeForDpt(const Dpt(13, 1), '-2147483648')!.data, [0x80, 0, 0, 0]);
      expect(encodeForDpt(const Dpt(14, 56), '1')!.data, [0x3F, 0x80, 0, 0]);
      expect(encodeForDpt(const Dpt(17, 1), '64')!.data, [63]);
      expect(encodeForDpt(const Dpt(17, 1), '0'), isNull);
      expect(encodeForDpt(const Dpt(11, 1), '01.01.1989'), isNull);
      expect(encodeForDpt(const Dpt(19, 1), '1'), isNull);
    });
  });

  test('DPT 9: limits, sign, round trip', () {
    expect(decodeDpt9([0x0C, 0x1A]), closeTo(21.0, 0.001));
    expect(decodeDpt9([0x00, 0x00]), 0);
    expect(decodeDpt9([0x87, 0x9C]), closeTo(-1.0, 0.001));
    expect(decodeDpt9([0x7F, 0xFF]), closeTo(670760.96, 0.01));
    expect(decodeDpt9([0xF8, 0x00]), closeTo(-671088.64, 0.01));
    expect(encodeDpt9(21.0), [0x0C, 0x1A]);
    expect(encodeDpt9(-1.0), [0x87, 0x9C]);
    expect(encodeDpt9(670760.96), [0x7F, 0xFF]);
    expect(encodeDpt9(700000), isNull);
    for (final v in [-273.0, -0.5, 0.01, 19.84, 1000.0, 40000.0]) {
      expect(decodeDpt9(encodeDpt9(v)!), closeTo(v, v.abs() * 0.002 + 0.01), reason: '$v');
    }
  });

  test('numeric value by DPT or estimated', () {
    expect(dptNumericValue(null, [1], small: true), 1);
    expect(dptNumericValue(const Dpt(3, 7), [9], small: true), isNull);
    expect(dptNumericValue(const Dpt(5, 1), [255], small: false), 100);
    expect(dptNumericValue(const Dpt(6, 10), [0xFF], small: false), -1);
    expect(dptNumericValue(null, [0xFF], small: false), 255);
    expect(dptNumericValue(const Dpt(7, 1), [0xFF, 0xFF], small: false), 65535);
    expect(dptNumericValue(const Dpt(8, 1), [0xFF, 0xFE], small: false), -2);
    expect(dptNumericValue(null, [0x0C, 0x1A], small: false), closeTo(21, 0.001));
    expect(dptNumericValue(const Dpt(12, 1), [0, 1, 0, 0], small: false), 65536);
    expect(dptNumericValue(const Dpt(13, 10), [0xFF, 0xFF, 0xFF, 0xFF], small: false), -1);
    expect(dptNumericValue(const Dpt(14, 56), [0x3F, 0x80, 0, 0], small: false), 1);
    expect(dptNumericValue(const Dpt(10, 1), [1, 2, 3], small: false), isNull);
    expect(dptNumericValue(const Dpt(9, 1), [1], small: false), isNull);
    expect(dptNumericValue(null, const [], small: false), isNull);
  });

  test('units', () {
    expect(dptUnit(const Dpt(9, 1)), '°C');
    expect(dptUnit(const Dpt(14, 56)), 'W');
    expect(dptUnit(const Dpt(14, 57)), '');
    expect(dptUnit(const Dpt(13, 13)), 'kWh');
    expect(dptUnit(const Dpt(5, 1)), '%');
    expect(dptUnit(const Dpt(7, 600)), 'K');
    expect(dptUnit(const Dpt(1, 1)), '');
    expect(dptUnit(const Dpt(9)), '');
  });
}
