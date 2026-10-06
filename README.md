# Šachový engine (x86-64 Linux, NASM)

A high-performance chess engine written in x86-64 NASM assembly for Linux, featuring UCI protocol support, alpha-beta pruning with quiescence search, opening book integration, and both text and graphical (framebuffer/SDL) interfaces.

Textový šachový engine písaný v čistom NASM assembly pre x86-64 Linux.
Aktuálny stav: stabilná UCI vetva, text aj grafika (framebuffer/SDL), opening book,
Syzygy podpora a priebežné ladenie sily vyhľadávania/evaluácie.

## Screenshoty

Textový mód s bočným panelom (história ťahov, zajaté figúrky, knižné ťahy):

![Textový mód](screenshots/text_mode.png)

Grafický SDL mód:

![SDL mód](screenshots/sdl_mode.png)

## TODO (priebežne)

- Stabilizovať search heuristiky cez reprodukovateľný benchmark + SPRT workflow.
- Priebežne retunovať eval/NNUE bez regresií v gate testoch.
- Rozšíriť a udržiavať test sady (regresia, suite, TB smoke/verify).
- Udržiavať dokumentáciu a test postupy v súlade s aktuálnym stavom engina.

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

V `chess.ini` môžeš nastaviť aj `syzygy=` na cestu k TB tabuľkám (prázdne = vypnuté).

V textovom móde sa vpravo od šachovnice zobrazuje panel s históriou ťahov,
zajatými figúrkami a knižnými ťahmi pre aktuálnu pozíciu (ak sú v `book.book`).

## Reprezentácia

- `board[64]` – index `0 = a1`, `63 = h8`
- Figúra na políčku: bity `0-2` typ, bit `3` farba
- Ťah: 16-bitové číslo `from(6) | to(6) | flags(4)`

Poznámka: interné testovacie a debug workflow sú presunuté do lokálnej internej dokumentácie mimo verejný repozitár.

---

Copyright (c) 2026 Marek Suchý <marek.suchy@gmail.com>. Všetky práva vyhradené.
