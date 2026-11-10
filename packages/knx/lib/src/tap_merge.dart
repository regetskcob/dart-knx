import 'hex.dart';
import 'telegram.dart';

/// Merges the telegrams of several tap points of one installation into one stream.
///
/// A telegram forwarded by couplers arrives at several tap points: same source, destination, APCI
/// and payload, a hop count 1 lower per coupler, all within a short [window]. It becomes **one**
/// telegram ([Telegram.tap] = the tap point on the sender's line, [Telegram.sightings] = the
/// others).
///
/// The sender's line is the sighting with the highest hop count: each coupler lowers it by one, so
/// the tap point that saw it unchanged sits on the line it came from. Arrival order does not tell:
/// interfaces report with different latency (a kBerry over UART some 40 ms after a KNX IP
/// interface, measured on 10 Nov 2026), so a telegram can reach a tap point behind a coupler
/// first. With equal hop counts the first sighting wins. The telegram keeps the time of its
/// earliest sighting, so entries stay in order; the earliest tap point, if it is not the sender's,
/// becomes a sighting with offset 0.
///
/// Matching is in order: per tap point a telegram joins the oldest open entry with the same content
/// that this tap point has not contributed to yet. Real installations send identical telegrams in
/// quick succession (read request and response twice, 5 to 47 ms apart, measured on 6 Nov 2026);
/// merging by content alone would swallow them. Repeats ([Telegram.repeated]) never merge with the
/// original. Sent telegrams (L_Data.con) merge with what other tap points see of them.
///
/// Pure and clock-free: [add] takes the telegram with its receive time, [flush] releases entries
/// whose window has passed. Entries leave in order of their first sighting. With a single active
/// tap point ([taps] ≤ 1) and nothing pending, [add] passes telegrams through at once.
class TapMerger {
  TapMerger({this.window = defaultWindow, Map<int, Duration>? windows, this.taps = 1}) : windows = windows ?? {};

  /// 100 ms: within one line the interfaces differed by at most 6.6 ms (6 Nov 2026).
  static const defaultWindow = Duration(milliseconds: 100);

  /// Window for tap points without their own entry in [windows].
  Duration window;

  /// Window per tap point, e.g. for a tap point over VPN with more latency.
  final Map<int, Duration> windows;

  /// Number of tap points currently delivering telegrams. An entry seen at all of them leaves
  /// without waiting for its window.
  int taps;

  final _open = <_Entry>[];

  /// Whether telegrams are waiting for their window.
  bool get pending => _open.isNotEmpty;

  Duration _windowOf(int tap) => windows[tap] ?? window;

  /// The longest window in use: an entry leaves at the latest this long after its first sighting.
  Duration get _longest {
    var w = window;
    for (final v in windows.values) {
      if (v > w) w = v;
    }
    return w;
  }

  /// When the next entry is due ([flush]), `null` if nothing is pending.
  DateTime? get nextDue => _open.isEmpty ? null : _open.first.first.time.add(_longest);

  /// Telegram [t] seen at tap point [tap]. Returns the telegrams that are complete now, in order.
  List<Telegram> add(int tap, Telegram t) {
    if (taps <= 1 && _open.isEmpty) return [t.tap == tap ? t : t.atTap(tap)];
    final key = _keyOf(t);
    for (final e in _open) {
      if (e.key != key || e.taps.contains(tap)) continue;
      final offset = t.time.difference(e.first.time);
      // The wider window of both tap points counts, whichever arrived first (VPN latency).
      final w0 = _windowOf(e.first.tap), w1 = _windowOf(tap);
      if (offset > (w0 > w1 ? w0 : w1) || offset.isNegative) continue;
      e.taps.add(tap);
      e.sightings.add(Sighting(tap, offset, t.hopCount));
      e.seen[tap] = t;
      return _release(t.time, null);
    }
    _open.add(_Entry(key, t.atTap(tap), tap));
    return _release(t.time, null);
  }

  /// Releases the entries whose window has passed at [now].
  List<Telegram> flush(DateTime now) => _release(now, null);

  /// Releases everything (disconnect, shutdown).
  List<Telegram> flushAll() => _release(null, true);

  List<Telegram> _release(DateTime? now, bool? all) {
    final out = <Telegram>[];
    final longest = _longest;
    while (_open.isNotEmpty) {
      final e = _open.first;
      final complete = e.taps.length >= taps;
      final due = now != null && !now.isBefore(e.first.time.add(longest));
      if (!(all == true || complete || due)) break;
      _open.removeAt(0);
      out.add(_settle(e));
    }
    return out;
  }

  /// The merged telegram of [e]: from the tap point with the highest hop count (the sender's
  /// line), at the time of the earliest sighting.
  static Telegram _settle(_Entry e) {
    if (e.sightings.isEmpty) return e.first;
    var origin = e.first.tap;
    var hop = e.first.hopCount;
    for (final s in e.sightings) {
      if (s.hopCount > hop) {
        origin = s.tap;
        hop = s.hopCount;
      }
    }
    if (origin == e.first.tap) return e.first.atTap(origin, sightings: List.unmodifiable(e.sightings));
    return e.seen[origin]!.atTap(
      origin,
      time: e.first.time,
      sightings: List.unmodifiable([
        Sighting(e.first.tap, Duration.zero, e.first.hopCount),
        for (final s in e.sightings)
          if (s.tap != origin) s,
      ]),
    );
  }

  static String _keyOf(Telegram t) =>
      '${t.source}|${t.destination}|${t.type.index}|${t.isSmall ? 1 : 0}|${t.repeated ? 1 : 0}|${hexOf(t.data)}';
}

class _Entry {
  _Entry(this.key, this.first, int tap) : taps = {tap};
  final String key;
  final Telegram first;
  final Set<int> taps;
  final sightings = <Sighting>[];

  /// The telegram as each further tap point saw it (its own hop count and frame).
  final seen = <int, Telegram>{};
}
