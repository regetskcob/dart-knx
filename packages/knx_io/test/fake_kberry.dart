import 'dart:io';
import 'dart:typed_data';

import 'package:knx_io/knx_io.dart';

/// Simulated kBerry module behind a serial line: acknowledges reset and frames,
/// answers property requests and PEI identify, and sends prepared frames in link
/// layer or bus monitor mode.
class FakeKberry implements SerialLine {
  FakeKberry({this.baud = 19200, this.lineBaud = 19200, this.modes = 0x0003, this.rejectBusmon = false});

  final int baud;
  final int lineBaud;
  final int modes;
  final bool rejectBusmon;
  final _decoder = _HostDecoder();
  final _out = <int>[];
  int commMode = 0xF0;
  final writes = <int>[];
  int hostAcks = 0;
  bool closed = false;

  /// Stops responding (bus voltage gone, module hangs).
  bool mute = false;

  /// Individual address in the device object (PID 57/58), factory default 15.15.255.
  int address = 0xFFFF;

  /// Sent L_Data.req; each gets a positive L_Data.con.
  final requests = <List<int>>[];
  bool confirmRequests = true;

  /// Confirms with the confirm bit set (NCON): nobody acknowledged on the bus.
  bool negativeConfirm = false;

  /// Last data frame to the host, for [repeatLast].
  List<int> _lastFrame = const [];

  /// Frames sent once per mode after switching.
  final linkFrames = <List<int>>[
    [0x29, 0x00, 0xBC, 0xE0, 0x11, 0x05, 0x09, 0x01, 0x01, 0x00, 0x81],
  ];
  final busmonFrames = <List<int>>[
    [0x2B, 0x07, 0x03, 0x01, 0x00, 0x04, 0x02, 0x12, 0x34, 0xBC, 0x11, 0x05, 0x09, 0x01, 0xE1, 0x00, 0x81, 0x3A],
    [0x2B, 0x00, 0xCC],
    [0x2B, 0x00, 0x0C],
    [0x2B, 0x03, 0x03, 0x01, 0x81, 0x9C, 0x11, 0x05, 0x09, 0x01, 0xE1, 0x00, 0x81, 0x3A],
    [0x2B, 0x00, 0xCC],
  ];

  bool _fcbData = true;

  void _send(List<int> data) {
    final control = _fcbData ? 0xF3 : 0xD3;
    _fcbData = !_fcbData;
    var sum = control;
    for (final b in data) {
      sum += b;
    }
    _lastFrame = [0x68, data.length + 1, data.length + 1, 0x68, control, ...data, sum & 0xFF, 0x16];
    _out.addAll(_lastFrame);
  }

  /// Sends a data frame ([push]) like a module on its own.
  void push(List<int> data) => _send(data);

  /// Repeats the last frame with the same control byte (lost acknowledgement).
  void repeatLast() => _out.addAll(_lastFrame);

  /// Restart (ETS download, bus voltage): M_Reset.ind, back in BAOS mode.
  void restart() {
    commMode = 0xF0;
    _send(const [0xF0]);
  }

  @override
  Future<void> write(List<int> bytes) async {
    writes.addAll(bytes);
    if (lineBaud != baud || mute) return; // wrong baud rate or muted: the module understands nothing
    for (final item in _decoder.add(bytes)) {
      switch (item) {
        case 'ack':
          hostAcks++;
        case 'reset':
          _out.add(0xE5);
        case final List<int> data:
          _out.add(0xE5);
          _answer(data);
      }
    }
  }

  void _answer(List<int> data) {
    switch (data.first) {
      case 0xA7:
        _send([0xA8, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
      case 0xFC:
        final object = (data[1] << 8) | data[2];
        final pid = data[4];
        final head = data.sublist(0, 7)..[0] = 0xFB;
        if (object == 0 && pid == 0x0B) {
          _send([...head, 0x00, 0xC5, 0x00, 0x00, 0x00, 0x00]);
        } else if (object == 8 && pid == 0x40) {
          _send([...head, modes >> 8, modes & 0xFF]);
        } else if (object == 8 && pid == 0x34) {
          _send([...head, commMode]);
        } else if (object == 0 && pid == 0x39) {
          _send([...head, address >> 8]);
        } else if (object == 0 && pid == 0x3A) {
          _send([...head, address & 0xFF]);
        } else {
          _send([...head.sublist(0, 5), 0x00, 0x01, 0x07]); // count 0: error
        }
      case 0xF6 when data[1] == 0 && data[2] == 0:
        final head = data.sublist(0, 7)..[0] = 0xF5;
        if (data[4] == 0x39) address = (data[7] << 8) | (address & 0xFF);
        if (data[4] == 0x3A) address = (address & 0xFF00) | data[7];
        _send(head);
      case 0xF6:
        final value = data[7];
        final head = data.sublist(0, 7)..[0] = 0xF5;
        if (value == 0x01 && rejectBusmon) {
          _send([...head.sublist(0, 5), 0x00, 0x01, 0x06]);
          return;
        }
        commMode = value;
        _send(head);
        for (final f in value == 0x00 ? linkFrames : (value == 0x01 ? busmonFrames : const <List<int>>[])) {
          _send(f);
        }
      case 0x11 when commMode == 0x00:
        requests.add(data);
        if (confirmRequests) {
          final con = [...data]..[0] = 0x2E;
          if (negativeConfirm) con[2 + con[1]] |= 0x01;
          _send(con);
        }
    }
  }

  @override
  Future<Uint8List> read() async {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final bytes = Uint8List.fromList(_out);
    _out.clear();
    return bytes;
  }

  @override
  Future<void> close() async => closed = true;
}

/// Splits what the host sends: acknowledgement, reset or data frame.
class _HostDecoder {
  final _decoder = Ft12Decoder();

  List<Object> add(List<int> bytes) => [
    for (final e in _decoder.add(bytes))
      switch (e) {
        Ft12AckEvent() => 'ack',
        Ft12FixedEvent() => 'reset',
        Ft12DataEvent(:final data) => data.toList(),
      },
  ];
}

/// Line whose read fails at once (e.g. module unplugged).
class BrokenLine implements SerialLine {
  bool closed = false;
  @override
  Future<void> write(List<int> bytes) async {}
  @override
  Future<Uint8List> read() async => throw const FileSystemException('I/O error');
  @override
  Future<void> close() async => closed = true;
}

/// Module whose line fails once while listening in link layer mode.
class FlakyKberry extends FakeKberry {
  FlakyKberry({super.lineBaud});
  bool failed = false;
  @override
  Future<Uint8List> read() async {
    if (commMode == 0x00 && !failed) {
      failed = true;
      throw const FileSystemException('I/O error');
    }
    return super.read();
  }
}
