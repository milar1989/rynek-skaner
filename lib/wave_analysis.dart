import 'dart:math';

/// Automatyczna analiza wykresu w duchu analizy falowej (Elliott) na skali logarytmicznej:
/// impuls 5 fal → korekta ABC → strefy z kilku narzędzi (Fibonacci, dołek fali 4, zasięgi fali C)
/// → zakup dopiero po korekcie trójfalowej i potwierdzeniu impulsem; ostrzeżenie przy wypadnięciu z klina.
/// To algorytm (mechaniczne reguły), nie człowiek - dlatego każdy wynik ma test na historii.

class Candle {
  final DateTime t;
  final double o, h, l, c;
  final double v; // wolumen (0 = brak danych, np. część indeksów)
  const Candle(this.t, this.o, this.h, this.l, this.c, [this.v = 0]);
}

/// Punkt zwrotny (szczyt / dołek). [confirmed] = false dla ostatniego, jeszcze trwającego ruchu.
class Pivot {
  final int i;
  final double price;
  final bool high;
  final bool confirmed;
  String label = '';
  Pivot(this.i, this.price, this.high, {this.confirmed = true});
}

double _ln(double x) => log(x);

/// ZigZag na skali logarytmicznej: nowy punkt zwrotny dopiero po ruchu powrotnym o [pct] (np. 0.08 = 8%).
List<Pivot> zigzag(List<Candle> cs, double pct, {int from = 0}) {
  if (cs.length - from < 3) return [];
  final th = _ln(1 + pct);
  final out = <Pivot>[];
  var hi = cs[from].h, lo = cs[from].l;
  var hiI = from, loI = from;
  var dir = 0; // 1: trwa wzrost (szukam szczytu), -1: trwa spadek
  for (var i = from + 1; i < cs.length; i++) {
    final c = cs[i];
    if (dir == 0) {
      if (c.h > hi) (hi, hiI) = (c.h, i);
      if (c.l < lo) (lo, loI) = (c.l, i);
      if (_ln(hi / lo) >= th) {
        if (hiI > loI) {
          out.add(Pivot(loI, lo, false));
          dir = 1;
        } else {
          out.add(Pivot(hiI, hi, true));
          dir = -1;
        }
      }
    } else if (dir == 1) {
      if (c.h >= hi) {
        (hi, hiI) = (c.h, i);
      } else if (_ln(hi / c.l) >= th) {
        out.add(Pivot(hiI, hi, true));
        dir = -1;
        (lo, loI) = (c.l, i);
      }
    } else {
      if (c.l <= lo) {
        (lo, loI) = (c.l, i);
      } else if (_ln(c.h / lo) >= th) {
        out.add(Pivot(loI, lo, false));
        dir = 1;
        (hi, hiI) = (c.h, i);
      }
    }
  }
  if (dir == 1) out.add(Pivot(hiI, hi, true, confirmed: false));
  if (dir == -1) out.add(Pivot(loI, lo, false, confirmed: false));
  return out;
}

const _steps = [0.02, 0.03, 0.04, 0.05, 0.065, 0.08, 0.1, 0.13, 0.16, 0.2, 0.25, 0.32, 0.4, 0.5, 0.65];

/// Dobiera próg ZigZag tak, żeby na wykresie było najwyżej [target] punktów zwrotnych (stopień fal „duży”).
(List<Pivot>, double) pivotsFor(List<Candle> cs, {int target = 14}) {
  var best = (<Pivot>[], _steps.first);
  for (final s in _steps) {
    final p = zigzag(cs, s);
    best = (p, s);
    if (p.length <= target) break;
  }
  return best;
}

/// Impuls 5 fal z 6 punktów (start + koniec fal 1..5). Reguły: 2 nie znosi całej 1, 3 nie jest najkrótsza,
/// 3 i 5 robią nowe ekstrema, 4 nie wchodzi na terytorium 1 - chyba że to klin (diagonal) o zbieżnych liniach.
({bool ok, bool diagonal}) checkImpulse(List<Pivot> p) {
  const no = (ok: false, diagonal: false);
  if (p.length != 6) return no;
  final s = p[0].high ? -1.0 : 1.0;
  double v(int k) => s * _ln(p[k].price);
  final w1 = v(1) - v(0), w2 = v(1) - v(2), w3 = v(3) - v(2), w4 = v(3) - v(4), w5 = v(5) - v(4);
  if ([w1, w2, w3, w4, w5].any((w) => w <= 0)) return no;
  if (w2 >= w1 || v(3) <= v(1) || v(5) <= v(3)) return no;
  if (w3 < w1 && w3 < w5) return no;
  if (v(4) > v(1)) return (ok: true, diagonal: false);
  // zachodzenie fali 4 na 1: dopuszczalne tylko w klinie - linia dołków (2-4) rośnie szybciej niż linia szczytów (1-3)
  final up = (v(3) - v(1)) / (p[3].i - p[1].i), lowSlope = (v(4) - v(2)) / (p[4].i - p[2].i);
  if (v(4) > v(2) && lowSlope > up) return (ok: true, diagonal: true);
  return no;
}

/// Linia w przestrzeni (indeks świecy, log ceny).
class TrendLine {
  final int i1, i2;
  final double p1, p2;
  const TrendLine(this.i1, this.p1, this.i2, this.p2);
  double at(num i) => exp(_ln(p1) + (_ln(p2) - _ln(p1)) * (i - i1) / (i2 - i1));
}

/// Klin wzrostowy (diagonal kończący): zbieżne linie szczytów i dołków. [broken] = zamknięcie pod dolną linią.
class Wedge {
  final TrendLine upper, lower;
  final bool broken;
  const Wedge(this.upper, this.lower, this.broken);
}

class Zone {
  final double lo, hi;
  final List<String> tools;
  const Zone(this.lo, this.hi, this.tools);
  double get mid => sqrt(lo * hi);
  int get score => {for (final t in tools) t.split(' ').first}.length;
  bool contains(double p) => p >= lo * 0.995 && p <= hi * 1.005;
}

