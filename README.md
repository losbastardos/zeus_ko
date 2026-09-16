# Šachový engine (x86-64 Linux, NASM)

A high-performance chess engine written in x86-64 NASM assembly for Linux, featuring UCI protocol support, alpha-beta pruning with quiescence search, opening book integration, and both text and graphical (framebuffer/SDL) interfaces.

Textový šachový engine písaný v čistom NASM assembly pre x86-64 Linux.
Aktuálny stav: E4 alpha-beta + eval hotové, E5 opening book, E6 čiastočne (Syzygy `.rtbw` mmap loader + základný WDL probe), bočný panel v textovom móde a E7 grafika (framebuffer/SDL).

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
- **E6** 🚧 Syzygy/Nalimov čiastočne: `SyzygyPath`/`SyzygyProbeDepth`, mmap loader pre `.rtbw`, `tbtest`, základný WDL fallback probe
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
Príkaz `tbtest` vypíše rýchlu diagnostiku TB vrstvy (`pieces`, `wdl`, `map_bytes`).
Ukonči program príkazom `exit` alebo `quit`.

V `chess.ini` môžeš nastaviť aj `syzygy=` na cestu k TB tabuľkám (prázdne = vypnuté).

V textovom móde sa vpravo od šachovnice zobrazuje panel s históriou ťahov,
zajatými figúrkami a knižnými ťahmi pre aktuálnu pozíciu (ak sú v `book.book`).

## Syzygy TB (E6, current)

Rýchly workflow pre lokálnu prípravu 3-piece tabuliek:

```bash
make syzygy-tools
make syzygy-3piece
```

Smoke test mapovania/probe:

```bash
printf "uci\nsetoption name SyzygyPath value /var/www/html/chess/tb\nposition fen 7k/8/8/8/8/8/8/KQ6 w - - 0 1\ntbtest\nquit\n" | ./chess-static --uci
```

Očakávaný tvar výstupu:

```text
info string tbtest pieces=3 wdl=2 map_bytes=272
```

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
	--openings-order sequential --srand 20260916 \
	--games 200 --concurrency 2 --tc 10+0.1 \
	--sprt "elo0=0 elo1=8 alpha=0.05 beta=0.05" \
	--pgnout /tmp/sprt.pgn
```

Pre kontrolu bez spustenia použij `--dry-run`.
Poznámka: `OwnBook=false` sa defaultne posiela len pre NEW engine (Zeus);
pre BASE (napr. Stockfish) je to defaultne vypnuté, aby nevznikali warningy.
Pre reprodukovateľné testy používaj `--openings-order sequential` a fixný `--srand`.

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

## TB Varianty

Pre TB prípravu vieš najprv vypísať presné varianty tried, napr. `KPPPvK | kpppK`, a až potom ich generovať.

```bash
python3 utils/rtbz_variants.py --max-pieces 5 --show both
python3 utils/rtbz_variants.py \
	--max-pieces 5 \
	--sided single \
	--show both \
	--generator 'tbgen --variant {canonical} --out {output}' \
	--output-dir /tmp/rtbz
make rtbz-variants MAX_PIECES=5 SIDED=single SHOW=both
```

Skript vie vypísať canonical aj compact alias názov, spustiť externý generator pre každý variant a zoradiť výsledné `.rtbz` súbory podľa konečnej veľkosti.

## Strength Gate

Automatický quality gate pre kandidátne zmeny (build + regresia + BF + Arasan d6):

```bash
make strength-gate
```

Skript: `utils/strength_gate.sh`

Voliteľné premenné prostredia:
- `BF_MIN_HITS` (default `2`)
- `ARASAN_MIN_HITS` (default `17`)
- `BF_DEPTH` (default `14`)
- `ARASAN_DEPTH` (default `6`)
- `BUILD_BIN=0` preskočí rebuild
- `BASELINE_FILE` (default `tests/suites/strength_baseline.env`)

Prvý krok na novej vetve (uloženie baseline):

```bash
BUILD_BIN=0 ./utils/strength_gate.sh --record-baseline ./chess-static
```

Následne bežný gate porovnáva proti uloženému baseline súboru.

Príklad:

```bash
BF_MIN_HITS=2 ARASAN_MIN_HITS=17 BUILD_BIN=0 ./utils/strength_gate.sh ./chess-static
```

## A/B Compare (candidate vs baseline)

Rýchle porovnanie dvoch binárok na BF + Arasan suite s delta reportom:

```bash
make ab-compare CANDIDATE=./chess-static BASELINE=./chess-static
```

Priamy skript:

```bash
STRICT=1 BF_DEPTH=14 ARASAN_DEPTH=6 ./utils/ab_compare.sh ./candidate ./baseline
```

`STRICT=1` vráti nenulový exit code, ak je candidate horší ako baseline.

Perzistentný report (append TSV + posledný MD snapshot):

```bash
REPORT_TSV=tests/reports/ab_history.tsv \
REPORT_MD=tests/reports/ab_latest.md \
./utils/ab_compare.sh ./candidate ./baseline
```

Voliteľne môžeš označiť beh explicitným tagom:

```bash
RUN_TAG=probcut-tweak-v2 ./utils/ab_compare.sh ./candidate ./baseline
```

Ak `RUN_TAG` nenastavíš, skript použije automaticky `git-short-hash` (+ `-dirty`).

Rýchly náhľad posledných behov:

```bash
make ab-history N=10
```

## Nightly Pipeline

Jedným príkazom spustí gate + strict A/B + report export:

```bash
make nightly-pipeline CANDIDATE=./chess-static BASELINE=./chess-static
```

Priamy skript:

```bash
RUN_TAG=nightly-local BUILD_BIN=0 ./utils/nightly_pipeline.sh ./candidate ./baseline
```

## SPRT A/B Runner

Wrapper nad `sprt_match.py` s reproducible defaults (fixed seed + sequential openings).

Dry-run (default):

```bash
make sprt-ab CANDIDATE=./chess-static BASELINE=./chess-static
```

Ostrý beh:

```bash
EXECUTE=1 RUN_TAG=sprt-test make sprt-ab CANDIDATE=./candidate BASELINE=./baseline
```

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
