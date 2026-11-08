import 'dart:convert';
import 'dart:typed_data';

import 'knx_crypto.dart';

/// Result of receiving a frame.
enum SecureResult {
  /// Not a Data Secure frame.
  plain,

  /// Decrypted or verified.
  decrypted,

  /// Data Secure, but no key for the group address.
  noKey,

  /// Invalid MAC or sequence number (replay, tampering, foreign sender).
  invalid,
}

/// KNX Data Secure for group telegrams (S-A_Data, AN158): decrypts received telegrams and encrypts our
/// own telegrams to secured addresses. Structure modelled on xknx (MIT), verified against its examples;
/// license notice in the package's NOTICE file.
class DataSecure {
  DataSecure({required this.groupKeys, required Map<int, int> sequenceNumbers, int? sequenceStart})
    : _lastSeq = Map.of(sequenceNumbers),
      _sendSeq = sequenceStart ?? _initialSequence();

  /// From the JSON form of the keys (group keys and last sequence numbers), as Busclear stores them.
  factory DataSecure.fromJson(Map<String, Object?> j) => DataSecure(
    groupKeys: {
      for (final MapEntry(:key, :value) in ((j['groupKeys'] as Map?) ?? const {}).entries)
        int.parse('$key'): base64.decode('$value'),
    },
    sequenceNumbers: {
      for (final MapEntry(:key, :value) in ((j['sequence'] as Map?) ?? const {}).entries)
        int.parse('$key'): value as int,
    },
  );

  final Map<int, Uint8List> groupKeys;
  final Map<int, int> _lastSeq;
  int _sendSeq;

  /// Called after a received telegram advanced a sender's counter. Whoever keeps [lastSequences]
  /// across restarts makes sure older recorded telegrams do not count as valid again.
  void Function()? onSequence;

  /// Highest accepted sequence number per sender (individual address).
  Map<int, int> get lastSequences => Map.unmodifiable(_lastSeq);

  /// Milliseconds since 2018-01-05 – increases by itself, even without a stored counter.
  static int _initialSequence() => DateTime.now().toUtc().difference(DateTime.utc(2018, 1, 5)).inMilliseconds;

  /// Whether [cemi] is an L_Data frame with a secured APDU (S-A_Data).
  static bool isSecure(List<int> cemi) {
    if (cemi.length < 2) return false;
    final i = 2 + cemi[1];
    return cemi.length > i + 9 && cemi[i + 7] & 0x03 == 0x03 && cemi[i + 8] == 0xF1;
  }

  static List<int> _block0(List<int> seq, List<int> addresses, int ctrl2, int tpci, int length) => [
    ...seq,
    ...addresses,
    0,
    (ctrl2 & 0x80) | (ctrl2 & 0x0F),
    (tpci << 2) + 0x03,
    0xF1,
    0,
    length,
  ];

  /// Decrypts a received frame. With [SecureResult.decrypted] the frame is the
  /// same cEMI frame with a plaintext APDU.
  (SecureResult, Uint8List) receive(Uint8List cemi) {
    if (!isSecure(cemi)) return (SecureResult.plain, cemi);
    final i = 2 + cemi[1];
    final ctrl2 = cemi[i + 1];
    final source = (cemi[i + 2] << 8) | cemi[i + 3];
    final destination = (cemi[i + 4] << 8) | cemi[i + 5];
    final tpdu = cemi.sublist(i + 7);
    final scf = tpdu[2];
    // Only S-A_Data to group addresses, without tool access/system broadcast.
    if (scf & 0x07 != 0 || scf & 0x88 != 0 || ctrl2 & 0x80 == 0) return (SecureResult.invalid, cemi);
    final key = groupKeys[destination];
    if (key == null) return (SecureResult.noKey, cemi);
    if (tpdu.length < 3 + 6 + 4) return (SecureResult.invalid, cemi);
    final seqBytes = tpdu.sublist(3, 9);
    var seq = 0;
    for (final b in seqBytes) {
      seq = (seq << 8) | b;
    }
    final last = _lastSeq[source];
    if (last == null || seq <= last) return (SecureResult.invalid, cemi);
    final secured = tpdu.sublist(9, tpdu.length - 4);
    final mac = tpdu.sublist(tpdu.length - 4);
    final addresses = cemi.sublist(i + 2, i + 6);
    final tpci = (tpdu[0] >> 2) & 0x3F;
    final Uint8List apdu;
    if ((scf >> 4) & 0x07 == 1) {
      final (plain, macTr) = ctr(key, [...seqBytes, ...addresses, 0, 0, 0, 0, 1, 0], mac, secured);
      final expected = cbcMac(
        key,
        [scf],
        payload: plain,
        block0: _block0(seqBytes, addresses, ctrl2, tpci, plain.length),
      );
      if (!bytesEqual(expected.sublist(0, 4), macTr)) return (SecureResult.invalid, cemi);
      apdu = plain;
    } else {
      final expected = cbcMac(key, [scf, ...secured], block0: _block0(seqBytes, addresses, ctrl2, tpci, 0));
      if (!bytesEqual(expected.sublist(0, 4), mac)) return (SecureResult.invalid, cemi);
      apdu = Uint8List.fromList(secured);
    }
    if (apdu.length < 2) return (SecureResult.invalid, cemi);
    _lastSeq[source] = seq;
    onSequence?.call();
    return (
      SecureResult.decrypted,
      Uint8List.fromList([
        ...cemi.sublist(0, i + 6),
        apdu.length - 1,
        (tpdu[0] & 0xFC) | (apdu[0] & 0x03),
        ...apdu.sublist(1),
      ]),
    );
  }

  /// Encrypts an L_Data.req to a secured group address ([source] = own tunnel
  /// address; it is part of the MAC). Other frames remain unchanged.
  Uint8List send(Uint8List cemi, {required int source}) {
    if (cemi.length < 2) return cemi;
    final i = 2 + cemi[1];
    if (cemi.length < i + 9 || cemi[i + 1] & 0x80 == 0) return cemi;
    final destination = (cemi[i + 4] << 8) | cemi[i + 5];
    final key = groupKeys[destination];
    if (key == null) return cemi;
    final ctrl2 = cemi[i + 1];
    final tpdu = cemi.sublist(i + 7);
    final tpci = (tpdu[0] >> 2) & 0x3F;
    final apdu = [tpdu[0] & 0x03, ...tpdu.sublist(1)];
    final seq = _sendSeq++;
    final seqBytes = [for (var b = 5; b >= 0; b--) (seq >> (8 * b)) & 0xFF];
    final addresses = [source >> 8, source & 0xFF, destination >> 8, destination & 0xFF];
    const scf = 0x10; // CCM encryption, S-A_Data
    final mac = cbcMac(key, [scf], payload: apdu, block0: _block0(seqBytes, addresses, ctrl2, tpci, apdu.length));
    final (secured, macEnc) = ctr(key, [...seqBytes, ...addresses, 0, 0, 0, 0, 1, 0], mac.sublist(0, 4), apdu);
    final secureTpdu = [(tpci << 2) | 0x03, 0xF1, scf, ...seqBytes, ...secured, ...macEnc];
    final npdu = secureTpdu.length - 1;
    return Uint8List.fromList([
      ...cemi.sublist(0, i),
      // More than 15 bytes only fit into an extended frame (Ctrl1 bit 7 = 0).
      npdu > 15 ? cemi[i] & 0x7F : cemi[i],
      ctrl2,
      ...addresses,
      npdu,
      ...secureTpdu,
    ]);
  }
}
