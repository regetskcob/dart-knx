import 'dart:typed_data';

import 'address.dart';
import 'hex.dart';

/// Kind of group telegram (APCI).
enum TelegramType { read, response, write }

/// Telegram priority (cEMI Ctrl1 bits 3–2).
enum TelegramPriority { system, normal, urgent, low }

/// One more place where the same telegram was seen (tap points): tap point [tap], [offset]
/// after the first sighting (the telegram's own time), with the hop count there.
class Sighting {
  const Sighting(this.tap, this.offset, this.hopCount);

  /// Number of the tap point (0 = the first one of the installation).
  final int tap;

  /// Time after the first sighting.
  final Duration offset;

  /// Routing counter at this tap point (6 directly from the sender, 1 less per coupler).
  final int hopCount;

  List<int> toJson() => [tap, offset.inMicroseconds, hopCount];

  static Sighting? fromJson(Object? j) {
    if (j is! List || j.length < 3) return null;
    final [tap, offset, hop, ...] = j;
    if (tap is! int || offset is! int || hop is! int) return null;
    return Sighting(tap, Duration(microseconds: offset), hop);
  }

  @override
  bool operator ==(Object other) =>
      other is Sighting && other.tap == tap && other.offset == offset && other.hopCount == hopCount;

  @override
  int get hashCode => Object.hash(tap, offset, hopCount);
}

/// A KNX group telegram: received (L_Data.ind) or confirmed for one we sent (L_Data.con).
///
/// Its JSON form ([toJson], [Telegram.fromJson]) is a compact line format for recordings (one JSON
/// object per line).
class Telegram {
  const Telegram({
    required this.time,
    required this.source,
    required this.destination,
    required this.type,
    required this.data,
    required this.isSmall,
    this.outgoing = false,
    this.priority = TelegramPriority.low,
    this.repeated = false,
    this.hopCount = 6,
    this.confirmError = false,
    this.tap = 0,
    this.sightings = const [],
    Uint8List? raw,
  }) : raw = raw ?? const [];

  final DateTime time;

  /// Individual address of the sender (raw, 16 bit).
  final int source;

  /// Group address (raw, 16 bit).
  final int destination;

  final TelegramType type;

  /// Payload. With [isSmall] exactly one byte with the 6-bit value.
  final Uint8List data;

  /// Whether the value sits directly in the APCI byte (≤ 6 bit, e.g. DPT 1).
  final bool isSmall;

  /// Whether we sent it ourselves (confirmation L_Data.con from the gateway).
  final bool outgoing;

  /// Complete cEMI frame.
  final List<int> raw;

  final TelegramPriority priority;

  /// Whether the telegram is repeated – the first attempt was not acknowledged.
  final bool repeated;

  /// Routing counter: 6 directly from the sender, each coupler subtracts 1, 7 = unlimited.
  final int hopCount;

  /// Only for telegrams we sent (L_Data.con): the bus did not acknowledge.
  final bool confirmError;

  /// Tap point where the telegram was seen first; 0 = the first tap point of the
  /// installation, which is also what every telegram without the field means.
  final int tap;

  /// Further tap points that saw the same telegram, in order of arrival. Empty with a single tap
  /// point. [Sighting.offset] counts from [time], the earliest sighting.
  final List<Sighting> sightings;

  /// All tap points that saw the telegram, [tap] first.
  Iterable<int> get taps sync* {
    yield tap;
    for (final s in sightings) {
      yield s.tap;
    }
  }

  /// The same telegram from tap point [tap] and with [sightings] (merging, see TapMerger), at
  /// [time] if given.
  Telegram atTap(int tap, {List<Sighting> sightings = const [], DateTime? time}) => Telegram(
    time: time ?? this.time,
    source: source,
    destination: destination,
    type: type,
    data: data,
    isSmall: isSmall,
    outgoing: outgoing,
    priority: priority,
    repeated: repeated,
    hopCount: hopCount,
    confirmError: confirmError,
    tap: tap,
    sightings: sightings,
    raw: raw is Uint8List ? raw as Uint8List : Uint8List.fromList(raw),
  );

  /// Whether the routing counter differs from 6 (passed a coupler, or a special case).
  bool get unusualHop => hopCount != 6;

  /// Sender as "1.1.5".
  String get sourceText => formatIndividual(source);

  /// The same telegram with a different value ([small] ≤ 6 bit or [data]), e.g. when editing a
  /// recording. The raw frame is dropped.
  Telegram withValue({int? small, List<int> data = const []}) => Telegram(
    time: time,
    source: source,
    destination: destination,
    type: type,
    data: Uint8List.fromList(small != null ? [small] : data),
    isSmall: small != null,
    outgoing: outgoing,
    priority: priority,
    repeated: repeated,
    hopCount: hopCount,
    tap: tap,
    sightings: sightings,
  );

