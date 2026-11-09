import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:knx/knx.dart';

import 'package:knx/secure.dart';

/// Error of a bus connection. [status] is the KNXnet/IP status code if the
/// gateway rejected the connection.
class LinkException implements Exception {
  const LinkException(this.message, {this.status, this._problem});
  final String message;
  final int? status;
  final String? _problem;

  /// Known reason as a stable code for your own messages: noResponse, network,
  /// noFreeTunnel, tunnelAddress, unsupported, secureAuth, secureDevice,
  /// routing; otherwise `null`.
  String? get problem =>
      _problem ??
      switch (status) {
        KnxIpStatus.noMoreConnections => 'noFreeTunnel',
        KnxIpStatus.noMoreUniqueConnections ||
        KnxIpStatus.connectionInUse ||
        KnxIpStatus.authorisation ||
        KnxIpStatus.noTunnellingAddress => 'tunnelAddress',
        KnxIpStatus.connectionType || KnxIpStatus.connectionOption || KnxIpStatus.tunnellingLayer => 'unsupported',
        _ => null,
      };
  @override
  String toString() => message;
}

/// Connection to the KNX bus: tunnel (UDP, TCP, Secure) or routing.
///
/// Delivers received cEMI frames (L_Data.ind and L_Data.con) and accepts
/// L_Data.req for sending.
abstract class BusLink {
  /// Received cEMI frames.
  Stream<Uint8List> get frames;

  /// Own individual address (tunnel address or routing address).
  int? get address;

  /// Short description for status and log, e.g. "UDP tunnel 1.1.38".
  String get label;

  Future<void> connect();

  /// Sends an L_Data.req. Returns as soon as the interface has accepted it;
  /// throws [LinkException] otherwise.
  Future<void> send(Uint8List cemi);

  /// Completes with the reason when the connection drops.
  Future<String> get lost;

  Future<void> close();
}

// --- Transport -------------------------------------------------------------------

abstract class _Transport {
  Stream<Uint8List> get packets;
  List<int> get hpai;
  bool get reliable;
  void send(List<int> frame);
  Future<void> close();
}

class _UdpTransport implements _Transport {
  _UdpTransport._(this._socket, this._gateway, this._port) {
    _socket.listen(
      (e) {
        if (e != RawSocketEvent.read) return;
        final dg = _socket.receive();
        // Only our own gateway: otherwise anyone on the LAN who guesses the
        // channel id could disconnect the tunnel or inject telegrams.
        if (dg == null || dg.address != _gateway) return;
        _packets.add(dg.data);
      },
      onError: (Object e) => _packets.addError(e),
      onDone: () => _packets.close(),
    );
  }

  static Future<_UdpTransport> open(InternetAddress gateway, int port) async =>
      _UdpTransport._(await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0), gateway, port);

  final RawDatagramSocket _socket;
  final InternetAddress _gateway;
  final int _port;
  final _packets = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get packets => _packets.stream;
  @override
  List<int> get hpai => hpaiUdpNat;
  @override
  bool get reliable => false;
  @override
  void send(List<int> frame) => _socket.send(frame, _gateway, _port);
  @override
  Future<void> close() async {
    _socket.close();
    if (!_packets.isClosed) await _packets.close();
  }
}

class _TcpTransport implements _Transport {
  _TcpTransport._(this._socket) {
    _socket.listen(
      _onData,
      onError: (Object e) => _packets.addError(e),
      onDone: () {
        if (!_packets.isClosed) _packets.addError(const LinkException('Gateway closed the TCP connection'));
        _packets.close();
      },
    );
  }

  static Future<_TcpTransport> open(InternetAddress gateway, int port) async => _TcpTransport._(
    await Socket.connect(gateway, port, timeout: const Duration(seconds: 5))
      ..setOption(SocketOption.tcpNoDelay, true),
  );

