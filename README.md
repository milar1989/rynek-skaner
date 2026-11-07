# rynek-skaner

Skaner sygnałów analizy falowej (impuls 5 fal, korekta A-B-C, strefy Fibonacciego, kliny, filtr trendu 200 sesji)
dla ok. 700 walorów (`universe.txt`). Uruchamiany co 5 minut przez GitHub Actions; w godzinach sesji skanuje otwarte rynki,
krypto całą dobę. Wynik: `signals.json` (sygnał każdego waloru + zdarzenia: nowe KUP, negacje, poprawy).

Tylko publiczne dane rynkowe. Repo nie zawiera sekretów ani danych użytkownika - powiadomienia wysyła aplikacja,
która sama pobiera `signals.json` z tego repo w konkretnej wersji (commit).

To narzędzie pomocnicze, nie rekomendacja inwestycyjna.