  Map<String, Object?> toJson() => {
    't': time.microsecondsSinceEpoch,
    's': source,
    'd': destination,
    'y': type.index,
    'x': hexOf(data),
    if (isSmall) 'm': true,
    if (outgoing) 'o': true,
    if (priority != TelegramPriority.low) 'p': priority.index,
    if (repeated) 'rp': true,
    if (hopCount != 6) 'h': hopCount,
    if (confirmError) 'ce': true,
    if (raw.isNotEmpty) 'r': hexOf(raw),
    if (tap != 0) 'tp': tap,
    if (sightings.isNotEmpty) 'sg': [for (final s in sightings) s.toJson()],
  };

  factory Telegram.fromJson(Map<String, Object?> j) => Telegram(
    time: DateTime.fromMicrosecondsSinceEpoch(j['t']! as int),
    source: j['s']! as int,
    destination: j['d']! as int,
    type: TelegramType.values[j['y']! as int],
    data: Uint8List.fromList(parseHex(j['x']! as String) ?? const []),
    isSmall: j['m'] == true,
    outgoing: j['o'] == true,
    priority: TelegramPriority.values[j['p'] as int? ?? TelegramPriority.low.index],
    repeated: j['rp'] == true,
    hopCount: j['h'] as int? ?? 6,
    confirmError: j['ce'] == true,
    raw: j['r'] == null ? null : Uint8List.fromList(parseHex(j['r']! as String) ?? const []),
    tap: j['tp'] is int ? j['tp']! as int : 0,
    sightings: j['sg'] is List ? [for (final s in j['sg']! as List) ?Sighting.fromJson(s)] : const [],
  );

  /// Parses a cEMI frame. Returns `null` for anything that is not a group telegram (L_Data.ind /
  /// L_Data.con with A_GroupValue_Read, _Response or _Write).
  static Telegram? fromCemi(Uint8List c, {DateTime? time}) {
    if (c.length < 2) return null;
    final code = c[0];
    if (code != 0x29 && code != 0x2E) return null;
    final i = 2 + c[1];
    if (c.length < i + 9) return null;

    final ctrl2 = c[i + 1];
    if (ctrl2 & 0x80 == 0) return null; // not a group address

    final source = (c[i + 2] << 8) | c[i + 3];
    final destination = (c[i + 4] << 8) | c[i + 5];
    final npduLength = c[i + 6];
    final apci = ((c[i + 7] & 0x03) << 8) | c[i + 8];

    final type = switch (apci & 0x3C0) {
      0x000 => TelegramType.read,
      0x040 => TelegramType.response,
      0x080 => TelegramType.write,
      _ => null,
    };
    if (type == null) return null;

    final isSmall = npduLength <= 1;
    final Uint8List data;
    if (isSmall) {
      data = Uint8List.fromList([c[i + 8] & 0x3F]);
    } else {
      final end = (i + 8 + npduLength).clamp(i + 9, c.length);
      data = Uint8List.fromList(c.sublist(i + 9, end));
    }

    return Telegram(
      time: time ?? DateTime.now(),
      source: source,
      destination: destination,
      type: type,
      data: data,
      isSmall: isSmall,
      outgoing: code == 0x2E,
      priority: TelegramPriority.values[(c[i] >> 2) & 0x03],
      // cEMI: bit 5 = 0 in L_Data.ind means "repeated".
      repeated: code == 0x29 && c[i] & 0x20 == 0,
      hopCount: (ctrl2 >> 4) & 0x07,
      confirmError: code == 0x2E && c[i] & 0x01 != 0,
      raw: Uint8List.fromList(c),
    );
  }
}

/// Builds a cEMI L_Data.req for a group telegram.
///
/// [small] = value (0–63) directly in the APCI byte; otherwise [data] as payload.
Uint8List buildGroupRequest(int destination, TelegramType type, {List<int> data = const [], int? small}) {
  final apci = switch (type) {
    TelegramType.read => 0x00,
    TelegramType.response => 0x40,
    TelegramType.write => 0x80,
  };
  final inline = type == TelegramType.read || small != null;
  return Uint8List.fromList([
    0x11, 0x00, // L_Data.req, no additional info
    0xBC, 0xE0, // standard frame, group address, hop count 6
    0x00, 0x00, // source: set by the gateway
    destination >> 8, destination & 0xFF,
    inline ? 1 : 1 + data.length,
    0x00,
    apci | (inline ? (small ?? 0) & 0x3F : 0),
    if (!inline) ...data,
  ]);
}