enum Signal { kup, obserwuj, czekaj, nieKupuj, ostrzezenie }

class Scenario {
  final String name;
  final String text;
  final bool bullish;
  final List<(num, double)> path; // (indeks świecy, cena); indeksy > ostatniej świecy = przyszłość
  const Scenario(this.name, this.text, this.bullish, this.path);
}

class Check {
  final bool ok;
  final String text;
  const Check(this.ok, this.text);
}

class Analysis {
  final List<Candle> candles;
  final List<Pivot> pivots;
  final double degree; // próg ZigZag
  final String trend;
  final Signal signal;
  final String headline;
  final List<Check> checks;
  final List<Zone> zones;
  final Wedge? wedge;
  final List<Scenario> scenarios;
  final double? entry, stop, tp1, tp2;
  final int sizePct;
  final List<Pivot> confirmPivots;
  /// Dodatkowe zgodne narzędzia przy sygnale KUP (RSI, wolumen, wyższy interwał, mocna strefa).
  final List<String> confluence;
  const Analysis({
    required this.candles,
    required this.pivots,
    required this.degree,
    required this.trend,
    required this.signal,
    required this.headline,
    this.checks = const [],
    this.zones = const [],
    this.wedge,
    this.scenarios = const [],
    this.entry,
    this.stop,
    this.tp1,
    this.tp2,
    this.sizePct = 0,
    this.confirmPivots = const [],
    this.confluence = const [],
  });
  double get last => candles.last.c;
}

/// Poziom w skali logarytmicznej: [a] + ratio × ([b] - [a]).
double _lvl(double a, double b, double ratio) => exp(_ln(a) + ratio * (_ln(b) - _ln(a)));

/// Łączy poziomy z różnych narzędzi w strefy (poziomy bliżej niż [gap] w log).
List<Zone> clusterZones(List<(double, String)> levels, {double gap = 0.03}) {
  final sorted = [...levels]..sort((a, b) => a.$1.compareTo(b.$1));
  final zones = <Zone>[];
  var group = <(double, String)>[];
  void flush() {
    if (group.isEmpty) return;
    zones.add(Zone(group.first.$1, group.last.$1, [for (final g in group) g.$2]));
    group = [];
  }

  for (final l in sorted) {
    if (group.isNotEmpty && _ln(l.$1 / group.first.$1) > gap) flush();
    group.add(l);
  }
  flush();
  return zones;
}

/// Klin na szczycie: ostatnie 5 punktów (dołek, szczyt, dołek, szczyt, dołek/szczyt) o rosnących, zbieżnych liniach.
Wedge? findWedge(List<Pivot> piv, List<Candle> cs) {
  for (var e = piv.length - 1; e >= 4 && e >= piv.length - 4; e--) {
    final w = piv.sublist(e - 4, e + 1);
    final highs = w.where((p) => p.high).toList(), lows = w.where((p) => !p.high).toList();
    if (highs.length < 2 || lows.length < 2) continue;
    final h1 = highs[highs.length - 2], h2 = highs.last, l1 = lows[lows.length - 2], l2 = lows.last;
    if (!(h2.price > h1.price && l2.price > l1.price)) continue;
    final su = (_ln(h2.price) - _ln(h1.price)) / (h2.i - h1.i), sl = (_ln(l2.price) - _ln(l1.price)) / (l2.i - l1.i);
    if (sl <= su) continue; // linie muszą się zbiegać
    final upper = TrendLine(h1.i, h1.price, h2.i, h2.price), lower = TrendLine(l1.i, l1.price, l2.i, l2.price);
    final lastI = cs.length - 1;
    // klin aktualny: ostatni szczyt to najwyższy punkt od początku klina
    final top = cs.sublist(w.first.i).map((c) => c.h).reduce(max);
    if (top > h2.price * 1.02) continue;
    return Wedge(upper, lower, cs.last.c < lower.at(lastI));
  }
  return null;
}

/// Potwierdzenie końca korekty na mniejszym stopniu: impuls 5 fal w górę od dołka albo wyższy dołek i wybicie szczytu fali 1.
({bool ok, String how, List<Pivot> piv}) confirmUp(List<Candle> cs, int lowIdx, double degree) {
  final small = zigzag(cs, max(0.012, degree / 6), from: lowIdx);
  if (small.isEmpty || small.first.high) return (ok: false, how: '', piv: small);
  if (small.length >= 6 && checkImpulse(small.sublist(0, 6)).ok) {
    return (ok: true, how: 'impuls 5 fal w górę od dołka', piv: small);
  }
  if (small.length >= 3) {
    final w1 = small[1], w2 = small[2];
    if (!w2.high && w2.price > small[0].price && cs.last.c > w1.price) {
      return (ok: true, how: 'wyższy dołek i wybicie szczytu pierwszej fali (start fali 3)', piv: small);
    }
  }
  return (ok: false, how: '', piv: small);
}

String _p(double v) => v >= 1000 ? v.toStringAsFixed(0) : v >= 10 ? v.toStringAsFixed(2) : v.toStringAsFixed(3);

/// Główna analiza wykresu.
/// Stopień fal: największy, na którym ostatni szczyt kończy czytelny impuls 5 fal; inaczej ~14 punktów zwrotnych.
(List<Pivot>, double) _chooseDegree(List<Candle> cs) {
  for (final s in _steps.reversed) {
    final p = zigzag(cs, s);
    if (p.length < 7 || p.length > 40) continue;
    final recent = p.sublist(max(0, p.length - 10)).where((x) => x.high).toList();
    if (recent.isEmpty) continue;
    final top = recent.reduce((a, b) => a.price > b.price ? a : b);
    final k = p.indexOf(top);
    if (k >= 5 && p.length - k <= 5 && checkImpulse(p.sublist(k - 5, k + 1)).ok) return (p, s);
  }
  return pivotsFor(cs);
}

