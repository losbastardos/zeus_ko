# TODO_OPEN.md

Aktivny backlog: iba otvorene ulohy.

Poznamka: hotove body su odmazane, pokracujeme v TODO.

## P0 — Bitboard core rewrite (E10, schvalene 2026-09-29)

- [ ] **F1-F5: bitboard jadro podla `docs/superpowers/plans/2026-09-29-bitboard-core.md`**
  - spec: `docs/superpowers/specs/2026-09-29-bitboard-core-design.md`
  - ciel: >=2x nps (>=300k) po F4, inkrementalny NNUE accumulator, magic attack query
  - validacia: perft 4/5/6, legal 1:1 vs python-chess, regression, strength-gate,
    bench-report, matchup GAMES=50 po dokonceni
- [ ] **P0: root-cause Arasan gap po bitboard rewrite (0-50, TC 10+0.1)**
  - aktualny stav: stale otvorene, posledny signal `W=0 D=0 L=4` (C77 smoke),
    pri zachovanej stabilite gate (`make test` PASS, `make strength-gate` PASS)
  - uzavrete pod-ulohy (hotovo):
    - root_top instrumentacia + bit-exaktna C77 reprodukcia
    - INF/50000 leak odstraneny (all-prune fallback uz neunika)
    - heuristic ablation (`LMR/NULL/LMP/RFP/FUTILITY`) a correction-history ablation hotove
    - anti all-prune guard + root ordering patch aplikovane a overene
    - ordering hint vetva uzavreta: SPRT 2000h (`763-699-538`, baseline +11.1 +/- 13.0 Elo,
      LOS 95.3%, LLR 0.827 nedecided) -> revert commit `570ef0d`
  - otvorene pod-ulohy (co ostava):
    - pivot checkpointy su potvrdene (ply 12/16, report `tests/reports/p0_checkpoint_compare_multi_20261002.tsv`)
    - aktivny patchset: NNUE `Ke1-f1` pseudo-castle korekcia + root tie-break proti home-king tahom
      + stop-carry fix v UCI (`uci_last_iter_move`) a aktivovany home-rook tie-break
    - posledna A/B batch (root full-window, root_best boost tweak, opening time floor,
      h-rook opening penalty, NNUE scale x8) bola bez praktickeho zisku na C77,
      regresne varianty revertnute
    - doplnujuca mini-batch s opening soft penalty (queen/flank pawn) tiez bez
      praktickeho zisku na C77, preto revertnuta (ponechany iba rook/king tie-break + stop-carry)
    - navrhnut 1 cieleny patch pre pivot (search/eval), nie dalsi broad sweep
    - potvrdit aspon jednu neprehru na C77 smoke pri zachovanom gate PASS
  - exit kriterium: C77 smoke uz nebude `0-2` a nasledne prejde `make strength-gate`
- [ ] **P0: deep-search SIGSEGV v `hash_xor_piece` (depth >= 8, bench, strength-gate)**
  - pre-existing (repro na cistom F2 aj F3), nie NNUE, nie singular; blokuje E9 validaciu
  - riesi agent-13; validacia po fixe: perft 4/5/6, go depth 8/10, bench, strength-gate
- [ ] **ECO kniznica do UI: pri tahu zobrazit knizny tah (book.book) + ECO kod a nazov otvorenia (eco.bin)**
  - loader eco.bin (magic/header, binary search v position_hash, zaznam 20 B) do noveho src/eco.asm
  - panel (src/panel.asm): pri aktualnej pozicii vypisat `C20 King's Pawn Game` + knizne tahy
  - rozsah: src/eco.asm, panel.asm, io.asm/main.asm (prkaz ecotest), Makefile; netykat sa search/hash (P0)
- [ ] **Search heuristiky pack (agent-7, odlozene) — znovu spustit na novom core po F4**
  - razoring d2-3, multicut, LMR modulacia, history pruning, futility/RFP ext.

## P2 — Vykon v searchi

- [ ] **P2-AKTIVNE: NNUE `EvalMode=2` diagnostika po failed bullet smoke**
  - signal: SPRT smoke vs classic (`tc=1+0.01`) skoncil `H0 accepted` uz po 68 zapocitanych hrach,
    score `0-65-3` pre NNUE, `Elo -658.7` (log: `scratch/sprt_bullet_nnue2_vs_classic0_20261006.log`)
  - krok 1 (hotovo): scale/korelacny audit pred hrami
    - dataset: `400` pozicii (`arasan2026 + STS1 + silent-but-deadly`)
    - vysledok: `median |eval2|/|eval0| = 0.4122`, `pearson=0.6966`, `spearman=0.8130`,
      rozsah classic `[-1081,533]` vs NNUE `[-339,360]`
    - artefakty: `scratch/evalmode_scale_audit_20261006.tsv` + `.txt`
  - krok 1b (hotovo, zamietnute): rychly linear post-scale trial + smoke
    - patch vyskusany a rollbacknuty po negativnom vysledku
    - smoke: `0-55-5`, `Elo -544.7`, `SPRT H0 accepted`
    - artefakt: `scratch/sprt_bullet_nnue2_scaled_vs_classic0_20261006.log`
  - krok 2 (AKTIVNE, priorita): konzistencia accumulatora v search ceste (incremental make/unmake vs reference)
    - ciel: najst prvy mismatch ply a typ tahu (capture/promo/en-passant/castle)
  - krok 3 (az po kroku 1+2): 50-100 hier debug run s root eval trace + mini-SPRT (`elo0=0 elo1=8`)
- [ ] **P2-AKTIVNE: Bitboard movegen/apply inkrementalne**
  - ciel: prejst generate_legal/apply na bitboard reprezentaciu, ciel +30-50 % nps
  - validacia: `perft 4/5` = 197281/4865609, strength-gate
- [ ] **P2-PARKING: Incremental eval update (spustit az po P2-AKTIVNE)**
  - ciel: pawn hash / material / faza inkrementalne v make/unmake namiesto plneho prepocitu
  - validacia: eval 1:1 vs stary vypocet na test sade, strength-gate

## P3 — Search heuristiky (kazda cez mini-SPRT)

- [ ] **P3-AKTIVNE: LMR modulacia (improving + cutnode + stat-based)**
- [ ] P3-PARKING: Razoring prehldbenie na depth 2-3
- [ ] P3-PARKING: Futility/RFP depth limit + tuned margins
- [ ] P3-PARKING: Multicut extension (depth>=8, 2. potomok)
- [ ] P3-PARKING: History pruning pre quiets (threshold per depth)
- validacia (kazdy bod): `make strength-gate` + `make sprt-ab CANDIDATE=... EXECUTE=1`

## P4 — Tablebases rozsirenie

- [ ] **P4-AKTIVNE: Syzygy 5-piece rollout (vybrane kriticke endgames)**
  - ciel: postupne rozsirit 5-piece coverage podla prioritnych materialov
  - validacia:
    - `make tb-smoke-matrix`
    - oracle compare na vybranej sade
    - `make strength-gate`

## Poznamky

- Uzavrete dokumenty sa neudrzuju ako TODO backlog; backlog je iba v tomto subore.
- Pri kazdej zmene platia povinne gate z `AGENTS.md` (`test/strength/TB` podla scope).