  final Socket _socket;
  final _packets = StreamController<Uint8List>.broadcast();
  final _buffer = BytesBuilder();

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    var bytes = _buffer.takeBytes();
    while (bytes.length >= 6) {
      final len = (bytes[4] << 8) | bytes[5];
      if (bytes[0] != 0x06 || bytes[1] != 0x10 || len < 6) {
        _packets.addError(const LinkException('Invalid KNXnet/IP stream'));
        _socket.destroy();
        return;
      }
      if (bytes.length < len) break;
      _packets.add(Uint8List.fromList(bytes.sublist(0, len)));
      bytes = Uint8List.sublistView(bytes, len);
    }
    _buffer.add(bytes);
  }

  @override
  Stream<Uint8List> get packets => _packets.stream;
  @override
  List<int> get hpai => hpaiTcp;
  @override
  bool get reliable => true;
  @override
  void send(List<int> frame) => _socket.add(frame);
  @override
  Future<void> close() async {
    _socket.destroy();
    if (!_packets.isClosed) await _packets.close();
  }
}

// --- Tunnel ----------------------------------------------------------------------

/// KNXnet/IP tunnel (link layer) over UDP or TCP.
///
/// [requestedAddress] requests a fixed tunnel address (Tunnelling v2); if it
/// is taken or unknown, the tunnel takes any free slot when [fallback] is set.
class KnxIpTunnel implements BusLink {
  KnxIpTunnel({
    required this.host,
    this.port = 3671,
    this.tcp = false,
    this.requestedAddress,
    this.fallback = true,
    this.heartbeatInterval = const Duration(seconds: 60),
    this.responseTimeout = const Duration(seconds: 5),
    this.secure,
  });

  /// IP Secure: creates the session (only with [tcp]).
  final IpSecureSession Function()? secure;
  IpSecureSession? _session;
  Timer? _keepalive;

  final String host;
  final int port;
  final bool tcp;
  final int? requestedAddress;
  final bool fallback;
  final Duration heartbeatInterval;
  final Duration responseTimeout;

  _Transport? _transport;
  StreamSubscription<Uint8List>? _sub;
  final _frames = StreamController<Uint8List>.broadcast();
  final _lost = Completer<String>();
  int _channel = 0;
  int _sendSeq = 0;
  int _expectedSeq = 0;
  Timer? _heartbeat;
  Timer? _heartbeatTimeout;
  Completer<Uint8List>? _connectResponse;
  Completer<int>? _ack;
  int? _ackSeq;
  Future<void> _queue = Future.value();
  bool _connected = false;

  @override
  int? address;

  @override
  String get label =>
      '${secure != null ? 'IP Secure' : (tcp ? 'TCP' : 'UDP')} tunnel${address == null ? '' : ' ${formatIndividual(address!)}'}';

  /// Sends a frame; encrypted in a secure session.
  void _out(List<int> frame) {
    final session = _session;
    _transport?.send(session != null && session.established ? session.wrap(frame) : frame);
  }

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<String> get lost => _lost.future;

  @override
  Future<void> connect() async {
    final gateway = await resolveIPv4(host);
    try {
      _transport = tcp ? await _TcpTransport.open(gateway, port) : await _UdpTransport.open(gateway, port);
    } on SocketException catch (e) {
      throw LinkException('Gateway unreachable: ${e.osError?.message ?? e.message}', problem: 'network');
    }
    _sub = _transport!.packets.listen((p) {
      final session = _session;
      final plain = session == null ? p : session.handle(p);
      if (plain != null) _onPacket(plain);
    }, onError: (Object e) => _drop('$e'));
    try {
      if (secure != null) {
        final session = secure!();
        _session = session;
        session.onStatus = (status) {
          if (status != IpSecureSession.statusKeepalive && status != IpSecureSession.statusOk) {
            _drop('Gateway hat die gesicherte Sitzung beendet');
          }
        };
        try {
          await session.handshake(_transport!.send);
        } on IpSecureException catch (e) {
          throw switch (e.reason) {
            'auth' => const LinkException('IP Secure: user or password rejected', problem: 'secureAuth'),
            'device' => const LinkException(
              'IP Secure: device authentication code does not match',
              problem: 'secureDevice',
            ),
            // Low-order key from the "gateway": not a gateway we may talk to.
            'key' => const LinkException('IP Secure: invalid key from the gateway', problem: 'secureDevice'),
            _ => const LinkException('IP Secure: gateway does not respond', problem: 'noResponse'),
          };
        }
        _keepalive = Timer.periodic(const Duration(seconds: 50), (_) {
          if (session.established) _transport?.send(session.keepalive());
        });
      }
      var res = await _requestConnection(requestedAddress);
      if (res[7] != KnxIpStatus.ok && requestedAddress != null && fallback && _addressProblem(res[7])) {
        res = await _requestConnection(null);
      }
      final status = res[7];
      if (status != KnxIpStatus.ok) throw LinkException(statusText(status), status: status);
      _channel = res[6];
      address = res.length >= 20 ? (res[18] << 8) | res[19] : null;
      _sendSeq = 0;
      _expectedSeq = 0;
      _connected = true;
      _heartbeat = Timer.periodic(heartbeatInterval, (_) => _sendHeartbeat());
    } catch (_) {
      await _cleanup();
      rethrow;
    }
  }

