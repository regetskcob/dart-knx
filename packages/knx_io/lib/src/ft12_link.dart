import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'ft12.dart';
import 'kberry.dart';

import 'package:knx/knx.dart' show formatIndividual;

import 'link.dart';

/// Bus connection over a serial FT1.2 module with cEMI (e.g. a Weinzierl kBerry
/// on `/dev/ttyAMA0`), without a KNX/IP gateway.
///
/// On connect, switches the module via PID 52 into link layer mode (sending
/// possible, `L_Data.ind`/`.con`) or into bus monitor mode (listen only, raw
/// TP frames including acknowledgements as `L_Busmon.ind` 0x2B), and back to
/// BAOS mode on disconnect.
///
/// A single reader: the loop in [_pump] fetches frames and runs jobs (sending,
/// keep-alive) one after another in between.
class Ft12CemiLink implements BusLink {
  Ft12CemiLink({
    required this.open,
    this.device = '/dev/ttyAMA0',
    this.busmonitor = false,
    this.requestedAddress,
    this.bauds = const [19200, 115200],
    this.keepalive = const Duration(seconds: 30),
    this.confirmTimeout = const Duration(seconds: 3),
  });

  /// Opens the line with a baud rate, e.g. [TtyLine.open].
  final Future<SerialLine> Function(int baud) open;

  /// Device for the label and messages.
  final String device;

  /// Bus monitor instead of link layer: all frames with acknowledgements, no sending.
  final bool busmonitor;

  /// Own individual address; `null` = keep the module's address.
  final int? requestedAddress;

  final List<int> bauds;

  /// Without traffic, check this often whether the module is still there.
  final Duration keepalive;

  /// How long to wait for the `L_Data.con` of a sent telegram.
  final Duration confirmTimeout;

  Ft12Session? _session;
  final _frames = StreamController<Uint8List>.broadcast();
  final _lost = Completer<String>();
  final _jobs = Queue<Future<void> Function()>();
  final _confirms = Queue<(Uint8List, Completer<void>)>();
  Future<void>? _loop;
  Future<void>? _shutdown;
  bool _running = false;

  /// Teardown per device: a new link waits until the old one has reset the
  /// module and closed the line.
  static final _releasing = <String, Future<void>>{};

  /// Announces another use of [device] (e.g. a [KberryProbe]) until [done]: a
  /// link only connects afterwards.
  static void occupy(String device, Future<void> done) {
    _releasing[device] = done;
    unawaited(
      done.whenComplete(() {
        if (identical(_releasing[device], done)) _releasing.remove(device);
      }),
    );
  }

  DateTime _lastHeard = DateTime.now();

  /// Baud rate at which the module responded.
  int? baud;

  @override
  int? address;

  @override
  String get label =>
      'FT1.2 ${busmonitor ? 'bus monitor' : 'link layer'}${address == null ? '' : ' ${formatIndividual(address!)}'}';

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<String> get lost => _lost.future;

  @override
  Future<void> connect() async {
    // Previous link or running check (both may finish one after another).
    for (var busy = _releasing[device]; busy != null; busy = _releasing[device]) {
      await busy;
    }
    Ft12Session? session;
    for (final b in bauds) {
      final SerialLine line;
      try {
        line = await open(b);
      } on Object catch (e) {
        throw LinkException('FT1.2: cannot open $device ($e)');
      }
      final candidate = Ft12Session(line);
      try {
        if (await candidate.reset()) {
          session = candidate;
          baud = b;
          break;
        }
      } on Object catch (e) {
        await line.close();
        throw LinkException('FT1.2: read error ($e)');
      }
      await line.close();
    }
    if (session == null) throw const LinkException('FT1.2 module does not respond (bus voltage, wiring, UART?)');
    _session = session;
    try {
      // PEI identify: with cEMI, Weinzierl modules respond with 11 bytes.
      if (await session.ask(const [0xA7], 0xA8) == null)
        throw const LinkException('FT1.2 module: no answer to identify');
      final modes = await session.readProperty(0x0008, 0x40);
      final mask = modes == null || modes.isEmpty ? null : modes.fold<int>(0, (v, b) => (v << 8) | b);
      if (mask != null && mask & (busmonitor ? 0x02 : 0x01) == 0) {
        throw LinkException('FT1.2 module has no ${busmonitor ? 'bus monitor' : 'link layer'} mode');
      }
      final wanted = requestedAddress;
      if (wanted != null && !busmonitor) await _writeAddress(session, wanted);
      address = await _readAddress(session);
      if (!await session.writeCommMode(busmonitor ? 0x01 : 0x00)) {
        throw const LinkException('FT1.2 module rejects the mode switch (PID 52)');
      }
    } on Object {
      await _restore(session);
      _session = null;
      rethrow;
    }
    _running = true;
    _lastHeard = DateTime.now();
    _loop = _pump(session);
  }