/// Wielkość pozycji wg liczby dodatkowych zgodnych narzędzi (0, 1, 2, …). Test na 20 walorach 2021-2026 pokazał,
/// że większa zgodność NIE dawała lepszych transakcji, więc domyślnie zawsze pełna pozycja (docs/metoda.md).
const defaultSizeTiers = [100];

/// Kiedy scenariusz korekty uznajemy za zanegowany.
enum Negation {
  /// zejście poniżej 0.886 całego ruchu
  fib886,
  /// zejście poniżej początku ruchu (reguła fali 2)
  start,
  /// korekta płaska nieregularna: C może zejść do 1.618 × A od szczytu B (jak w analizie Karola), najgłębiej do początku ruchu
  flat,
}

/// [minReward] - minimalny zysk do TP1 jako wielokrotność ryzyka (odległości stopu).
Analysis analyze(List<Candle> cs, {double minReward = 1.0, List<int> sizeTiers = defaultSizeTiers, Negation negation = Negation.flat}) {
  final (piv, degree) = _chooseDegree(cs);
  final last = cs.last.c, lastI = cs.length - 1;
  if (piv.length < 4) {
    return Analysis(candles: cs, pivots: piv, degree: degree, trend: 'brak danych', signal: Signal.czekaj, headline: 'Za mało historii do analizy.');
  }
  final conf = piv.where((p) => p.confirmed).toList();
  final highs = conf.where((p) => p.high).toList(), lows = conf.where((p) => !p.high).toList();
  var trend = 'boczny';
  if (highs.length >= 2 && lows.length >= 2) {
    final hh = highs.last.price > highs[highs.length - 2].price, hl = lows.last.price > lows[lows.length - 2].price;
    if (hh && hl) trend = 'wzrostowy';
    if (!hh && !hl) trend = 'spadkowy';
  }

  // 1) szczyt ruchu wzrostowego, który teraz może być korygowany = najwyższy punkt z ostatnich punktów zwrotnych
  final recent = piv.sublist(max(0, piv.length - 10));
  final topP = recent.where((p) => p.high).fold<Pivot?>(null, (a, p) => a == null || p.price > a.price ? p : a);
  if (topP == null) {
    return Analysis(candles: cs, pivots: piv, degree: degree, trend: trend, signal: Signal.czekaj, headline: 'Brak czytelnej struktury.');
  }
  final topK = piv.indexOf(topP);

  // 2) impuls 5 fal kończący się na szczycie (albo przynajmniej ruch od dołka do szczytu)
  var impulse = false, diagonal = false;
  Pivot start;
  Pivot? w4;
  if (topK >= 5 && checkImpulse(piv.sublist(topK - 5, topK + 1)).ok) {
    final r = checkImpulse(piv.sublist(topK - 5, topK + 1));
    impulse = true;
    diagonal = r.diagonal;
    for (var k = 0; k < 6; k++) {
      piv[topK - 5 + k].label = ['0', '1', '2', '3', '4', '5'][k];
    }
    start = piv[topK - 5];
    w4 = piv[topK - 1];
  } else {
    final before = piv.sublist(0, topK).where((p) => !p.high).toList();
    start = before.isEmpty ? piv.first : before.reduce((a, b) => a.price < b.price ? a : b);
  }

  // 3) korekta po szczycie: A, B, C (więcej odcinków = korekta złożona)
  // korekta liczona o stopień niżej niż impuls (jak wewnętrzne struktury na mniejszym interwale)
  final fine = zigzag(cs, max(0.015, degree * 0.5), from: topP.i);
  final corr = [for (final p in fine) if (p.i > topP.i) p];
  piv
    ..removeRange(topK + 1, piv.length)
    ..addAll(corr);
  // korekta trwa do najniższego dołka; to, co po nim, to już odbicie / nowy impuls
  final cLow = corr.where((p) => !p.high).fold<Pivot?>(null, (m, p) => m == null || p.price < m.price ? p : m);
  final legs = cLow == null ? corr : corr.sublist(0, corr.indexOf(cLow) + 1);
  const names = ['A', 'B', 'C', 'X', 'Y', 'Z'];
  for (var k = 0; k < legs.length && k < names.length; k++) {
    legs[k].label = names[k];
  }
  final post = corr.sublist(legs.length);
  for (var k = 0; k < post.length && k < 5; k++) {
    post[k].label = '(${k + 1})';
  }
  final a = legs.isNotEmpty ? legs[0] : null, b = legs.length > 1 ? legs[1] : null;

  // 4) poziomy z kilku narzędzi → strefy
  final levels = <(double, String)>[
    (_lvl(topP.price, start.price, 0.382), 'Fibo 0.382 zniesienia'),
    (_lvl(topP.price, start.price, 0.5), 'Fibo 0.5 zniesienia'),
    (_lvl(topP.price, start.price, 0.618), 'Fibo 0.618 zniesienia'),
    if (w4 != null) (w4.price, 'Dołek fali 4 (wsparcie)'),
  ];
  // wsparcie: ostatni dołek przed szczytem (jeśli to nie fala 4 - ten już jest)
  final lastLow = piv.sublist(0, topK).lastWhere((p) => !p.high, orElse: () => start);
  if (w4 == null && lastLow != start) levels.add((lastLow.price, 'Dołek poprzedniej korekty (wsparcie)'));
  if (a != null && b != null && b.high) {
    final aLen = _ln(topP.price) - _ln(a.price);
    for (final r in [1.0, 1.236, 1.382, 1.618]) {
      levels.add((exp(_ln(b.price) - r * aLen), 'Zasięg C = ${r == 1.0 ? '1' : r} × A'));
    }
    if (b.price > topP.price) {
      final bLen = _ln(b.price) - _ln(a.price);
      for (final r in [1.272, 1.618]) {
        levels.add((exp(_ln(b.price) - r * bLen), 'Zewnętrzne $r fali B (flat nieregularna)'));
      }
    }
  }
  final zones = clusterZones(levels, gap: (degree * 0.25).clamp(0.015, 0.06))..sort((x, y) => y.score.compareTo(x.score) != 0 ? y.score.compareTo(x.score) : y.hi.compareTo(x.hi));
  final below = zones.where((z) => z.lo < topP.price).toList();
  // przy równej sile wygrywa strefa, w której faktycznie skończyła się korekta
  final hitZone = cLow == null ? null : below.where((z) => z.contains(cLow.price)).fold<Zone?>(null, (m, z) => m == null || z.score > m.score ? z : m);
  final best = hitZone != null && (below.isEmpty || hitZone.score >= below.first.score) ? hitZone : (below.isEmpty ? null : below.first);
  final fib886 = _lvl(topP.price, start.price, 0.886);
  final flatC = a != null && b != null && b.high ? exp(_ln(b.price) - 1.618 * (_ln(topP.price) - _ln(a.price))) : null;
  final invalid = switch (negation) {
    Negation.fib886 => fib886,
    Negation.start => start.price * 0.995,
    Negation.flat => max(start.price * 0.995, min(fib886, (flatC ?? fib886) * 0.99)),
  };
  final invalidWhy = switch (negation) {
    Negation.fib886 => '0.886 całego ruchu',
    Negation.start => 'początek całego ruchu',
    Negation.flat => flatC != null && invalid < fib886 ? 'zasięg 1.618 fali A (korekta płaska nieregularna)' : '0.886 całego ruchu',
  };

  final wedge = findWedge(piv, cs);
  final checks = <Check>[
    Check(trend == 'wzrostowy', 'Trend (szczyty i dołki): $trend'),
    Check(impulse, impulse ? 'Impuls 5 fal do szczytu${diagonal ? ' (klin - diagonal)' : ''}' : 'Brak czytelnego impulsu 5 fal do szczytu'),
    Check(legs.length >= 3, legs.isEmpty ? 'Korekta jeszcze się nie zaczęła' : 'Korekta: ${legs.length} ${legs.length >= 3 ? 'odcinki (A-B-C)' : legs.length == 1 ? 'odcinek (tylko A)' : 'odcinki (A-B, brak C)'}'),
    if (best != null) Check(best.score >= 2, 'Najmocniejsza strefa ${_p(best.lo)}–${_p(best.hi)}: ${best.score} narzędzia (${best.tools.join(', ')})'),
    if (wedge != null) Check(!wedge.broken, wedge.broken ? 'Wypadnięcie z klina wzrostowego - sygnał ostrzegawczy' : 'Klin wzrostowy na szczycie - obserwuj dolną krawędź'),
  ];

  final up = topP.price * pow(topP.price / start.price, 0.382);
  Scenario bullish(String text, num fromI, double from, double via) => Scenario(
        'Główny: koniec korekty i wzrosty',
        text,
        true,
        [(lastI, last), if (via < from) (fromI + max(4, (lastI - topP.i) * 0.4), via), (lastI + max(10, (lastI - start.i) * 0.35), up)],
      );

  // 5) decyzja
  if (wedge != null && wedge.broken && corr.length <= 2) {
    return Analysis(
      candles: cs, pivots: piv, degree: degree, trend: trend, signal: Signal.ostrzezenie, zones: below.take(3).toList(), wedge: wedge,
      headline: 'Wypadek z klina po 5 falach - ryzyko końca wzrostów. Nie dokładam, rozważ ograniczenie ryzyka.',
      checks: checks,
      scenarios: [
        Scenario('Ryzyko: większa korekta', 'Jeśli cena nie wróci do klina, spodziewaj się korekty A-B-C do ${best == null ? 'stref poniżej' : '${_p(best.lo)}–${_p(best.hi)}'}.', false,
            [(lastI, last), (lastI + 8, wedge.lower.at(lastI + 8) * 0.99), (lastI + 25, best?.mid ?? last * 0.8)]),
        Scenario('Alternatywa: fałszywe wybicie', 'Powrót ceny do klina ruchem 5-falowym neguje sygnał - trend trwa.', true,
            [(lastI, last), (lastI + 15, topP.price * 1.03)]),
      ],
    );
  }
  if (trend == 'spadkowy' && !impulse && topK < piv.length - 4) {
    return Analysis(
      candles: cs, pivots: piv, degree: degree, trend: trend, signal: Signal.nieKupuj, zones: below.take(3).toList(), wedge: wedge,
      headline: 'Trend spadkowy - niższe szczyty i dołki. Nie kupuję, dopóki nie pojawi się impuls 5 fal w górę.',
      checks: checks,
      scenarios: [
        Scenario('Główny: spadki trwają', 'Kolejne strefy, gdzie spadek może się zatrzymać, są poniżej. Szukam w nich impulsu wzrostowego.', false,
            [(lastI, last), (lastI + 20, last * 0.85)]),
      ],
    );
  }
  if (corr.isEmpty || (corr.length == 1 && !corr.first.confirmed && corr.first.high)) {
    return Analysis(
      candles: cs, pivots: piv, degree: degree, trend: trend, signal: Signal.czekaj, zones: below.take(3).toList(), wedge: wedge,
      headline: 'Trwa wzrost - nie gonię ceny. Okazja pojawi się po korekcie trójfalowej do strefy ${best == null ? '' : '${_p(best.lo)}–${_p(best.hi)}'}.',
      checks: checks,
      scenarios: [if (best != null) bullish('Po korekcie A-B-C do strefy i impulsie w górę - kontynuacja trendu.', lastI, last, best.mid)],
    );
  }
  if (last < invalid) {
    return Analysis(
      candles: cs, pivots: piv, degree: degree, trend: trend, signal: Signal.nieKupuj, zones: below.take(3).toList(), wedge: wedge,
      headline: 'Cena poniżej ${_p(invalid)} ($invalidWhy) - scenariusz korekty zanegowany. Możliwy koniec trendu; czekam na nową strukturę.',
      checks: checks,
      scenarios: [
        Scenario('Większa korekta / bessa', 'To mogła być dopiero fala A większej korekty: odbicie B, potem C niżej.', false,
            [(lastI, last), (lastI + 12, last * 1.1), (lastI + 30, last * 0.8)]),
      ],
    );
  }
  final inZone = best != null && (best.contains(last) || (cLow != null && best.contains(cLow.price)) || last < best.hi);
  if (!inZone) {
    return Analysis(
      candles: cs, pivots: piv, degree: degree, trend: trend, signal: Signal.czekaj, zones: below.take(3).toList(), wedge: wedge,
      headline: 'Korekta trwa (${legs.map((p) => p.label).join('-')}). Strefa zakupu ${best == null ? '-' : '${_p(best.lo)}–${_p(best.hi)}'}; kupuję dopiero po A-B-C i impulsie w górę.',
      checks: checks,
      scenarios: [
        if (best != null) bullish('Spadek do strefy ruchem 3-falowym, potem impuls - zakup i powrót do wzrostów.', lastI, last, best.mid),
        Scenario('Alternatywa: głębsza korekta', 'Zamknięcie poniżej ${_p(invalid)} neguje scenariusz - to mogła być dopiero fala A.', false,
            [(lastI, last), (lastI + 20, invalid * 0.95)]),
      ],
    );
  }
  // cena w strefie: potrzebne A-B-C i potwierdzenie
  final abc = legs.length >= 3;
  final conf2 = cLow == null ? (ok: false, how: '', piv: <Pivot>[]) : confirmUp(cs, cLow.i, degree);
  checks.add(Check(conf2.ok, conf2.ok ? 'Potwierdzenie: ${conf2.how}' : 'Brak potwierdzenia (impulsu w górę od dołka)'));
  if (abc && conf2.ok && cLow != null) {
    final stop = cLow.price * 0.99;
    // TP1 na najbliższym oporze, ale musi dawać choć pół ryzyka zysku - inaczej dalszy opór albo brak transakcji
    final riskAbs = last - stop;
    final tp1 = [if (b != null && b.high) b.price, topP.price].where((x) => x - last >= riskAbs * minReward).fold<double?>(null, (m, x) => m == null || x < m ? x : m);
    // dodatkowe, niezależne narzędzia - nie blokują wejścia, tylko zwiększają pozycję
    final extra = confluenceTools(cs, a, cLow, b, best);
    for (final e in extra.all.entries) {
      checks.add(Check(e.value, e.key));
    }
    final n = extra.all.values.where((v) => v).length;
    final size = sizeTiers[min(n, sizeTiers.length - 1)];
    if (tp1 == null || up <= tp1) {
      checks.add(Check(false, 'Zysk do najbliższego oporu za mały względem ryzyka (stop ${_p(stop)}) - nie wchodzę'));
      return Analysis(
        candles: cs, pivots: piv, degree: degree, trend: trend, signal: Signal.obserwuj, zones: below.take(3).toList(), wedge: wedge,
        headline: 'Korekta A-B-C i potwierdzenie są, ale cena już blisko oporu - stosunek zysku do ryzyka za słaby. Czekam na lepsze miejsce.',
        checks: checks, confirmPivots: conf2.piv,
      );
    }
    // filtr trendu (dobrany testem na 20 walorach 2021-2026): korekty kupujemy tylko nad średnią ~200 sesji
    final sma = trendAverage(cs);
    if (sma != null && last < sma) {
      checks.add(Check(false, 'Cena pod średnią ${_smaLabel(cs)} (${_p(sma)}) - korekta w trendzie spadkowym, nie wchodzę'));
      return Analysis(
        candles: cs, pivots: piv, degree: degree, trend: trend, signal: Signal.obserwuj, zones: below.take(3).toList(), wedge: wedge,
        headline: 'Korekta A-B-C i potwierdzenie są, ale cena jest pod średnią ${_smaLabel(cs)} - w trendzie spadkowym takie sygnały częściej zawodzą.',
        checks: checks, confirmPivots: conf2.piv,
      );
    }
    if (sma != null) checks.add(Check(true, 'Cena nad średnią ${_smaLabel(cs)} (${_p(sma)}) - trend sprzyja'));
    return Analysis(
      candles: cs, pivots: piv, degree: degree, trend: trend, signal: Signal.kup, zones: below.take(3).toList(), wedge: wedge,
      headline: 'Sygnał KUP: korekta A-B-C w strefie ${best.score} narzędzi i ${conf2.how}. '
          'Dodatkowo zgodne: $n z ${extra.all.length} (informacyjnie).${size < 100 ? ' Pozycja $size%.' : ''}',
      checks: checks, confirmPivots: conf2.piv, confluence: [for (final e in extra.all.entries) if (e.value) e.key],
      entry: last, stop: stop, tp1: tp1, tp2: up, sizePct: size,
      scenarios: [
        Scenario('Główny: fala 3 / powrót trendu', 'TP1 ${_p(tp1)} - realizuję część, stop na wejście (zabezpieczenie przed stratą). Cel ${_p(up)}.', true,
            [(lastI, last), (lastI + 8, tp1), (lastI + 25, up)]),
        Scenario('Negacja', 'Zamknięcie poniżej ${_p(stop)} (dołek korekty) - stop, scenariusz nieaktualny.', false,
            [(lastI, last), (lastI + 10, stop * 0.97)]),
      ],
    );
  }
  return Analysis(
    candles: cs, pivots: piv, degree: degree, trend: trend, signal: Signal.obserwuj, zones: below.take(3).toList(), wedge: wedge,
    headline: abc
        ? 'Cena w strefie, korekta A-B-C kompletna - czekam na impuls w górę jako potwierdzenie.'
        : 'Cena w strefie, ale to dopiero ${corr.length == 1 ? 'fala A' : 'A-B'} - jedno narzędzie (wsparcie) to za mało. Czekam na ruch trójfalowy.',
    checks: checks, confirmPivots: conf2.piv,
    scenarios: [
      bullish('Impuls w górę ze strefy = sygnał zakupu.', lastI, last, last),
      Scenario('Alternatywa: to fala A', 'Odbicie B i jeszcze jedno zejście (C) niżej, w okolice ${_p(zones.where((z) => z.hi < best.lo).fold<double>(invalid, (m, z) => z.mid))}.', false,
          [(lastI, last), (lastI + 10, last * 1.06), (lastI + 25, invalid)]),
    ],
  );
}

