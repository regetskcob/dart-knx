import 'dart:async';
import 'dart:typed_data';

import 'knx_crypto.dart';

/// Error in the IP Secure handshake or in the secure session.
class IpSecureException implements Exception {
  const IpSecureException(this.reason, [this.status]);

  /// `auth` = user/password rejected, `device` = device code does not match, `key` = the gateway's
  /// public key yields no usable shared secret, `timeout`, `closed`.
  final String reason;
  final int? status;
  @override
  String toString() => 'IP Secure: $reason${status == null ? '' : ' ($status)'}';
}

/// KNX IP Secure: secure session over TCP (AN159).
///
/// Sequence: SESSION_REQUEST with our own X25519 key → SESSION_RESPONSE with the gateway's
/// (optionally verified with the device code) → shared session key → SESSION_AUTHENTICATE with the
/// user password → SESSION_STATUS. After that every frame is encrypted inside a SECURE_WRAPPER.
class IpSecureSession {
  IpSecureSession({
    required this.userId,
    required String userPassword,
    String? deviceAuthentication,
    List<int>? serialNumber,
    List<int>? messageTag,
    (Uint8List, Uint8List)? keyPair,
  }) : _userKey = deriveUserPassword(userPassword),
       _deviceKey = (deviceAuthentication == null || deviceAuthentication.isEmpty)
           ? null
           : deriveDeviceAuthentication(deviceAuthentication),
       serial = Uint8List.fromList(serialNumber ?? defaultSerial),
       tag = Uint8List.fromList(messageTag ?? const [0x00, 0x00]),
       _keys = keyPair ?? x25519KeyPair();

  /// Own "serial number" in the wrappers (freely chosen, 6 bytes): "KMON".
  static const defaultSerial = [0x00, 0x00, 0x4B, 0x4D, 0x4F, 0x4E];

  static const sessionRequest = 0x0951;
  static const sessionResponse = 0x0952;
  static const sessionAuthenticate = 0x0953;
  static const sessionStatus = 0x0954;
  static const secureWrapper = 0x0950;

  /// Status codes in SESSION_STATUS.
  static const statusOk = 0x00, statusAuthFailed = 0x01, statusUnauthenticated = 0x02, statusTimeout = 0x03;
  static const statusKeepalive = 0x04, statusClose = 0x05;

  final int userId;
  final Uint8List _userKey;
  final Uint8List? _deviceKey;
  final Uint8List serial;
  final Uint8List tag;
  final (Uint8List, Uint8List) _keys;

  Uint8List? _key;
  int sessionId = 0;
  int _sendSeq = 0;
  int _receivedSeq = -1;
  bool get established => _key != null && _authenticated;
  bool _authenticated = false;

  Completer<Uint8List>? _response;
  Completer<int>? _status;

  /// Reports the gateway's SESSION_STATUS after setup (close, timeout).
  void Function(int status)? onStatus;

  static Uint8List _frame(int service, List<int> body) {
    final len = 6 + body.length;
    return Uint8List.fromList([0x06, 0x10, service >> 8, service & 0xFF, len >> 8, len & 0xFF, ...body]);
  }

  /// Establishes the session. [send] sends raw bytes to the gateway; the responses come in via
  /// [handle].
  Future<void> handshake(void Function(List<int>) send, {Duration timeout = const Duration(seconds: 10)}) async {
    _response = Completer();
    send(_frame(sessionRequest, [0x08, 0x02, 0, 0, 0, 0, 0, 0, ..._keys.$2]));
    final res = await _response!.future.timeout(timeout, onTimeout: () => throw const IpSecureException('timeout'));
    sessionId = (res[0] << 8) | res[1];
    final serverKey = res.sublist(2, 34);
    final mac = res.sublist(34, 50);
    final xor = [for (var i = 0; i < 32; i++) _keys.$2[i] ^ serverKey[i]];
    final counter0 = Uint8List(16)..[14] = 0xFF;
    if (_deviceKey != null) {
      final expected = cbcMac(_deviceKey, [0x06, 0x10, 0x09, 0x52, 0x00, 0x38, res[0], res[1], ...xor]);
      final (_, macTr) = ctr(_deviceKey, counter0, mac);
      if (!bytesEqual(expected, macTr)) throw const IpSecureException('device');
    }
    final shared = x25519(_keys.$1, serverKey);
    // A low-order public key (e.g. all zeros) forces the shared secret to zero, so whoever sent it
    // would know the session key (RFC 7748, section 6.1).
    if (shared.every((b) => b == 0)) throw const IpSecureException('key');
    _key = sha256(shared).sublist(0, 16);
    final authMac = cbcMac(_userKey, [0x06, 0x10, 0x09, 0x53, 0x00, 0x18, 0x00, userId, ...xor]);
    final (_, authMacEnc) = ctr(_userKey, counter0, authMac);
    _status = Completer();
    send(wrap(_frame(sessionAuthenticate, [0x00, userId, ...authMacEnc])));
    final status = await _status!.future.timeout(timeout, onTimeout: () => throw const IpSecureException('timeout'));
    if (status != statusOk) throw IpSecureException('auth', status);
    _authenticated = true;
  }

