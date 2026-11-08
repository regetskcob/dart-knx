import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'ft12.dart';
import 'ft12_link.dart' show BusmonCounters;

import 'package:knx/knx.dart' show hexOf;

/// Serial line, FT1.2 session and a step-by-step check for a Weinzierl KNX BAOS
/// 838 kBerry (on a Raspberry Pi on GPIO 14/15, `/dev/ttyAMA0`) or a similar
/// FT1.2 module with cEMI. [KberryProbe] only measures: does the module respond,
/// which operating modes does it support, do telegrams arrive, does the bus
/// monitor deliver acknowledgements? [Ft12CemiLink] is the bus connection for
/// continuous use, on the same [Ft12Session].

/// Serial line to the module.
abstract class SerialLine {
  Future<void> write(List<int> bytes);

  /// Reads whatever has arrived; waits only briefly (about 100 ms) and then
  /// may return nothing.
  Future<Uint8List> read();

  Future<void> close();
}

/// Linux device such as `/dev/ttyAMA0`, configured via `stty` (8E1, raw, reads
/// with a 100 ms timeout so that every measurement can be aborted).
class TtyLine implements SerialLine {
  TtyLine._(this._input, this._output);

  static Future<TtyLine> open(String device, int baud) async {
    // Not FileSystemEntity.type: it reports character devices as notFound.
    if (!await File(device).exists()) {
      throw FileSystemException('Device missing (on a Raspberry Pi: UART overlay in config.txt, then reboot)', device);
    }
    final result = await Process.run('stty', [
      '-F', device, 'raw', '$baud', 'cs8', 'parenb', '-parodd', '-cstopb', '-crtscts', 'clocal', 'cread', //
      '-echo', 'min', '0', 'time', '1',
    ]);
    if (result.exitCode != 0) throw FileSystemException('stty: ${'${result.stderr}'.trim()}', device);
    final input = await File(device).open();
    try {
      // Not writeOnlyAppend: it seeks to the end, which a tty cannot do (ESPIPE).
      return TtyLine._(input, await File(device).open(mode: FileMode.writeOnly));
    } on Object {
      await input.close();
      rethrow;
    }
  }

  final RandomAccessFile _input;
  final RandomAccessFile _output;

  @override
  Future<void> write(List<int> bytes) => _output.writeFrom(bytes);

  @override
  Future<Uint8List> read() => _input.read(256);

  @override
  Future<void> close() async {
    await _input.close();
    await _output.close();
  }
}

/// Result of a check step.
enum ProbeStatus { ok, warn, fail, skip }

/// Check steps in order (identifiers in the report).
const kberrySteps = ['reset', 'identify', 'serial', 'modes', 'commMode', 'linkLayer', 'busmonitor', 'restore'];

/// Runs the check over a [SerialLine] that [open] opens per baud rate.
class KberryProbe {
  KberryProbe(this.open, {this.bauds = const [19200, 115200], this.onStep});

  final Future<SerialLine> Function(int baud) open;
  final List<int> bauds;

  /// Reports the step currently running (for the progress display).
  final void Function(String step)? onStep;