/// Liczba świec odpowiadająca ~200 sesjom: dzienne 200, tygodniowe 40, miesięczne 10.
int _smaLen(List<Candle> cs) {
  if (cs.length < 3) return 200;
  final gap = cs.last.t.difference(cs[cs.length - 2].t).inDays.abs();
  return gap >= 20 ? 10 : gap >= 5 ? 40 : 200;
}

String _smaLabel(List<Candle> cs) => switch (_smaLen(cs)) { 10 => '10 miesięcy', 40 => '40 tygodni', _ => '200 sesji' };

/// Średnia z ostatnich ~200 sesji (null, gdy za krótka historia).
double? trendAverage(List<Candle> cs) {
  final n = _smaLen(cs);
  if (cs.length < n) return null;
  return cs.sublist(cs.length - n).fold(0.0, (s, c) => s + c.c) / n;
}

/// RSI (14) - siła ruchu; < 30-35 = wyprzedanie.
List<double> rsiSeries(List<Candle> cs, [int n = 14]) {
  final out = List<double>.filled(cs.length, 50);
  double g = 0, l = 0;
  for (var i = 1; i < cs.length; i++) {
    final d = cs[i].c - cs[i - 1].c;
    final up = d > 0 ? d : 0.0, dn = d < 0 ? -d : 0.0;
    if (i <= n) {
      g += up / n;
      l += dn / n;
    } else {
      g = (g * (n - 1) + up) / n;
      l = (l * (n - 1) + dn) / n;
    }
    out[i] = l == 0 ? 100 : 100 - 100 / (1 + g / l);
  }
  return out;
}

