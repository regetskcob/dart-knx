import 'dart:typed_data';

/// FT1.2 frames (IEC 60870-5-1/-2) between the host and a Weinzierl BAOS module
/// such as the kBerry (KNX BAOS Starter Kit User's Guide, ch. 5.4).
///
/// - Reset: `10 40 40 16`, the module acknowledges with [ft12Ack].
/// - Data: `68 L L 68 C <data> CS 16`, L = length of C + data, CS = sum
///   of C + data. C from the host `0x73`/`0x53` (the frame count bit toggles with
///   each new frame and is set first after a reset), from the module `0xF3`/`0xD3`.
/// - Every data frame is acknowledged with the single character [ft12Ack].
const ft12Ack = 0xE5;
const ft12Reset = [0x10, 0x40, 0x40, 0x16];

/// Data frame from the host with the frame count bit [fcb].
Uint8List ft12Frame(List<int> data, {required bool fcb}) {
  final control = fcb ? 0x73 : 0x53;
  var sum = control;
  for (final b in data) {
    sum += b;
  }
  return Uint8List.fromList([0x68, data.length + 1, data.length + 1, 0x68, control, ...data, sum & 0xFF, 0x16]);
}

sealed class Ft12Event {
  const Ft12Event();
}

/// Single-character acknowledgement.
final class Ft12AckEvent extends Ft12Event {
  const Ft12AckEvent();
}

/// Fixed-length frame (e.g. reset), [control] = control byte.
final class Ft12FixedEvent extends Ft12Event {
  const Ft12FixedEvent(this.control);
  final int control;
}

/// Data frame; [data] is the content without the control byte (cEMI or BAOS).
final class Ft12DataEvent extends Ft12Event {
  const Ft12DataEvent(this.control, this.data);
  final int control;
  final Uint8List data;
}

/// Splits the byte stream from the module into frames. Unknown bytes and frames
/// with a wrong checksum are skipped and counted in [skipped].
class Ft12Decoder {
  final _buffer = <int>[];
  int skipped = 0;

  List<Ft12Event> add(List<int> bytes) {
    _buffer.addAll(bytes);
    final events = <Ft12Event>[];
    while (_buffer.isNotEmpty) {
      final first = _buffer.first;
      if (first == ft12Ack) {
        _buffer.removeAt(0);
        events.add(const Ft12AckEvent());
      } else if (first == 0x10) {
        if (_buffer.length < 4) break;
        if (_buffer[1] == _buffer[2] && _buffer[3] == 0x16) {
          events.add(Ft12FixedEvent(_buffer[1]));
          _buffer.removeRange(0, 4);
        } else {
          _skip();
        }
      } else if (first == 0x68) {
        if (_buffer.length < 4) break;
        final length = _buffer[1];
        if (length == 0 || _buffer[2] != length || _buffer[3] != 0x68) {
          _skip();
          continue;
        }
        final total = length + 6;
        if (_buffer.length < total) break;
        var sum = 0;
        for (var i = 4; i < 4 + length; i++) {
          sum += _buffer[i];
        }
        if ((sum & 0xFF) == _buffer[4 + length] && _buffer[total - 1] == 0x16) {
          events.add(Ft12DataEvent(_buffer[4], Uint8List.fromList(_buffer.sublist(5, 4 + length))));
          _buffer.removeRange(0, total);
        } else {
          _skip();
        }
      } else {
        _skip();
      }
    }
    return events;
  }

  void _skip() {
    _buffer.removeAt(0);
    skipped++;
  }
}