  /// Address in the device object: PID 57 area/line, PID 58 device.
  static Future<int?> _readAddress(Ft12Session s) async {
    final subnet = await s.readProperty(0x0000, 0x39);
    final device = await s.readProperty(0x0000, 0x3A);
    if (subnet == null || subnet.isEmpty || device == null || device.isEmpty) return null;
    return (subnet.first << 8) | device.first;
  }

  static Future<void> _writeAddress(Ft12Session s, int address) async {
    if (await _readAddress(s) == address) return;
    if (!await s.writeProperty(0x0000, 0x39, [address >> 8]) ||
        !await s.writeProperty(0x0000, 0x3A, [address & 0xFF])) {
      throw LinkException('FT1.2 module does not take the address ${formatIndividual(address)}');
    }
  }

  /// Back to BAOS mode and close the line (best effort).
  static Future<void> _restore(Ft12Session s) async {
    try {
      await s.writeCommMode(0xF0);
    } on Object {
      // The line is broken anyway.
    }
    try {
      await s.line.close();
    } on Object {
      // Same here.
    }
  }

  Future<void> _pump(Ft12Session s) async {
    while (_running) {
      try {
        if (_jobs.isNotEmpty) await _jobs.removeFirst()();
        if (!_running) break;
        for (final event in await s.poll()) {
          _dispatch(event);
        }
        if (_jobs.isEmpty && DateTime.now().difference(_lastHeard) >= keepalive) {
          _lastHeard = DateTime.now();
          _jobs.add(() => _checkAlive(s));
        }
      } on Object catch (e) {
        _drop('FT1.2: read error ($e)');
      }
    }
  }

  void _dispatch(Ft12Event event) {
    if (event is! Ft12DataEvent || event.data.isEmpty) return;
    _lastHeard = DateTime.now();
    final data = event.data;
    switch (data.first) {
      case 0x29 || 0x2B:
        _frames.add(data);
      case 0x2E:
        _confirm(data);
        _frames.add(data);
      case 0xF0:
        // M_Reset.ind: module restarted (ETS download, bus voltage) and is back in
        // BAOS mode – set it up again as after a tunnel loss.
        _drop('FT1.2 module restarted');
    }
  }

  /// Assigns an `L_Data.con` to the oldest open job with the same destination.
  /// A negative confirmation (confirm bit in control field 1 set: no
  /// acknowledgement on the bus after all repetitions) fails the job.
  void _confirm(Uint8List con) {
    final target = _destination(con);
    for (final entry in _confirms) {
      if (_destination(entry.$1) == target) {
        _confirms.remove(entry);
        if (entry.$2.isCompleted) return;
        if (_negative(con)) {
          entry.$2.completeError(const LinkException('Telegram not acknowledged on the bus (NCON)'));
        } else {
          entry.$2.complete();
        }
        return;
      }
    }
  }

  static bool _negative(Uint8List con) => con.length > 2 + con[1] && con[2 + con[1]] & 0x01 != 0;