/// Narzędzia niezależne od Fibonacciego i fal: RSI, wolumen, wyższy interwał, mocna strefa (≥3 narzędzia).
({Map<String, bool> all}) confluenceTools(List<Candle> cs, Pivot? a, Pivot? cLow, Pivot? b, Zone zone) {
  final all = <String, bool>{};
  if (cLow != null) {
    final r = rsiSeries(cs);
    final oversold = r[cLow.i] < 35;
    final div = a != null && !a.high && cLow.price < a.price && r[cLow.i] > r[a.i];
    all[oversold
        ? 'RSI: wyprzedanie na dołku C (${r[cLow.i].toStringAsFixed(0)})'
        : div
            ? 'RSI: dywergencja - cena niżej niż w A, RSI wyżej'
            : 'RSI: bez wyprzedania i dywergencji na dołku C'] = oversold || div;
  }
  // wolumen: spadek C na słabnącym obrocie, odbicie na rosnącym
  if (cLow != null && b != null && cLow.i > b.i && cs.length - 1 > cLow.i && cs.any((c) => c.v > 0)) {
    double avg(int from, int to) {
      final xs = cs.sublist(from, to).map((c) => c.v).where((v) => v > 0).toList();
      return xs.isEmpty ? 0 : xs.reduce((x, y) => x + y) / xs.length;
    }

    final down = avg(b.i + 1, cLow.i + 1), up = avg(cLow.i + 1, cs.length);
    if (down > 0 && up > 0) {
      all[up > down ? 'Wolumen: odbicie na większym obrocie niż spadek C (×${(up / down).toStringAsFixed(1)})' : 'Wolumen: odbicie bez wzrostu obrotu'] = up > down;
    }
  }
  // wyższy interwał: świece łączone po 5 (dzień → tydzień), 4 (tydzień → miesiąc), 3 (miesiąc → kwartał)
  final k = switch (_smaLen(cs)) { 10 => 3, 40 => 4, _ => 5 };
  final closes = <double>[for (var i = cs.length - 1; i >= 0; i -= k) cs[i].c].reversed.toList();
  if (closes.length >= 15) {
    double sma(int end) => closes.sublist(end - 10, end).reduce((x, y) => x + y) / 10;
    final now = sma(closes.length), before = sma(closes.length - 4);
    final ok = closes.last > now && now > before;
    all[ok ? 'Wyższy interwał: trend wzrostowy (nad rosnącą średnią)' : 'Wyższy interwał: trend nie potwierdza'] = ok;
  }
  all[zone.score >= 3 ? 'Strefa z ${zone.score} różnych narzędzi' : 'Strefa tylko z ${zone.score} narzędzi'] = zone.score >= 3;
  return (all: all);
}

