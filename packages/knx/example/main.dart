import 'package:knx/knx.dart';

void main() {
  final ga = parseGroupAddress('1/2/3', GroupStyle.threeLevel)!;
  // L_Data.req: switch on (DPT 1.001) to 1/2/3.
  final cemi = buildGroupRequest(ga, TelegramType.write, small: 1);
  print(hexOf(cemi));
}