  /// Checks the module; [listen] is the duration per listening step (link layer
  /// and bus monitor). At the end the module is back in BAOS mode.
  Future<Map<String, Object?>> run({Duration listen = const Duration(seconds: 10)}) async {
    final steps = <Map<String, Object?>>[];
    void add(String id, ProbeStatus status, [Map<String, Object?> data = const {}]) =>
        steps.add({'id': id, 'status': status.name, ...data});
    void skipRest() {
      for (final id in kberrySteps.skip(steps.length)) {
        add(id, ProbeStatus.skip);
      }
    }

    final report = <String, Object?>{'started': DateTime.now().toIso8601String(), 'steps': steps};
    onStep?.call('reset');
    Ft12Session? session;
    final tried = <Map<String, Object?>>[];
    for (final baud in bauds) {
      final SerialLine line;
      try {
        line = await open(baud);
      } on Object catch (e) {
        add('reset', ProbeStatus.fail, {'error': '$e'});
        skipRest();
        return report;
      }
      final candidate = Ft12Session(line);
      bool ok;
      try {
        ok = await candidate.reset();
      } on Object catch (e) {
        // Read error (e.g. module unplugged): do not leave the line open.
        await line.close();
        add('reset', ProbeStatus.fail, {'tried': tried, 'error': '$e'});
        skipRest();
        return report;
      }
      tried.add({'baud': baud, 'ok': ok, 'skipped': candidate.decoder.skipped});
      if (ok) {
        session = candidate;
        report['baud'] = baud;
        break;
      }
      await line.close();
    }
    if (session == null) {
      add('reset', ProbeStatus.fail, {'tried': tried});
      skipRest();
      return report;
    }
    final s = session;
    try {
      add('reset', ProbeStatus.ok, {'baud': report['baud'], 'tried': tried});

      onStep?.call('identify');
      final identify = await s.ask(const [0xA7], 0xA8);
      add('identify', identify == null ? ProbeStatus.warn : ProbeStatus.ok, {
        if (identify != null) 'response': hexOf(identify),
        if (identify != null) 'length': identify.length,
      });

      onStep?.call('serial');
      final serial = await s.readProperty(0x0000, 0x0B);
      add('serial', serial == null ? ProbeStatus.warn : ProbeStatus.ok, {if (serial != null) 'serial': hexOf(serial)});

      onStep?.call('modes');
      final modes = await s.readProperty(0x0008, 0x40);
      final mask = modes == null || modes.isEmpty ? null : modes.fold<int>(0, (v, b) => (v << 8) | b);
      final canBusmon = mask != null && mask & 0x02 != 0;
      add('modes', mask == null ? ProbeStatus.warn : (canBusmon ? ProbeStatus.ok : ProbeStatus.warn), {
        if (mask != null) ...{
          'mask': mask,
          'linkLayer': mask & 0x01 != 0,
          'busmonitor': canBusmon,
          'transportLayer': mask & 0x08 != 0,
        },
      });

      onStep?.call('commMode');
      final comm = await s.readProperty(0x0008, 0x34);
      add('commMode', comm == null || comm.isEmpty ? ProbeStatus.warn : ProbeStatus.ok, {
        if (comm != null && comm.isNotEmpty) 'mode': comm.first,
      });

      onStep?.call('linkLayer');
      if (await s.writeCommMode(0x00)) {
        final frames = await s.collect(0x29, listen);
        add('linkLayer', frames.isEmpty ? ProbeStatus.warn : ProbeStatus.ok, {
          'seconds': listen.inSeconds,
          'frames': frames.length,
          'samples': [for (final f in frames.take(8)) hexOf(f)],
        });
      } else {
        add('linkLayer', ProbeStatus.fail, {'error': 'M_PropWrite PID 52 = 0x00 rejected'});
      }

      onStep?.call('busmonitor');
      if (await s.writeCommMode(0x01)) {
        final frames = await s.collect(0x2B, listen);
        final counts = classifyBusmon(frames);
        add('busmonitor', (counts['ack']! as int) > 0 ? ProbeStatus.ok : ProbeStatus.warn, {
          'seconds': listen.inSeconds,
          ...counts,
          'samples': [for (final f in frames.take(8)) hexOf(f)],
        });
      } else {
        add('busmonitor', ProbeStatus.fail, {'error': 'M_PropWrite PID 52 = 0x01 rejected'});
      }

      onStep?.call('restore');
      final restored = await s.writeCommMode(0xF0);
      add('restore', restored ? ProbeStatus.ok : ProbeStatus.warn);
      report['skippedBytes'] = s.decoder.skipped;
    } on Object catch (e) {
      add(kberrySteps[steps.length], ProbeStatus.fail, {'error': '$e'});
      skipRest();
      // Do not leave the module in link layer or bus monitor mode.
      try {
        await s.writeCommMode(0xF0);
      } on Object {
        // Best effort; the line is closed below anyway.
      }
    } finally {
      await s.line.close();
    }
    return report;
  }
}

/// Counts raw bus monitor frames (cEMI L_Busmon.ind, 0x2B): acknowledgements in
/// TP encoding (ACK 0xCC, NAK 0x0C, BUSY 0xC0, NAK+BUSY 0x00), data telegrams,
/// repetitions (repeat bit in the control field cleared), frames with error
/// bits in the bus monitor status (additional info 0x03) and with a timestamp.
/// [BusmonCounters] adds what the module saw but did not pass on: `orphanAcks`
/// (acknowledgement without a data frame before it) and `seqGaps` (frames
/// skipped by the sequence number).
Map<String, Object?> classifyBusmon(List<Uint8List> frames) {
  final gaps = BusmonCounters();
  for (final f in frames) {
    gaps.add(f);
  }
  var ack = 0, nak = 0, busy = 0, nakBusy = 0, data = 0, repeated = 0, other = 0, errors = 0, timestamps = 0;
  for (final f in frames) {
    if (f.length < 2) {
      other++;
      continue;
    }
    final addIl = f[1];
    var status = 0;
    var stamped = false;
    for (var i = 2; i + 1 < 2 + addIl && i + 1 < f.length; i += 2 + f[i + 1]) {
      final type = f[i], len = f[i + 1];
      if (type == 0x03 && len >= 1 && i + 2 < f.length) status = f[i + 2];
      if (type == 0x04 || type == 0x06) stamped = true;
    }
    if (status & 0xF8 != 0) errors++;
    if (stamped) timestamps++;
    if (2 + addIl >= f.length) {
      other++;
      continue;
    }
    final raw = f.sublist(2 + addIl);
    if (raw.length == 1) {
      switch (raw.first) {
        case 0xCC:
          ack++;
        case 0x0C:
          nak++;
        case 0xC0:
          busy++;
        case 0x00:
          nakBusy++;
        default:
          other++;
      }
    } else {
      data++;
      if (raw.first & 0x20 == 0) repeated++;
    }
  }
  return {
    'frames': frames.length,
    'ack': ack,
    'nak': nak,
    'busy': busy,
    'nakBusy': nakBusy,
    'data': data,
    'repeated': repeated,
    'other': other,
    'errors': errors,
    'timestamps': timestamps,
    'orphanAcks': gaps.orphanAcks,
    'seqGaps': gaps.seqGaps,
  };
}

