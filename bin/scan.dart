// Skaner rynku: co 5 minut (GitHub Actions) liczy sygnały analizy falowej dla walorów z universe.txt
// i zapisuje zmiany do signals.json. Tylko publiczne dane rynkowe - żadnych danych użytkownika.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rynek_skaner/wave_analysis.dart';

const _names = {
  Signal.kup: 'kup',
  Signal.obserwuj: 'obserwuj',
  Signal.czekaj: 'czekaj',
  Signal.nieKupuj: 'nie',
  Signal.ostrzezenie: 'uwaga',
};

/// Czy giełda waloru jest teraz otwarta (UTC, z zapasem na czas letni/zimowy).
bool marketOpen(String s, DateTime now) {
  if (s.endsWith('-USD')) return true; // krypto całą dobę
  if (now.weekday > 5) return false;
  final m = now.hour * 60 + now.minute;
  if (s.endsWith('.WA')) return m >= 6 * 60 + 55 && m <= 16 * 60 + 15;
  if (s.endsWith('.DE') || s == '^GDAXI') return m >= 6 * 60 + 55 && m <= 16 * 60 + 40;
  return m >= 13 * 60 + 25 && m <= 21 * 60 + 10; // USA i kontrakty
}

final _client = HttpClient()..userAgent = 'Mozilla/5.0';

Future<({String name, List<Candle> candles})?> fetch(String s) async {
  try {
    final uri = Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/${Uri.encodeComponent(s)}?range=2y&interval=1d');
    final req = await _client.getUrl(uri).timeout(const Duration(seconds: 20));
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      await res.drain<void>();
      return null;
    }
    final j = jsonDecode(await res.transform(utf8.decoder).join());
    final r = j['chart']['result'][0];
    final q = r['indicators']['quote'][0];
    final t = r['timestamp'] as List;
    final cs = <Candle>[];
    for (var k = 0; k < t.length; k++) {
      final v = [q['open'][k], q['high'][k], q['low'][k], q['close'][k]];
      if (v.any((x) => x == null || (x as num) <= 0)) continue;
      cs.add(Candle(DateTime.fromMillisecondsSinceEpoch((t[k] as num).toInt() * 1000, isUtc: true), (v[0] as num).toDouble(),
          (v[1] as num).toDouble(), (v[2] as num).toDouble(), (v[3] as num).toDouble(), ((q['volume']?[k] as num?) ?? 0).toDouble()));
    }
    return (name: '${r['meta']['shortName'] ?? r['meta']['longName'] ?? s}', candles: cs);
  } catch (_) {
    return null;
  }
}

Future<void> main(List<String> args) async {
  final all = args.contains('--all');
  final now = DateTime.now().toUtc();
  final today = now.toIso8601String().substring(0, 10);
  final universe = File('universe.txt').readAsLinesSync().map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#')).toList();
  final f = File('signals.json');
  final prev = f.existsSync() ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic> : <String, dynamic>{};
  final sig = Map<String, String>.from(prev['sig'] ?? {});
  final seen = Map<String, String>.from(prev['seen'] ?? {});
  final lastEv = Map<String, String>.from(prev['last'] ?? {});
  final events = [for (final e in prev['events'] ?? []) Map<String, dynamic>.from(e)];
  var nextId = (prev['nextId'] as num?)?.toInt() ?? 1;

  // otwarte rynki + raz dziennie wszystko (sygnał z zamknięcia)
  final todo = [for (final s in universe) if (all || marketOpen(s, now) || seen[s] != today) s];
  stdout.writeln('Skanuję ${todo.length} z ${universe.length}');
  final added = <Map<String, dynamic>>[];
  var ok = 0, i = 0;
  Future<void> worker() async {
    while (i < todo.length) {
      final s = todo[i++];
      final d = await fetch(s);
      if (d == null || d.candles.length < 120) continue;
      ok++;
      final a = analyze(d.candles);
      final now2 = _names[a.signal]!;
      final was = sig[s];
      sig[s] = now2;
      seen[s] = today;
      if (was == null || was == now2) continue;
      final good = {'kup', 'obserwuj', 'czekaj'};
      String? t;
      if (now2 == 'kup') t = 'kup';
      if (good.contains(was) && (now2 == 'nie' || now2 == 'uwaga')) t = 'neg';
      if ((was == 'nie' || was == 'uwaga') && good.contains(now2)) t = 'pos';
      if (t == null) continue;
      // bez powtórek tego samego zdarzenia w ciągu doby (sygnał z niezamkniętej świecy potrafi „mrugać”)
      final key = '$s|$t';
      final prevAt = lastEv[key] == null ? null : DateTime.parse(lastEv[key]!);
      if (prevAt != null && now.difference(prevAt).inHours < 24) continue;
      lastEv[key] = now.toIso8601String();
      final why = switch (now2) {
        'uwaga' => 'wypadek z klina',
        'nie' => a.headline.startsWith('Trend spadkowy') ? 'trend spadkowy' : 'scenariusz zanegowany',
        _ => a.signal == Signal.kup ? 'korekta A-B-C + impuls' : 'poprawa',
      };
      added.add({'id': nextId++, 'at': now.toIso8601String(), 's': s, 'n': d.name, 't': t, 'why': why, 'p': d.candles.last.c, 'h': a.headline});
    }
  }

  await Future.wait([for (var k = 0; k < 8; k++) worker()]);
  _client.close(force: true);
  events.addAll(added);
  if (events.length > 300) events.removeRange(0, events.length - 300);
  stdout.writeln('Przeanalizowano $ok, nowych zdarzeń: ${added.length}');
  for (final e in added) {
    stdout.writeln('  ${e['t']} ${e['s']} (${e['why']})');
  }
  final out = {
    'updated': now.toIso8601String(),
    'nextId': nextId,
    'events': events,
    'sig': sig,
    'seen': seen,
    'last': lastEv,
  };
  // plik zmieniamy tylko, gdy coś istotnego się zmieniło - mniej commitów
  final changed = added.isNotEmpty || jsonEncode(prev['sig']) != jsonEncode(sig) || jsonEncode(prev['seen']) != jsonEncode(seen);
  if (changed) f.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
  File(Platform.environment['GITHUB_OUTPUT'] ?? '/dev/null').writeAsStringSync('events=${added.length}\n', mode: FileMode.append);
}