// ---------- mam ten walor: trzymać czy sprzedać ----------

enum HoldAction { trzymaj, dokup, czesc, rozwaz, sprzedaj }

class HoldAdvice {
  final HoldAction action;
  final String title, text;
  final double? stop, target;
  const HoldAdvice(this.action, this.title, this.text, {this.stop, this.target});
}

/// Rada dla kogoś, kto już ma walor (kupiony po [entry], jeśli znana). Te same reguły co analiza:
/// trend i negacja scenariusza decydują, stop pod ostatnim dołkiem chroni zysk, opór to miejsce na realizację.
HoldAdvice holdingAdvice(Analysis a, {double? entry}) {
  final last = a.last;
  final lows = a.pivots.where((p) => !p.high && p.price < last).toList();
  final lastLow = lows.isEmpty ? null : lows.last;
  final stop = a.signal == Signal.kup ? a.stop : (lastLow == null ? null : lastLow.price * 0.99);
  final above = [for (final z in a.zones) if (z.lo > last * 1.005) z]..sort((x, y) => x.lo.compareTo(y.lo));
  final highs = a.pivots.where((p) => p.high && p.price > last * 1.005).toList();
  final res = above.isNotEmpty ? above.first.lo : (highs.isEmpty ? null : highs.map((p) => p.price).reduce(min));
  final pnl = entry == null || entry <= 0 ? null : (last / entry - 1) * 100;
  final pnlTxt = pnl == null ? '' : ' Jesteś ${pnl >= 0 ? 'na plusie' : 'na minusie'} ${pnl.abs().toStringAsFixed(1)}%.';
  final stopTxt = stop == null ? '' : ' Stop ochronny: zamknięcie pod ${_p(stop)} (ostatni dołek).';
  final resTxt = res == null ? '' : ' Najbliższy opór: ${_p(res)}.';
  final nearRes = res != null && res / last - 1 < 0.02;
  // odbicie: cena wyraźnie nad ostatnim dołkiem
  final bouncing = lastLow != null && last / lastLow.price - 1 > 0.05;

  if (pnl != null && pnl >= 100) {
    return HoldAdvice(HoldAction.czesc, 'WYJMIJ WKŁAD',
        'Cena podwoiła się od Twojego zakupu.$pnlTxt Sprzedaj połowę - odzyskasz cały wkład, a reszta pracuje „za darmo”.$stopTxt',
        stop: stop, target: res);
  }
  switch (a.signal) {
    case Signal.ostrzezenie:
      return HoldAdvice(HoldAction.rozwaz, 'ROZWAŻ SPRZEDAŻ',
          'Wypadek z klina po wzrostach - ryzyko końca trendu. Ogranicz ryzyko: sprzedaj część (np. połowę), resztę chroń stopem.$pnlTxt$stopTxt',
          stop: stop, target: res);
    case Signal.nieKupuj:
      if (bouncing && res != null) {
        return HoldAdvice(HoldAction.rozwaz, 'SPRZEDAJ NA ODBICIU',
            'Scenariusz wzrostowy zanegowany, trwa odbicie. Odbicie to dobre miejsce na wyjście - rozważ sprzedaż przy oporze ${_p(res)}, '
            'zanim cena wróci w dół.$pnlTxt$stopTxt',
            stop: stop, target: res);
      }
      return HoldAdvice(HoldAction.sprzedaj, 'SPRZEDAJ / CIASNY STOP',
          'Trend spadkowy albo scenariusz zanegowany - analiza nie widzi powodu, żeby trzymać.$pnlTxt'
          '${stop == null ? ' Sprzedaj albo ustaw stop tuż pod bieżącą ceną.' : stopTxt}$resTxt',
          stop: stop, target: res);
    case Signal.kup:
      return HoldAdvice(HoldAction.dokup, 'TRZYMAJ (MOŻNA DOKUPIĆ)',
          'Sygnał KUP - korekta zakończona, trend wraca. Trzymaj; dokupienie tylko z planem (stop i wielkość z zarządzania kapitałem).$pnlTxt$stopTxt',
          stop: stop, target: a.tp1);
    case Signal.obserwuj:
    case Signal.czekaj:
      if (nearRes && (pnl ?? 0) > 0) {
        return HoldAdvice(HoldAction.czesc, 'ZREALIZUJ CZĘŚĆ',
            'Cena dochodzi do oporu ${_p(res)} - realizacja części zysku i stop na wejście zabezpieczy pozycję przed stratą.$pnlTxt$stopTxt',
            stop: stop, target: res);
      }
      return HoldAdvice(HoldAction.trzymaj, 'TRZYMAJ',
          '${a.trend == 'wzrostowy' ? 'Trend wzrostowy, ' : ''}korekta w toku nie neguje scenariusza - nie ma sygnału do sprzedaży.$pnlTxt$stopTxt$resTxt',
          stop: stop, target: res);
  }
}

