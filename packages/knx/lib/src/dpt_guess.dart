import 'dart:typed_data';

import 'dpt.dart';
import 'telegram.dart';

/// Guessed datapoint type of a group address without a project.
///
/// Based purely on overheard telegrams (length, value range) and possibly the name someone
/// assigned. For learning without an ETS project, plain-text display and later the survey of
/// foreign installations.
class DptGuess {
  const DptGuess(this.dpt, {this.fromName = false});

  final Dpt dpt;

  /// The name determined the subtype (e.g. "Temperatur" → 9.001).
  final bool fromName;

  @override
  String toString() => '$dpt${fromName ? ' (Name)' : ''}';
}

/// Guesses the DPT from [samples] (read telegrams do not count). [name] refines the subtype, e.g.
/// "Rollladen" → 1.008, "Temperatur" → 9.001. `null` if there is no value among them.
DptGuess? guessDpt(Iterable<Telegram> samples, {String? name}) {
  final values = [
    for (final t in samples)
      if (t.type != TelegramType.read) t,
  ];
  if (values.isEmpty) return null;
  final hint = _hint(name);

  if (values.every((t) => t.isSmall)) {
    final max = values.map((t) => t.data.isEmpty ? 0 : t.data[0]).reduce((a, b) => a > b ? a : b);
    if (max > 1) return DptGuess(Dpt(3, hint == _Hint.blind ? 8 : 7), fromName: hint == _Hint.blind);
    final sub = switch (hint) {
      _Hint.blind => 8,
      _Hint.window => 19,
      _Hint.alarm => 5,
      _Hint.presence => 18,
      _ => null,
    };
    return DptGuess(Dpt(1, sub ?? 1), fromName: sub != null);
  }

  // The longest length counts: mixed lengths are a finding, not a type.
  final length = values.map((t) => t.isSmall ? 0 : t.data.length).reduce((a, b) => a > b ? a : b);
  final last = values.lastWhere((t) => !t.isSmall && t.data.length == length).data;
  switch (length) {
    case 1:
      return switch (hint) {
        _Hint.scene => const DptGuess(Dpt(17, 1), fromName: true),
        _Hint.hvac => const DptGuess(Dpt(20, 102), fromName: true),
        _Hint.angle => const DptGuess(Dpt(5, 3), fromName: true),
        _Hint.counter => const DptGuess(Dpt(5, 10), fromName: true),
        _ => const DptGuess(Dpt(5, 1)),
      };
    case 2:
      final sub = switch (hint) {
        _Hint.temperature => 1,
        _Hint.lux => 4,
        _Hint.wind => 5,
        _Hint.humidity => 7,
        _Hint.co2 => 8,
        _Hint.power => 24,
        _ => null,
      };
      return DptGuess(Dpt(9, sub), fromName: sub != null);
    case 3:
      return DptGuess(_threeBytes(last, values.last.time.year));
    case 4:
      final f = ByteData.sublistView(last).getFloat32(0);
      final plausibleFloat = f.isFinite && (f == 0 || (f.abs() > 1e-4 && f.abs() < 1e8));
      if (hint == _Hint.energy) return const DptGuess(Dpt(13, 13), fromName: true);
      if (plausibleFloat) {
        return hint == _Hint.power ? const DptGuess(Dpt(14, 56), fromName: true) : const DptGuess(Dpt(14));
      }
      return const DptGuess(Dpt(12, 1));
    case 8:
      return const DptGuess(Dpt(19, 1));
    case 14:
      return const DptGuess(Dpt(16, 0));
  }
  return null;
}

/// Types that match a payload length (0 = ≤ 6 bit), for the selection while learning. The guessed
/// type comes first.
List<Dpt> dptCandidates(int length) => switch (length) {
  0 => const [Dpt(1, 1), Dpt(1, 8), Dpt(1, 9), Dpt(1, 19), Dpt(1, 18), Dpt(1, 5), Dpt(1, 3), Dpt(3, 7), Dpt(3, 8)],
  1 => const [Dpt(5, 1), Dpt(5, 10), Dpt(5, 3), Dpt(17, 1), Dpt(18, 1), Dpt(20, 102), Dpt(6, 10)],
  2 => const [Dpt(9, 1), Dpt(9, 7), Dpt(9, 4), Dpt(9, 5), Dpt(9, 8), Dpt(9, 24), Dpt(7, 1), Dpt(8, 1)],
  3 => const [Dpt(10, 1), Dpt(11, 1), Dpt(232, 600)],
  4 => const [Dpt(14, 56), Dpt(14, 68), Dpt(13, 13), Dpt(13, 10), Dpt(12, 1)],
  8 => const [Dpt(19, 1)],
  14 => const [Dpt(16, 0)],
  _ => const [],
};

/// Payload length of a telegram as in [dptCandidates].
int payloadLength(Telegram t) => t.isSmall ? 0 : t.data.length;

/// 3 bytes: date if the year matches the reception time, otherwise time of day, otherwise colour.
Dpt _threeBytes(List<int> d, int year) {
  final date = d[0] >= 1 && d[0] <= 31 && d[1] >= 1 && d[1] <= 12 && d[2] < 100;
  if (date && (d[2] - year % 100).abs() <= 1) return const Dpt(11, 1);
  if ((d[0] & 0x1F) < 24 && d[1] < 60 && d[2] < 60) return const Dpt(10, 1);
  return const Dpt(232, 600);
}

enum _Hint {
  blind,
  window,
  alarm,
  presence,
  scene,
  hvac,
  angle,
  counter,
  temperature,
  lux,
  wind,
  humidity,
  co2,
  power,
  energy,
}

/// Keywords in the name (German and English, lowercase).
const _words = {
  _Hint.blind: [
    'rollladen',
    'rolladen',
    'jalousie',
    'raffstore',
    'markise',
    'shutter',
    'blind',
    'awning',
    'auf/ab',
    'up/down',
  ],
  _Hint.window: ['fenster', 'window', 'kontakt', 'contact', 'tür', 'door'],
  _Hint.alarm: ['alarm', 'rauch', 'smoke', 'störung', 'fault'],
  _Hint.presence: ['präsenz', 'praesenz', 'bewegung', 'presence', 'motion', 'occupancy'],
  _Hint.scene: ['szene', 'scene'],
  _Hint.hvac: ['betriebsart', 'betriebsmodus', 'hvac', 'operating mode'],
  _Hint.angle: ['lamelle', 'winkel', 'slat', 'angle'],
  _Hint.counter: ['zähler', 'counter'],
  _Hint.temperature: ['temp', 'soll', 'setpoint'],
  _Hint.lux: ['lux', 'helligkeit', 'brightness', 'illuminance'],
  _Hint.wind: ['wind'],
  _Hint.humidity: ['feuchte', 'feuchtigkeit', 'humid'],
  _Hint.co2: ['co2', 'co₂', 'luftqualität', 'air quality'],
  _Hint.power: ['leistung', 'power', 'watt'],
  _Hint.energy: ['energie', 'verbrauch', 'kwh', 'energy', 'meter'],
};

_Hint? _hint(String? name) {
  if (name == null || name.trim().isEmpty) return null;
  final n = name.toLowerCase();
  // Energy before power and counter: "Energiezähler" (energy meter) is energy.
  for (final h in [_Hint.energy, ..._Hint.values.where((h) => h != _Hint.energy)]) {
    if (_words[h]!.any(n.contains)) return h;
  }
  return null;
}