  /// Wraps a KNXnet/IP frame in a SECURE_WRAPPER.
  Uint8List wrap(List<int> plain) {
    final key = _key;
    if (key == null) throw const IpSecureException('closed');
    final seq = _sendSeq++;
    final seqBytes = [for (var i = 5; i >= 0; i--) (seq >> (8 * i)) & 0xFF];
    final total = 38 + plain.length;
    final header = [0x06, 0x10, 0x09, 0x50, total >> 8, total & 0xFF];
    final mac = cbcMac(
      key,
      [...header, sessionId >> 8, sessionId & 0xFF],
      payload: plain,
      block0: [...seqBytes, ...serial, ...tag, plain.length >> 8, plain.length & 0xFF],
    );
    final (data, macEnc) = ctr(key, [...seqBytes, ...serial, ...tag, 0xFF, 0x00], mac, plain);
    return Uint8List.fromList([
      ...header,
      sessionId >> 8,
      sessionId & 0xFF,
      ...seqBytes,
      ...serial,
      ...tag,
      ...data,
      ...macEnc,
    ]);
  }

  /// Processes a received frame. Returns the decrypted KNXnet/IP frame, or `null` for session
  /// traffic and discarded frames.
  Uint8List? handle(Uint8List p) {
    if (p.length < 6) return null;
    final service = (p[2] << 8) | p[3];
    if (service == sessionResponse) {
      if (p.length == 56 && !(_response?.isCompleted ?? true)) _response!.complete(Uint8List.sublistView(p, 6));
      return null;
    }
    if (service != secureWrapper || _key == null || p.length < 6 + 16 + 2 + 16) return null;
    final body = Uint8List.sublistView(p, 6);
    if (((body[0] << 8) | body[1]) != sessionId) return null;
    final seqBytes = body.sublist(2, 8);
    var seq = 0;
    for (final b in seqBytes) {
      seq = (seq << 8) | b;
    }
    if (seq <= _receivedSeq) return null; // replay or attack
    final serialIn = body.sublist(8, 14);
    final tagIn = body.sublist(14, 16);
    final encrypted = body.sublist(16, body.length - 16);
    final macIn = body.sublist(body.length - 16);
    final (plain, macTr) = ctr(_key!, [...seqBytes, ...serialIn, ...tagIn, 0xFF, 0x00], macIn, encrypted);
    final expected = cbcMac(
      _key!,
      [...p.sublist(0, 6), body[0], body[1]],
      payload: plain,
      block0: [...seqBytes, ...serialIn, ...tagIn, plain.length >> 8, plain.length & 0xFF],
    );
    if (!bytesEqual(expected, macTr)) return null;
    _receivedSeq = seq;
    if (plain.length >= 8 && ((plain[2] << 8) | plain[3]) == sessionStatus) {
      final status = plain[6];
      if (!(_status?.isCompleted ?? true)) {
        _status!.complete(status);
      } else {
        onStatus?.call(status);
      }
      return null;
    }
    return plain;
  }

  /// Keep-alive so the gateway does not close the session (60 s).
  Uint8List keepalive() => wrap(_frame(sessionStatus, [statusKeepalive, 0x00]));

  /// Log off.
  Uint8List close() => wrap(_frame(sessionStatus, [statusClose, 0x00]));
}
