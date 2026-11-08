import 'package:knx/knx.dart';
import 'package:knx_io/knx_io.dart';

/// Connects to a KNXnet/IP gateway (or, with `--kberry`, to a kBerry on
/// /dev/ttyAMA0) and prints every group telegram.
Future<void> main(List<String> args) async {
  final BusLink link = args.contains('--kberry')
      ? Ft12CemiLink(open: (baud) => TtyLine.open('/dev/ttyAMA0', baud))
      : KnxIpTunnel(host: args.isEmpty ? '192.168.1.10' : args.first);
  link.frames.listen((cemi) {
    final t = Telegram.fromCemi(cemi);
    if (t != null) print('${formatIndividual(t.source)} → ${formatGroupAddress(t.destination)} ${hexOf(t.data)}');
  });
  await link.connect();
  print('connected: ${link.label}');
  print('lost: ${await link.lost}');
}