// ---------- wyższy interwał ----------

/// Świece tygodniowe z dziennych (poniedziałek-piątek).
List<Candle> weeklyCandles(List<Candle> d) {
  final out = <Candle>[];
  DateTime? wk;
  var o = 0.0, h = 0.0, l = 0.0, c = 0.0, v = 0.0;
  var t = DateTime(2000);
  for (final x in d) {
    final w = DateTime(x.t.year, x.t.month, x.t.day).subtract(Duration(days: x.t.weekday - 1));
    if (wk != w) {
      if (wk != null) out.add(Candle(t, o, h, l, c, v));
      wk = w;
      o = x.o;
      h = x.h;
      l = x.l;
      v = 0;
      t = x.t;
    }
    h = max(h, x.h);
    l = min(l, x.l);
    c = x.c;
    v += x.v;
  }
  if (wk != null) out.add(Candle(t, o, h, l, c, v));
  return out;
}

/// Czy wykres tygodniowy nie neguje sygnału z dziennego (nie NIE KUPUJ / UWAGA). null = za krótka historia.
/// Test na 688 walorach: ocena 3-4 + tydzień nie neguje → 65% trafień i +6,8% (bez tego 64% i +6,6%).
bool? weeklyAgrees(List<Candle> daily) {
  final wk = weeklyCandles(daily);
  if (wk.length < 60) return null;
  final s = analyze(wk).signal;
  return s != Signal.nieKupuj && s != Signal.ostrzezenie;
}

// ---------- ranking „warte uwagi” ----------

