import 'dart:typed_data';

/// KNXnet/IP service type identifiers (Core, Tunnelling, Routing, Secure).
abstract final class KnxIpService {
  static const searchRequest = 0x0201;
  static const descriptionRequest = 0x0203;
  static const descriptionResponse = 0x0204;
  static const connectRequest = 0x0205;
  static const connectResponse = 0x0206;
  static const stateRequest = 0x0207;
  static const stateResponse = 0x0208;
  static const disconnectRequest = 0x0209;
  static const disconnectResponse = 0x020A;
  static const tunnelRequest = 0x0420;
  static const tunnelAck = 0x0421;
  static const routingIndication = 0x0530;
  static const routingLost = 0x0531;
  static const routingBusy = 0x0532;
  static const secureWrapper = 0x0950;
  static const sessionRequest = 0x0951;
  static const sessionResponse = 0x0952;
  static const sessionAuthenticate = 0x0953;
  static const sessionStatus = 0x0954;
  static const timerNotify = 0x0955;
}

/// Status codes from CONNECT_RESPONSE and CONNECTIONSTATE_RESPONSE.
abstract final class KnxIpStatus {
  static const ok = 0x00;
  static const connectionId = 0x21;
  static const connectionType = 0x22;
  static const connectionOption = 0x23;
  static const noMoreConnections = 0x24;
  static const noMoreUniqueConnections = 0x25;
  static const dataConnection = 0x26;
  static const knxConnection = 0x27;
  static const authorisation = 0x28;
  static const tunnellingLayer = 0x29;
  static const noTunnellingAddress = 0x2D;
  static const connectionInUse = 0x2E;
}

/// KNXnet/IP frame with header (06 10 …).
Uint8List knxFrame(int service, List<int> body) {
  final len = 6 + body.length;
  return Uint8List.fromList([0x06, 0x10, service >> 8, service & 0xFF, len >> 8, len & 0xFF, ...body]);
}

/// Service type of a frame, `null` if there is no valid KNXnet/IP header.
int? serviceOf(List<int> p) {
  if (p.length < 6 || p[0] != 0x06 || p[1] != 0x10) return null;
  return (p[2] << 8) | p[3];
}

/// HPAI "0.0.0.0:0": the gateway replies to the sender address (NAT mode).
const hpaiUdpNat = [0x08, 0x01, 0, 0, 0, 0, 0, 0];

/// HPAI for TCP: address and port are always 0.
const hpaiTcp = [0x08, 0x02, 0, 0, 0, 0, 0, 0];

/// Connection Request Information for a link layer tunnel; with [address] as
/// "Extended CRI" (Tunnelling v2, fixed tunnel address).
List<int> tunnelCri({int? address}) => [
  address == null ? 4 : 6,
  0x04, // tunnel connection
  0x02, // Link Layer
  0x00,
  if (address != null) ...[address >> 8, address & 0xFF],
];