  /// Reasons for which a tunnel without a fixed address may still succeed.
  static bool _addressProblem(int status) => const {
    KnxIpStatus.connectionOption,
    KnxIpStatus.noMoreUniqueConnections,
    KnxIpStatus.authorisation,
    KnxIpStatus.noTunnellingAddress,
    KnxIpStatus.connectionInUse,
  }.contains(status);

  Future<Uint8List> _requestConnection(int? address) async {
    _connectResponse = Completer();
    final hpai = _transport!.hpai;
    _out(knxFrame(KnxIpService.connectRequest, [...hpai, ...hpai, ...tunnelCri(address: address)]));
    return _connectResponse!.future.timeout(
      responseTimeout,
      onTimeout: () => throw const LinkException('Gateway does not respond', problem: 'noResponse'),
    );
  }

  @override
  Future<void> send(Uint8List cemi) {
    final f = _queue.then((_) => _sendTunnel(cemi));
    _queue = f.catchError((_) {});
    return f;
  }

  Future<void> _sendTunnel(Uint8List cemi) async {
    if (!_connected) throw const LinkException('Nicht verbunden');
    final seq = _sendSeq;
    final frame = knxFrame(KnxIpService.tunnelRequest, [0x04, _channel, seq, 0x00, ...cemi]);
    if (_transport!.reliable) {
      // TCP: no tunnelling ACK, TCP guarantees delivery.
      _out(frame);
      _sendSeq = (seq + 1) & 0xFF;
      return;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      _ack = Completer();
      _ackSeq = seq;
      _out(frame);
      try {
        final status = await _ack!.future.timeout(const Duration(seconds: 1));
        _sendSeq = (seq + 1) & 0xFF;
        if (status != KnxIpStatus.ok) {
          throw LinkException('Gateway rejects the telegram (0x${status.toRadixString(16)})');
        }
        return;
      } on TimeoutException {
        // retry once
      } finally {
        _ack = null;
      }
    }
    // Specification: close the connection after two missing ACKs.
    _drop('Gateway does not acknowledge');
    throw const LinkException('Gateway does not acknowledge');
  }

  void _onPacket(Uint8List p) {
    final service = serviceOf(p);
    switch (service) {
      case KnxIpService.connectResponse:
        if (p.length >= 8 && !(_connectResponse?.isCompleted ?? true)) _connectResponse!.complete(p);
      case KnxIpService.tunnelRequest:
        _onTunnelRequest(p);
      case KnxIpService.tunnelAck:
        if (p.length >= 10 && p[7] == _channel && p[8] == _ackSeq && !(_ack?.isCompleted ?? true)) {
          _ack!.complete(p[9]);
        }
      case KnxIpService.stateResponse:
        if (p.length >= 8 && p[6] == _channel) {
          _heartbeatTimeout?.cancel();
          if (p[7] != KnxIpStatus.ok) _drop('Gateway ended the connection');
        }
      case KnxIpService.disconnectRequest:
        if (p.length >= 7 && p[6] == _channel) {
          _out(knxFrame(KnxIpService.disconnectResponse, [_channel, 0x00]));
          _drop('Gateway ended the connection');
        }
    }
  }