/// Jak sygnały KUP wypadały wcześniej na tym walorze (zasady bota: połowa na 1R, stop na wejście, reszta na celu).
({int wins, int n}) ruleHistory(List<Candle> cs, {int from = 250}) {
  var wins = 0, n = 0, i = from;
  while (i < cs.length - 1) {
    final a = analyze(cs.sublist(0, i + 1));
    if (a.signal != Signal.kup) {
      i++;
      continue;
    }
    final e = a.entry!, risk = e - a.stop!;
    final tp1 = e + risk, tp2 = max(a.tp2!, tp1 + risk);
    var stop = a.stop!, half = false, res = 0.0, j = i + 1;
    double? exit;
    for (; j < cs.length && j <= i + 120; j++) {
      final k = cs[j];
      if (k.l <= stop) {
        exit = stop;
        break;
      }
      if (!half && k.h >= tp1) {
        half = true;
        res += (tp1 / e - 1) * 50;
        stop = e;
      }
      if (k.h >= tp2) {
        exit = tp2;
        break;
      }
    }
    if (j >= cs.length) break; // transakcja jeszcze trwa - nie liczymy
    exit ??= cs[j].c;
    res += (exit / e - 1) * (half ? 50 : 100);
    n++;
    if (res > 0) wins++;
    i = j + 1;
  }
  return (wins: wins, n: n);
}

/// Ocena okazji 0-4 z cech, które w teście na ~690 walorach 2021-2026 (612 sygnałów) wiązały się z lepszym wynikiem:
/// cena wyraźnie nad średnią 200 sesji, realny cel (≤ 4,5× ryzyka), reguły działały wcześniej na tym walorze,
/// walor o większych ruchach (stop > 10%). Ocena 3-4: średnio +3,7% … +10,4% na transakcję; 0-1,5: ok. 0%.
({double score, List<String> why}) opportunityScore(Analysis a, {({int wins, int n})? history}) {
  var score = 0.0;
  final why = <String>[];
  final sma = trendAverage(a.candles);
  if (sma != null && a.last > sma * 1.012) {
    score += 1;
    why.add('wyraźnie nad średnią 200 sesji');
  }
  if (a.signal == Signal.kup && a.entry != null && a.stop != null && a.tp2 != null) {
    final risk = a.entry! - a.stop!;
    if (risk > 0 && (a.tp2! - a.entry!) / risk < 4.5) {
      score += 1;
      why.add('realny cel');
    }
    if (risk / a.entry! > 0.10) {
      score += 1;
      why.add('duże ruchy (szeroki stop)');
    }
  }
  final h = history;
  if (h == null || h.n == 0) {
    score += 0.5;
  } else if (h.wins / h.n >= 0.5) {
    score += 1;
    why.add('tu działało ${h.wins}/${h.n}');
  } else {
    why.add('tu słabo: ${h.wins}/${h.n}');
  }
  return (score: score, why: why);
}

// ---------- test na historii ----------

class BacktestTrade {
  final DateTime entryAt;
  final double entry, exit;
  final double pct; // wynik na całej pozycji
  final double riskPct; // odległość stopu od wejścia (%)
  const BacktestTrade(this.entryAt, this.entry, this.exit, this.pct, this.riskPct);
  /// Wynik w wielokrotnościach ryzyka (R): +2R = zysk dwa razy większy niż ryzykowana kwota.
  double get r => riskPct <= 0 ? 0 : pct / riskPct;
}

/// Zarządzanie kapitałem: każda transakcja ryzykuje [riskPct]% aktualnego kapitału (wielkość pozycji z odległości stopu).
({double endPct, double maxDrawdownPct}) equityCurve(List<BacktestTrade> trades, double riskPct) {
  var eq = 1.0, peak = 1.0, dd = 0.0;
  for (final t in trades) {
    eq *= 1 + riskPct / 100 * t.r;
    peak = max(peak, eq);
    dd = max(dd, 1 - eq / peak);
  }
  return (endPct: (eq - 1) * 100, maxDrawdownPct: dd * 100);
}

class BacktestResult {
  final List<BacktestTrade> trades;
  final double buyHoldPct;
  const BacktestResult(this.trades, this.buyHoldPct);
  int get wins => trades.where((t) => t.pct > 0).length;
  double get totalPct => trades.fold(1.0, (s, t) => s * (1 + t.pct / 100)) * 100 - 100;
  double get avgPct => trades.isEmpty ? 0 : trades.fold(0.0, (s, t) => s + t.pct) / trades.length;
  double get worstPct => trades.isEmpty ? 0 : trades.map((t) => t.pct).reduce(min);
}

/// Test na historii bez zaglądania w przyszłość: na każdej świecy analiza tylko z danych do tej świecy.
/// Wejście po zamknięciu przy sygnale KUP; połowa na TP1 i stop na wejście; reszta na celu, stopie albo po [maxBars].
BacktestResult backtest(List<Candle> cs, {int warmup = 120, int maxBars = 120}) {
  final trades = <BacktestTrade>[];
  var i = warmup;
  while (i < cs.length - 1) {
    final a = analyze(cs.sublist(0, i + 1));
    if (a.signal != Signal.kup) {
      i++;
      continue;
    }
    final entry = cs[i].c;
    var stop = a.stop!;
    var half = false;
    var realized = 0.0;
    var j = i + 1;
    double? exitPrice;
    for (; j < cs.length && j <= i + maxBars; j++) {
      final k = cs[j];
      if (k.l <= stop) {
        exitPrice = stop;
        break;
      }
      if (!half && k.h >= a.tp1!) {
        half = true;
        realized = (a.tp1! / entry - 1) * 50;
        stop = entry;
      }
      if (k.h >= a.tp2!) {
        exitPrice = a.tp2!;
        break;
      }
    }
    j = min(j, cs.length - 1);
    exitPrice ??= cs[j].c;
    final restPct = (exitPrice / entry - 1) * (half ? 50 : 100);
    trades.add(BacktestTrade(cs[i].t, entry, exitPrice, realized + restPct, (1 - a.stop! / entry) * 100));
    i = j + 1;
  }
  final bh = cs.length > warmup ? (cs.last.c / cs[warmup].c - 1) * 100 : 0.0;
  return BacktestResult(trades, bh);
}
