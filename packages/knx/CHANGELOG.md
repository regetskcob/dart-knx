# Changelog

## 0.2.3

- `TapMerger`: the merged telegram comes from the tap point on the sender's line, the sighting
  with the highest hop count, not from the one that reported first. Interfaces report with
  different latency (a kBerry over UART some 40 ms after a KNX IP interface), so a telegram
  could reach a tap point behind a coupler first. The time stays that of the earliest sighting;
  the earliest tap point becomes a sighting with offset 0. Equal hop counts keep the first.
- `Telegram.atTap` takes an optional `time`.

## 0.2.2

- `cycleSilences`: addresses that send in bursts (dimming, blinds status while moving,
  switching with feedback) no longer count as cyclic. An address must have sent in its own
  rhythm for at least an hour and for half its history (or two days in all), see
  `cycleMinCovered` and `cycleEnoughCovered`.

## 0.2.1

- Shorter package description (pub.dev limit), analysis with `package:lints/recommended`.

## 0.2.0

- First public release, BSD 3-Clause.
- New: `guessDpt` and `dptCandidates` guess the datapoint type of a group address from
  overheard telegrams and its name.

## 0.1.0 (internal)

- Taken out of the Busclear app and its Home Assistant add-on server: addresses, cEMI, group
  telegrams, KNXnet/IP headers, datapoint types, KNX Secure, cycle silence rule.