  void _onTunnelRequest(Uint8List p) {
    if (p.length < 10 || p[7] != _channel || !_connected) return;
    // The connection header length is in the packet; a forged UDP packet may
    // claim more than there is. Do not acknowledge, the gateway will repeat.
    final start = 6 + p[6];
    if (start > p.length) return;
    final seq = p[8];
    if (!_transport!.reliable) {
      if (seq == ((_expectedSeq - 1) & 0xFF)) {
        // Repetition of a frame already processed: only acknowledge.
        _out(knxFrame(KnxIpService.tunnelAck, [0x04, _channel, seq, 0x00]));
        return;
      }
      if (seq != _expectedSeq) return; // out of sequence: do not acknowledge, the gateway will repeat
      _transport!.send(knxFrame(KnxIpService.tunnelAck, [0x04, _channel, seq, 0x00]));
      _expectedSeq = (seq + 1) & 0xFF;
    }
    final cemi = Uint8List.fromList(p.sublist(start));
    if (cemi.isNotEmpty) _frames.add(cemi);
  }

  void _sendHeartbeat([int attempt = 1]) {
    if (!_connected) return;
    _out(knxFrame(KnxIpService.stateRequest, [_channel, 0x00, ..._transport!.hpai]));
    _heartbeatTimeout?.cancel();
    _heartbeatTimeout = Timer(const Duration(seconds: 10), () {
      if (attempt >= 3) {
        _drop('Gateway stopped responding');
      } else {
        _sendHeartbeat(attempt + 1);
      }
    });
  }

  void _drop(String reason) {
    if (!_lost.isCompleted && _connected) _lost.complete(reason);
    _connected = false;
    unawaited(_cleanup());
  }

  Future<void> _cleanup() async {
    _keepalive?.cancel();
    final session = _session;
    _session = null;
    if (session != null && session.established) _transport?.send(session.close());
    _heartbeat?.cancel();
    _heartbeatTimeout?.cancel();
    await _sub?.cancel();
    _sub = null;
    await _transport?.close();
    _transport = null;
  }

  @override
  Future<void> close() async {
    if (_connected && _transport != null) {
      _out(knxFrame(KnxIpService.disconnectRequest, [_channel, 0x00, ..._transport!.hpai]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _connected = false;
    if (!_lost.isCompleted) _lost.complete('Disconnected');
    await _cleanup();
    if (!_frames.isClosed) await _frames.close();
  }
}

/// Text for a status code from CONNECT_RESPONSE.
String statusText(int status) => switch (status) {
  KnxIpStatus.noMoreConnections => 'Gateway has no free tunnel',
  KnxIpStatus.noMoreUniqueConnections || KnxIpStatus.connectionInUse => 'Tunnel address is in use',
  KnxIpStatus.connectionType => 'Gateway does not support tunnelling',
  KnxIpStatus.connectionOption => 'Gateway does not support the connection option',
  KnxIpStatus.tunnellingLayer => 'Gateway does not support the link layer',
  KnxIpStatus.authorisation => 'No permission for the tunnel address',
  KnxIpStatus.noTunnellingAddress => 'Address is not a tunnel address of the gateway',
  _ => 'Gateway rejects the connection (0x${status.toRadixString(16)})',
};

Future<InternetAddress> resolveIPv4(String host) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return literal;
  try {
    return (await InternetAddress.lookup(host, type: InternetAddressType.IPv4)).first;
  } on SocketException {
    throw LinkException('Host $host not found', problem: 'network');
  }
}

/// Queries the gateway's self description (DESCRIPTION_RESPONSE without
/// header). `null` if it does not respond.
Future<Uint8List?> describeGateway(String host, int port) async {
  RawDatagramSocket? socket;
  try {
    final gateway = await resolveIPv4(host);
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final result = Completer<Uint8List?>();
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final dg = socket!.receive();
      if (dg == null || dg.address != gateway || serviceOf(dg.data) != KnxIpService.descriptionResponse) return;
      if (!result.isCompleted) result.complete(Uint8List.fromList(dg.data.sublist(6)));
    }, onError: (Object _) {});
    socket.send(knxFrame(KnxIpService.descriptionRequest, hpaiUdpNat), gateway, port);
    return await result.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
  } on Object {
    return null;
  } finally {
    socket?.close();
  }
}

