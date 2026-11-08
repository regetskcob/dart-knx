import 'telegram.dart';

/// A group address that usually sends regularly but has gone silent.
class CycleSilence {
  const CycleSilence(this.address, {required this.last, required this.interval});

  /// Group address (raw, 16 bit).
  final int address;

  /// Time of its last telegram.
  final DateTime last;

  /// Usual interval: median of the gaps between its telegrams.
  final Duration interval;

  /// How long it may stay silent before it counts: three times [interval], at
  /// least [cycleMinSilence].
  Duration get limit => cycleLimit(interval);
}

/// Fewest telegrams of an address before its interval counts as known.
const cycleMinTelegrams = 6;

/// Longest median interval that still counts as cyclic.
const cycleMaxInterval = Duration(hours: 6);

/// Shortest silence that is reported, however short the interval.
const cycleMinSilence = Duration(minutes: 15);

/// How long an address with the median [interval] may stay silent.
Duration cycleLimit(Duration interval) => interval * 3 < cycleMinSilence ? cycleMinSilence : interval * 3;

/// Silence rule for cyclic senders: addresses that send regularly according to the
/// history (median interval at most [cycleMaxInterval], at least
/// [cycleMinTelegrams] telegrams) but have now been silent for longer than
/// [cycleLimit].
///
/// [times] maps each group address to the times of the telegrams it sent
/// (microseconds since epoch, any order; the lists are sorted in place). Read
/// requests and the caller's own telegrams must already be left out, see
/// [cycleSilencesOf]. The result keeps the order of [times].
List<CycleSilence> cycleSilences(Map<int, List<int>> times, DateTime now) {
  final result = <CycleSilence>[];
  final nowMicros = now.microsecondsSinceEpoch;
  for (final MapEntry(key: ga, value: list) in times.entries) {
    if (list.length < cycleMinTelegrams) continue;
    list.sort();
    final gaps = [for (var i = 1; i < list.length; i++) list[i] - list[i - 1]]..sort();
    final median = Duration(microseconds: gaps[gaps.length ~/ 2]);
    if (median > cycleMaxInterval || median < const Duration(seconds: 1)) continue;
    final silent = Duration(microseconds: nowMicros - list.last);
    if (silent > cycleLimit(median)) {
      result.add(CycleSilence(ga, last: DateTime.fromMicrosecondsSinceEpoch(list.last), interval: median));
    }
  }
  return result;
}

/// [cycleSilences] over telegrams: only what other devices sent (no read
/// requests, nothing [Telegram.outgoing]).
List<CycleSilence> cycleSilencesOf(Iterable<Telegram> telegrams, DateTime now) {
  final times = <int, List<int>>{};
  for (final t in telegrams) {
    if (t.outgoing || t.type == TelegramType.read) continue;
    (times[t.destination] ??= []).add(t.time.microsecondsSinceEpoch);
  }
  return cycleSilences(times, now);
}