/// FT1.2 session with the module: reset, frames with acknowledgement and
/// frame count bit, property services. Used for the check and for continuous
/// mode (`Ft12CemiLink`); only reads when someone is waiting.
class Ft12Session {
  Ft12Session(this.line);

  final SerialLine line;
  final decoder = Ft12Decoder();
  final _events = <Ft12Event>[];

  /// Frame count bit of the next frame; set after a reset.
  bool _fcb = true;

  /// Control byte and content of the last data frame from the module: if our
  /// acknowledgement did not arrive, it repeats the frame with the same bit.
  int? _lastControl;
  Uint8List? _lastData;

  Future<void> _fill() async {
    final bytes = await line.read();
    if (bytes.isEmpty) return;
    for (final event in decoder.add(bytes)) {
      // Every data frame from the module requires an acknowledgement.
      if (event is Ft12DataEvent) {
        await line.write(const [ft12Ack]);
        if (event.control == _lastControl && _sameBytes(event.data, _lastData)) continue;
        _lastControl = event.control;
        _lastData = event.data;
      }
      _events.add(event);
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Reads once (at most about 100 ms) and returns all events that nobody has
  /// picked up yet.
  Future<List<Ft12Event>> poll() async {
    await _fill();
    final events = List.of(_events);
    _events.clear();
    return events;
  }

  Future<Ft12Event?> _waitFor(bool Function(Ft12Event) test, Duration timeout) async {
    final watch = Stopwatch()..start();
    while (true) {
      final i = _events.indexWhere(test);
      if (i >= 0) return _events.removeAt(i);
      if (watch.elapsed >= timeout) return null;
      await _fill();
    }
  }

  Future<bool> reset() async {
    _events.clear();
    await line.write(ft12Reset);
    final ok = await _waitFor((e) => e is Ft12AckEvent, const Duration(milliseconds: 600)) != null;
    _fcb = true;
    _lastControl = null;
    return ok;
  }

  /// Sends a data frame, waits for the acknowledgement, retries once.
  Future<bool> send(List<int> data) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      await line.write(ft12Frame(data, fcb: _fcb));
      if (await _waitFor((e) => e is Ft12AckEvent, const Duration(milliseconds: 500)) != null) {
        _fcb = !_fcb;
        return true;
      }
    }
    return false;
  }

  /// Sends [request] and waits for the response with message code [code].
  Future<Uint8List?> ask(List<int> request, int code) async {
    if (!await send(request)) return null;
    final event = await _waitFor(
      (e) => e is Ft12DataEvent && e.data.isNotEmpty && e.data.first == code,
      const Duration(milliseconds: 1500),
    );
    return (event as Ft12DataEvent?)?.data;
  }

  /// M_PropRead.req (0xFC) for object [objectType], instance 1, one element from
  /// index 1; returns the value or `null` (no response or error).
  Future<Uint8List?> readProperty(int objectType, int pid) async {
    final con = await ask([0xFC, objectType >> 8, objectType & 0xFF, 0x01, pid, 0x10, 0x01], 0xFB);
    // A count of 0 in the confirmation means error; an error code follows.
    if (con == null || con.length < 7 || con[5] >> 4 == 0) return null;
    return Uint8List.sublistView(con, 7);
  }

  /// M_PropWrite.req (0xF6) like [readProperty]; `true` if the module accepted
  /// the value.
  Future<bool> writeProperty(int objectType, int pid, List<int> value) async {
    final con = await ask([0xF6, objectType >> 8, objectType & 0xFF, 0x01, pid, 0x10, 0x01, ...value], 0xF5);
    return con != null && con.length >= 7 && con[5] >> 4 != 0;
  }

  /// PID 52 (communication mode) in the cEMI server object: 0x00 link layer,
  /// 0x01 bus monitor, 0xF0 back to BAOS mode.
  Future<bool> writeCommMode(int mode) => writeProperty(0x0008, 0x34, [mode]);

  /// Collects data frames with message code [code] for [duration], including
  /// those that arrived together with the confirmation of the mode switch.
  Future<List<Uint8List>> collect(int code, Duration duration) async {
    final frames = <Uint8List>[];
    final watch = Stopwatch()..start();
    while (watch.elapsed < duration) {
      for (final event in _events) {
        if (event is Ft12DataEvent && event.data.isNotEmpty && event.data.first == code) frames.add(event.data);
      }
      _events.clear();
      await _fill();
    }
    for (final event in _events) {
      if (event is Ft12DataEvent && event.data.isNotEmpty && event.data.first == code) frames.add(event.data);
    }
    _events.clear();
    return frames;
  }
}
