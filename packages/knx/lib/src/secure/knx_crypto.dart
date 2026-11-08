import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Cryptographic building blocks for KNX Secure (IP Secure and Data Secure).
///
/// KNX uses AES-128 in CCM mode, but with its own block formatting: the MAC is computed via CBC
/// over "block 0 + length of additional data + additional data + payload", encryption uses CTR,
/// with counter 0 encrypting the MAC. Algorithms according to AN158/AN159 of the KNX Association,
/// verified against their examples (see tests); structure modelled on xknx (MIT, notice in the
/// package's NOTICE file).

Uint8List _aesBlock(Uint8List key, Uint8List block) {
  final aes = AESEngine()..init(true, KeyParameter(key));
  final out = Uint8List(16);
  aes.processBlock(block, 0, out, 0);
  return out;
}

/// CBC-MAC over `block0 + len(additional) + additional + payload`, padded to 16 bytes. Returns the
/// last block (16 bytes).
Uint8List cbcMac(List<int> key, List<int> additionalData, {List<int> payload = const [], List<int>? block0}) {
  final data = BytesBuilder()
    ..add(block0 ?? Uint8List(16))
    ..add([additionalData.length >> 8, additionalData.length & 0xFF])
    ..add(additionalData)
    ..add(payload);
  var bytes = data.takeBytes();
  if (bytes.length % 16 != 0) bytes = Uint8List.fromList([...bytes, ...List.filled(16 - bytes.length % 16, 0)]);
  final k = Uint8List.fromList(key);
  var y = Uint8List(16);
  for (var i = 0; i < bytes.length; i += 16) {
    final block = Uint8List(16);
    for (var j = 0; j < 16; j++) {
      block[j] = y[j] ^ bytes[i + j];
    }
    y = _aesBlock(k, block);
  }
  return y;
}

/// AES-CTR from [counter0] as one continuous key stream: [mac] is processed first, [payload]
/// directly after it (with Data Secure the MAC is only 4 bytes long, so the payload starts in the
/// middle of the first block). Returns (processed payload, processed MAC) – encryption and
/// decryption are the same operation.
(Uint8List data, Uint8List mac) ctr(List<int> key, List<int> counter0, List<int> mac, [List<int> payload = const []]) {
  final k = Uint8List.fromList(key);
  final counter = Uint8List.fromList(counter0);
  final input = [...mac, ...payload];
  final out = Uint8List(input.length);
  for (var i = 0; i < input.length; i += 16) {
    final s = _aesBlock(k, counter);
    for (var j = 0; j < 16 && i + j < input.length; j++) {
      out[i + j] = input[i + j] ^ s[j];
    }
    // Increment the counter as a 128-bit number.
    for (var b = 15; b >= 0; b--) {
      counter[b] = (counter[b] + 1) & 0xFF;
      if (counter[b] != 0) break;
    }
  }
  return (Uint8List.sublistView(out, mac.length), Uint8List.sublistView(out, 0, mac.length));
}

/// AES-128-CBC without padding (keyring fields).
Uint8List aesCbcDecrypt(List<int> data, List<int> key, List<int> iv) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(Uint8List.fromList(key)), Uint8List.fromList(iv)));
  final input = Uint8List.fromList(data);
  final out = Uint8List(input.length);
  for (var i = 0; i + 16 <= input.length; i += 16) {
    cipher.processBlock(input, i, out, i);
  }
  return out;
}

Uint8List pbkdf2Sha256(List<int> password, String salt, {int iterations = 65536, int length = 16}) {
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(utf8.encode(salt)), iterations, length));
  return kdf.process(Uint8List.fromList(password));
}

Uint8List sha256(List<int> data) => SHA256Digest().process(Uint8List.fromList(data));

/// User password of a secure tunnel → key.
Uint8List deriveUserPassword(String password) =>
    pbkdf2Sha256(latin1.encode(password), 'user-password.1.secure.ip.knx.org');

/// Device authentication code → key.
Uint8List deriveDeviceAuthentication(String code) =>
    pbkdf2Sha256(latin1.encode(code), 'device-authentication-code.1.secure.ip.knx.org');

/// Keyring password → key.
Uint8List deriveKeyringPassword(String password) => pbkdf2Sha256(utf8.encode(password), '1.keyring.ets.knx.org');

// --- X25519 (RFC 7748) --------------------------------------------------------------

final _p = (BigInt.one << 255) - BigInt.from(19);
final _a24 = BigInt.from(121665);

BigInt _decodeLE(List<int> b) {
  var r = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    r = (r << 8) | BigInt.from(b[i]);
  }
  return r;
}

Uint8List _encodeLE(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  for (var i = 0; i < 32; i++) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x >>= 8;
  }
  return out;
}

/// Scalar multiplication on Curve25519 (Montgomery ladder).
Uint8List x25519(List<int> scalar, List<int> uCoordinate) {
  final k = Uint8List.fromList(scalar);
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;
  final u = Uint8List.fromList(uCoordinate)..[31] &= 127;
  final kInt = _decodeLE(k);
  final x1 = _decodeLE(u) % _p;
  var x2 = BigInt.one, z2 = BigInt.zero, x3 = x1, z3 = BigInt.one;
  var swap = 0;
  for (var t = 254; t >= 0; t--) {
    final kt = ((kInt >> t) & BigInt.one).toInt();
    swap ^= kt;
    if (swap == 1) {
      (x2, x3) = (x3, x2);
      (z2, z3) = (z3, z2);
    }
    swap = kt;
    final a = (x2 + z2) % _p;
    final aa = (a * a) % _p;
    final b = (x2 - z2) % _p;
    final bb = (b * b) % _p;
    final e = (aa - bb) % _p;
    final c = (x3 + z3) % _p;
    final d = (x3 - z3) % _p;
    final da = (d * a) % _p;
    final cb = (c * b) % _p;
    x3 = ((da + cb) * (da + cb)) % _p;
    z3 = (x1 * ((da - cb) * (da - cb))) % _p;
    x2 = (aa * bb) % _p;
    z2 = (e * (aa + _a24 * e)) % _p;
  }
  if (swap == 1) {
    (x2, x3) = (x3, x2);
    (z2, z3) = (z3, z2);
  }
  return _encodeLE((x2 * z2.modPow(_p - BigInt.two, _p)) % _p);
}

/// New key pair (private, public).
(Uint8List private, Uint8List public) x25519KeyPair([Random? random]) {
  final r = random ?? Random.secure();
  final private = Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
  final base = Uint8List(32)..[0] = 9;
  return (private, x25519(private, base));
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List fromHex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2) int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}