// --- Routing ---------------------------------------------------------------------

/// KNXnet/IP routing (multicast 224.0.23.12). Sends with [address] as the
/// source; the link generates the confirmation (L_Data.con) itself, since
/// routing has none.
class RoutingLink implements BusLink {
  RoutingLink({required this.address, this.group = '224.0.23.12', this.port = 3671});

  @override
  final int address;
  final String group;
  final int port;

  RawDatagramSocket? _socket;
  final _frames = StreamController<Uint8List>.broadcast();
  final _lost = Completer<String>();
  Future<void> _queue = Future.value();
  DateTime _busyUntil = DateTime(0);

  @override
  String get label => 'Routing ${formatIndividual(address)}';
  @override
  Stream<Uint8List> get frames => _frames.stream;
  @override
  Future<String> get lost => _lost.future;

  @override
  Future<void> connect() async {
    final multicast = InternetAddress(group);
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true, reusePort: true);
      socket
        ..multicastLoopback = false
        ..joinMulticast(multicast);
      _socket = socket;
    } on SocketException catch (e) {
      throw LinkException('Routing not possible: ${e.osError?.message ?? e.message}', problem: 'routing');
    }
    _socket!.listen(
      (e) {
        if (e != RawSocketEvent.read) return;
        final dg = _socket?.receive();
        if (dg == null) return;
        switch (serviceOf(dg.data)) {
          case KnxIpService.routingIndication:
            final cemi = Uint8List.fromList(dg.data.sublist(6));
            // Do not duplicate our own frames (e.g. coming back via a second router).
            if (cemi.length > 5 && cemi[0] == 0x29 && _sourceOf(cemi) == address) return;
            _frames.add(cemi);
          case KnxIpService.routingBusy:
            if (dg.data.length >= 10) {
              final wait = (dg.data[8] << 8) | dg.data[9];
              _busyUntil = DateTime.now().add(Duration(milliseconds: wait.clamp(20, 1000)));
            }
        }
      },
      onError: (Object e) {
        if (!_lost.isCompleted) _lost.complete('Routing-Socket: $e');
      },
    );
  }

  static int _sourceOf(Uint8List c) {
    final i = 2 + c[1];
    return c.length < i + 4 ? -1 : (c[i + 2] << 8) | c[i + 3];
  }

  @override
  Future<void> send(Uint8List cemi) {
    final f = _queue.then((_) => _send(cemi));
    _queue = f.catchError((_) {});
    return f;
  }

  Future<void> _send(Uint8List cemi) async {
    final socket = _socket;
    if (socket == null || cemi.length < 10) throw const LinkException('Nicht verbunden');
    final wait = _busyUntil.difference(DateTime.now());
    if (!wait.isNegative) await Future<void>.delayed(wait);
    final i = 2 + cemi[1];
    final ind = Uint8List.fromList(cemi)
      ..[0] = 0x29
      ..[i + 2] = address >> 8
      ..[i + 3] = address & 0xFF;
    socket.send(knxFrame(KnxIpService.routingIndication, ind), InternetAddress(group), port);
    // Routing has no acknowledgement; we generate the confirmation ourselves so
    // that senders see, as with a tunnel, that their telegram went out.
    _frames.add(Uint8List.fromList(ind)..[0] = 0x2E);
    // At most 50 telegrams per second (KNXnet/IP routing, flow control).
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  @override
  Future<void> close() async {
    _socket?.close();
    _socket = null;
    if (!_lost.isCompleted) _lost.complete('Disconnected');
    if (!_frames.isClosed) await _frames.close();
  }
}
