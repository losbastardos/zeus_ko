# Šachový engine (x86-64 Linux, NASM)

A high-performance chess engine written in x86-64 NASM assembly for Linux, featuring UCI protocol support, alpha-beta pruning with quiescence search, opening book integration, and both text and graphical (framebuffer/SDL) interfaces.

Textový šachový engine písaný v čistom NASM assembly pre x86-64 Linux.
Aktuálny stav: E4 alpha-beta + eval hotové, E5 opening book, základný UCI protokol, bočný panel v textovom móde a E7 grafika (framebuffer/SDL).

## Screenshoty

Textový mód s bočným panelom (história ťahov, zajaté figúrky, knižné ťahy):

![Textový mód](screenshots/text_mode.png)

Grafický SDL mód:

![SDL mód](screenshots/sdl_mode.png)

## Etapy

- **E0** ✅ Kostra: šachovnica, ASCII výpis, vstup `e2e4`, výmena strán
- **E1** ✅ Generátor pseudo-legálnych ťahov
- **E2** ✅ Legálne ťahy + šach/mat/pat detekcia, 50-ťahové pravidlo, 3x opakovanie pozície
- **E3** ✅ NegaMax (hĺbka 3-4), engine hrá čierneho
- **E4** ✅ Alpha-Beta + evaluácia (materiál + PST), quiescence
- **E5** ✅ Opening book (vlastný formát `hash | move`)
- **E6** ⏳ Príprava Syzygy/Nalimov interface
- **E7** ✅ Grafika: framebuffer/SDL, BMP figúrky, klikacie rozhranie
- **E8** ✅ Textový UI panel: história ťahov, zajaté figúrky, knižné ťahy, UCI

## Kompilácia

```bash
./build.sh
```

alebo manuálne (odporúčam `make`, ktoré to spraví za teba):

```bash
make
```

Binárka `./chess` obsahuje všetky backendy naraz (text, framebuffer aj SDL),
SDL (`libSDL2`) sa linkuje dynamicky.

Na NixOS, ak nemáš `nasm` v PATH, `./build.sh` ho automaticky získa cez `nix-shell`.

## Spustenie

```bash
./chess
```

Zadávaj ťahy v algebraickej notácii, napríklad `e2e4`, `g1f3`.
Príkaz `flip` prepne orientáciu výpisu šachovnice.
Príkaz `new` spustí novú hru, `go` nechá engine zahrať jeden ťah za aktuálnu stranu.
Príkaz `gfx` prepne do grafického režimu (framebuffer `/dev/fb0` alebo SDL okno,
podľa `chess.ini` a dostupnosti), `text` vráti späť do terminálu.
Príkaz `uci` prepne do UCI režimu pre pripojenie k GUI.
Ukonči program príkazom `exit` alebo `quit`.

V textovom móde sa vpravo od šachovnice zobrazuje panel s históriou ťahov,
zajatými figúrkami a knižnými ťahmi pre aktuálnu pozíciu (ak sú v `book.book`).

## Reprezentácia

- `board[64]` – index `0 = a1`, `63 = h8`
- Figúra na políčku: bity `0-2` typ, bit `3` farba
- Ťah: 16-bitové číslo `from(6) | to(6) | flags(4)`

## Gauntlet Testovanie

Rýchly self-play benchmark Zeus vs iný UCI engine:

```bash
/var/www/html/chess/.venv/bin/python utils/gauntlet.py ./chess-static /run/current-system/sw/bin/stockfish 20 "movetime 100"
```

Poznámka:
- `utils/gauntlet.py` má auto-fallback pre enginy, ktoré nepoznajú argument
	`--uci` (napr. Stockfish 17), takže už netreba wrapper skript.
- Skript používa Python balík `chess` (`python-chess`).

## SPRT Workflow (CuteChess)

Automatizovaný builder pre `cutechess-cli` SPRT behy:

```bash
/var/www/html/chess/.venv/bin/python utils/sprt_match.py \
	--new ./chess-static \
	--base /run/current-system/sw/bin/stockfish \
	--openings utils/LumbrasGigaBase_OTB_0001-1899.pgn \
	--games 200 --concurrency 2 --tc 10+0.1 \
	--sprt "elo0=0 elo1=8 alpha=0.05 beta=0.05" \
	--pgnout /tmp/sprt.pgn
```

Pre kontrolu bez spustenia použij `--dry-run`.
Poznámka: `OwnBook=false` sa defaultne posiela len pre NEW engine (Zeus);
pre BASE (napr. Stockfish) je to defaultne vypnuté, aby nevznikali warningy.

## Suite Analyza (EPD)

Natívne priamo v engine (text/UCI command set):

```bash
# text mode (po starte vyber napr. 2 - local)
suite tests/suites/smoke.epd 6

# UCI mode (custom helper command)
printf "uci\nsuite tests/suites/smoke.epd 6\nquit\n" | ./chess-static --uci
printf "uci\nanalyze rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 | e2e4 d2d4\nquit\n" | ./chess-static --uci
```

Výstup obsahuje sumár: `cases`, `hits`, `misses`, `hitrate%`, `nodes`, `time_ms`.

Pre testovanie "najlepsieho tahu" na sade pozicii je k dispozicii:

```bash
/var/www/html/chess/.venv/bin/python utils/analyze_suite.py ./chess-static tests/suites/smoke.epd "depth 6"

# adresar suite + CSV export
/var/www/html/chess/.venv/bin/python utils/analyze_suite.py ./chess-static tests/suites --go "depth 6" --csv /tmp/suite_results.csv
```

Skript nacita EPD riadky s `bm` operaciou a vypise:
- HIT/MISS pre kazdu poziciu
- bestmove, ocakavane move(s), depth/time/nodes
- sumarny hit-rate

Podporovane vstupy:
- `.epd` (bm/id operacie)
- `.txt` alebo `.fenbm` vo formate `FEN | bm1,bm2 | id`
- jednotlive subory aj cely adresar suite

Poznamka:
- testovacie sady pre engine analyzu su typicky vo formate EPD/PGN (nie PNG obrazky).

---

Copyright (c) 2026 Marek Suchý <marek.suchy@gmail.com>. Všetky práva vyhradené.