  static int _destination(Uint8List c) {
    if (c.length < 2) return -1;
    final i = 2 + c[1];
    return c.length < i + 6 ? -1 : (c[i + 4] << 8) | c[i + 5];
  }

  Future<void> _checkAlive(Ft12Session s) async {
    if (!_running) return;
    final mode = await s.readProperty(0x0008, 0x34);
    if (mode == null || mode.isEmpty) return _drop('FT1.2 module stopped responding');
    if (mode.first != (busmonitor ? 0x01 : 0x00)) _drop('FT1.2 module left the operating mode');
  }

  @override
  Future<void> send(Uint8List cemi) async {
    final s = _session;
    if (s == null || !_running) throw const LinkException('Not connected');
    if (busmonitor) throw const LinkException('FT1.2 bus monitor mode cannot send');
    if (cemi.length < 10 || cemi[0] != 0x11) throw const LinkException('Invalid frame');
    final frame = Uint8List.fromList(cemi);
    final own = address;
    if (own != null) {
      // Source as with the tunnel: our own address.
      final i = 2 + frame[1];
      frame
        ..[i + 2] = own >> 8
        ..[i + 3] = own & 0xFF;
    }
    final accepted = Completer<void>();
    final confirmed = Completer<void>();
    // May fail before anyone waits (abort); so do not leave it unhandled.
    confirmed.future.ignore();
    _jobs.add(() async {
      if (!_running) return accepted.completeError(const LinkException('Not connected'));
      _confirms.add((frame, confirmed));
      if (await s.send(frame)) {
        accepted.complete();
      } else {
        _confirms.removeWhere((e) => identical(e.$2, confirmed));
        accepted.completeError(const LinkException('FT1.2 module does not acknowledge'));
        _drop('FT1.2 module does not acknowledge');
      }
    });
    await accepted.future;
    try {
      await confirmed.future.timeout(confirmTimeout);
    } on TimeoutException {
      _confirms.removeWhere((e) => identical(e.$2, confirmed));
      throw const LinkException('FT1.2 module does not confirm the telegram');
    }
  }

  void _drop(String reason) {
    if (!_lost.isCompleted) _lost.complete(reason);
    _running = false;
    for (final (_, c) in _confirms) {
      if (!c.isCompleted) c.completeError(LinkException(reason));
    }
    _confirms.clear();
    _release();
  }

  /// Lets the loop run out, rejects waiting jobs, puts the module back into
  /// BAOS mode, closes the line – once, even on abort.
  Future<void> _release() => _shutdown ??= () async {
    final done = () async {
      await _loop;
      while (_jobs.isNotEmpty) {
        // With _running == false, jobs fail immediately.
        await _jobs.removeFirst()();
      }
      final s = _session;
      _session = null;
      if (s != null) await _restore(s);
      if (!_frames.isClosed) await _frames.close();
    }();
    _releasing[device] = done;
    await done;
    if (identical(_releasing[device], done)) unawaited(_releasing.remove(device));
  }();

  @override
  Future<void> close() async {
    _drop('Disconnected');
    await _release();
  }
}

/// Converts a bus monitor frame (cEMI `L_Busmon.ind`, 0x2B) carrying a
/// standard-format data telegram into an `L_Data.ind` (0x29), as if it came
/// from a tunnel. `null` for acknowledgements, extended
/// frames, truncated frames and those with a transmission error.
Uint8List? busmonToLData(Uint8List cemi) {
  if (cemi.length < 3 || cemi[0] != 0x2B) return null;
  final infoLength = cemi[1];
  if (cemi.length < 2 + infoLength + 8) return null;
  var status = 0;
  for (var i = 2; i + 1 < 2 + infoLength; i += 2 + cemi[i + 1]) {
    if (cemi[i] == 0x03 && cemi[i + 1] >= 1 && i + 2 < 2 + infoLength) status = cemi[i + 2];
  }
  // Frame, bit, parity error, overflow, lost.
  if (status & 0xF8 != 0) return null;
  final raw = Uint8List.sublistView(cemi, 2 + infoLength);
  // Standard frame: control field 10xx xx00.
  if (raw[0] & 0xD3 != 0x90) return null;
  final length = raw[5] & 0x0F;
  final end = 6 + length + 1;
  if (raw.length < end + 1) return null;
  var xor = 0;
  for (var i = 0; i < end; i++) {
    xor ^= raw[i];
  }
  if ((~xor & 0xFF) != raw[end]) return null;
  return Uint8List.fromList([0x29, 0x00, raw[0], raw[5] & 0xF0, ...raw.sublist(1, 5), length, ...raw.sublist(6, end)]);
}

