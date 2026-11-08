import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Minimal KNXnet/IP gateway for tests: UDP and TCP on localhost.
class FakeGateway {
  FakeGateway._(this._udp, this._tcp) {
    _udp.listen((e) {
      if (e != RawSocketEvent.read) return;
      final dg = _udp.receive();
      if (dg == null) return;
      _handle(dg.data, (bytes) => _udp.send(bytes, dg.address, dg.port), reliable: false);
    });
    _tcp.listen((socket) {
      _tcpClients.add(socket);
      final buffer = BytesBuilder();
      socket.listen((chunk) {
        buffer.add(chunk);
        var bytes = buffer.takeBytes();
        while (bytes.length >= 6) {
          final len = (bytes[4] << 8) | bytes[5];
          if (bytes.length < len) break;
          _handle(Uint8List.fromList(bytes.sublist(0, len)), socket.add, reliable: true);
          bytes = Uint8List.sublistView(bytes, len);
        }
        buffer.add(bytes);
      }, onDone: () => _tcpClients.remove(socket));
    });
  }

  static Future<FakeGateway> start() async {
    // UDP and TCP on the same port number; if TCP already uses it
    // (parallel tests), try again with a new port.
    for (var attempt = 0; ; attempt++) {
      final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      try {
        final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, udp.port);
        return FakeGateway._(udp, tcp);
      } on SocketException {
        udp.close();
        if (attempt == 20) rethrow;
      }
    }
  }

  final RawDatagramSocket _udp;
  final ServerSocket _tcp;
  final _tcpClients = <Socket>[];
  int get port => _udp.port;

  int tunnelAddress = 0x1126;

  /// Tunnel addresses handed out on request (extended CRI).
  final freeAddresses = <int>{0x11F0};

  /// No free tunnel.
  bool full = false;

  /// Supports tunnelling v1 only (rejects the extended CRI).
  bool v1Only = false;

  int connects = 0;
  final requests = <Uint8List>[];
  final connectCris = <List<int>>[];

  void Function(List<int>)? _client;
  bool _reliable = false;
  int _seq = 0;

  Future<void> close() async {
    _udp.close();
    for (final c in List.of(_tcpClients)) {
      c.destroy();
    }
    await _tcp.close();
  }

  void _send(int service, List<int> body) {
    final len = 6 + body.length;
    _client?.call([0x06, 0x10, service >> 8, service & 0xFF, len >> 8, len & 0xFF, ...body]);
  }

  /// Sends arbitrary bytes to the client (broken packets, fuzzing).
  void raw(List<int> bytes) => _client?.call(bytes);

  /// Sends a frame from the bus to the client.
  void indicate(List<int> cemi) => _send(0x0420, _last = [0x04, 0x01, _seq++ & 0xFF, 0x00, ...cemi]);

  /// Repeats the last frame with the same sequence number (lost acknowledgement).
  void repeatLast() => _send(0x0420, _last!);
  List<int>? _last;

  /// Disconnects from the gateway side.
  void kick() => _send(0x0209, [0x01, 0x00, 0x08, 0x01, 127, 0, 0, 1, port >> 8, port & 0xFF]);

  void _handle(Uint8List p, void Function(List<int>) reply, {required bool reliable}) {
    _client = reply;
    _reliable = reliable;
    final service = (p[2] << 8) | p[3];
    switch (service) {
      case 0x0205:
        connects++;
        final cri = p.sublist(22);
        connectCris.add(cri);
        if (full) return _send(0x0206, [0x00, 0x24]);
        var address = tunnelAddress;
        if (cri[0] == 6) {
          if (v1Only) return _send(0x0206, [0x00, 0x23]);
          final wanted = (cri[4] << 8) | cri[5];
          if (!freeAddresses.contains(wanted)) return _send(0x0206, [0x00, 0x2E]);
          address = wanted;
        }
        _seq = 0;
        _send(0x0206, [
          0x01,
          0x00,
          0x08,
          0x01,
          127,
          0,
          0,
          1,
          port >> 8,
          port & 0xFF,
          0x04,
          0x04,
          address >> 8,
          address & 0xFF,
        ]);
      case 0x0203:
        _send(0x0204, [0x36, 0x01, 0x02, 0x00, 0x11, 0xFA, ...List.filled(48, 0)]);
      case 0x0207:
        _send(0x0208, [0x01, 0x00]);
      case 0x0209:
        _send(0x020A, [0x01, 0x00]);
      case 0x0420:
        if (!_reliable) _send(0x0421, [0x04, 0x01, p[8], 0x00]);
        final c = Uint8List.fromList(p.sublist(10));
        requests.add(c);
        // L_Data.con back, like a real gateway.
        indicate([0x2E, 0x00, c[2], c[3], tunnelAddress >> 8, tunnelAddress & 0xFF, ...c.sublist(6)]);
    }
  }
}

/// Waits until [condition] holds (at most [timeout]).
Future<void> until(bool Function() condition, {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