/// Counts in bus monitor mode what is only visible there:
/// acknowledgements, rejected and corrupted frames.
///
/// Two counters measure frames the module saw but did not pass on:
/// [orphanAcks] are acknowledgements without a data frame directly before them,
/// [seqGaps] are frames skipped by the sequence number in the bus monitor status
/// (bits 0–2 of additional info 0x03). Measured on a kBerry (7.11.2026, Pi 4):
/// about every second data frame is missing at 19200 and at 115200 baud, while
/// the link layer delivers all of them.
class BusmonCounters {
  int data = 0;
  int acks = 0;
  int naks = 0;
  int busy = 0;
  int damaged = 0;
  int orphanAcks = 0;
  int seqGaps = 0;
  bool _dataPending = false;
  int? _lastSeq;

  /// After a new connection the module counts from the start again: neither the
  /// sequence number nor a pending data frame carry over.
  void resync() {
    _lastSeq = null;
    _dataPending = false;
  }

  int get total => data + acks + naks + busy + damaged;

  /// Records an `L_Busmon.ind` (0x2B).
  void add(Uint8List cemi) {
    if (cemi.length < 3 || cemi[0] != 0x2B) return;
    final infoLength = cemi[1];
    final start = 2 + infoLength;
    if (cemi.length <= start) {
      damaged++;
      return;
    }
    var status = 0;
    var hasStatus = false;
    for (var i = 2; i + 1 < start; i += 2 + cemi[i + 1]) {
      if (cemi[i] == 0x03 && cemi[i + 1] >= 1 && i + 2 < start) {
        status = cemi[i + 2];
        hasStatus = true;
      }
    }
    if (hasStatus) {
      final seq = status & 0x07;
      final last = _lastSeq;
      // The same number again: this interface does not number its frames.
      if (last != null && seq != last) seqGaps += (seq - last - 1) & 0x07;
      _lastSeq = seq;
    }
    if (status & 0xF8 != 0) {
      damaged++;
      _dataPending = false;
      return;
    }
    if (cemi.length == start + 1) {
      switch (cemi[start]) {
        case 0xCC:
          acks++;
          if (!_dataPending) orphanAcks++;
        case 0x0C:
          naks++;
        case 0xC0:
          busy++;
        case 0x00:
          naks++;
          busy++;
        default:
          damaged++;
      }
      _dataPending = false;
      return;
    }
    // Data frame with a matching checksum, otherwise corrupted.
    if (_checksumOk(Uint8List.sublistView(cemi, start))) {
      data++;
      _dataPending = true;
    } else {
      damaged++;
      _dataPending = false;
    }
  }

  static bool _checksumOk(Uint8List raw) {
    if (raw.length < 2) return false;
    var xor = 0;
    for (var i = 0; i < raw.length - 1; i++) {
      xor ^= raw[i];
    }
    return (~xor & 0xFF) == raw.last;
  }

  Map<String, Object?> toJson() => {
    'data': data,
    'acks': acks,
    'naks': naks,
    'busy': busy,
    'damaged': damaged,
    'orphanAcks': orphanAcks,
    'seqGaps': seqGaps,
  };
}
