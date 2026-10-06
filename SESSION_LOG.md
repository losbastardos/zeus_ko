# SESSION_LOG.md

Aktivny log pre rozrobene temy. Historicke uzavrete session su presunute do
SESSION_LOG_ARCHIVE_20261002.md.

## Session: 2026-10-02 (P0 root-cause Arasan gap)

### Uzavrete dnes

- `root_top` instrumentacia + C77 replay/FEN reprodukcia su hotove.
- Fixnute all-prune INF uniky (`cp 50000`), symptom uz sa nereprodukuje.
- Hotove heuristicke ablation behy (`LMR/NULL/LMP/RFP/FUTILITY`) aj correction-history ablation.
- Nasadeny anti all-prune guard a root ordering patch; obe zmeny presli gate.
- Harness uprava `ENGINE_EVAL_MODE` v [utils/arasan_matchup.sh](utils/arasan_matchup.sh) je hotova.
- Dokonceny multi-checkpoint compare pre C77: [tests/reports/p0_checkpoint_compare_multi_20261002.tsv](tests/reports/p0_checkpoint_compare_multi_20261002.tsv).
- Experiment `root castle boost` v root orderingu bol otestovany a revertnuty (bez zlepsenia C77 smoke).
- Zmena v [src/eval.asm](src/eval.asm): NNUE post-korekcia uz neodmenuje manualny krok `Ke1-f1` ako pseudo rošádu.
- Zmena v [src/search.asm](src/search.asm): root tie-break pri rovnakom score uprednostni ne-king-home tah pred `Ke1/e8` manualnym krokom.
- Dokoncena seria A/B pokusov bez prinosu pre P0 symptom a s okamzitym cleanupom:
  - `root full-window` (revert),
  - `root_best` boost reduction (BF fail, revert),
  - opening time floor v `uci_alloc_time` (revert),
  - opening h-rook ordering penalty (revert),
  - NNUE scale test x8 (BF fail, revert).
- Novy mini-batch (2026-10-02 vecer):
  - ponechany patch v [src/uci.asm](src/uci.asm): pri stop-e sa preferuje posledny
    realne vrateny tah z ID iteracie (`uci_last_iter_move`) namiesto fallback searchu
    s aktivnym `uci_stop_flag`.
  - ponechany patch v [src/search.asm](src/search.asm): root tie-break/ordering pre
    manualny home-king/home-rook tah bol opravene aktivovany (fix vetvenia).
  - opening soft penalty (queen/flank pawn) bola bez praktickeho zisku a revertnuta.

### Aktualny otvoreny stav

- Hlavny P0 symptom trva: C77 smoke stale bez neprehry.
- Aktualny cisty patchset po cleanup-e je gate-green a reprodukuje rovnaky P0 symptom (`W=0 D=0 L=2`).
- Rozsireny C77 smoke (4 hry) stale `W=0 D=0 L=4`.
- C77 pivot je stabilny uz od skorých ply (`12` a `16`): baseline vs safe sa rozchadzaju v bestmove aj cp.
- Posledny overeny baseline je stabilny:
  - `make chess-static` PASS
  - `make test` PASS
  - `make strength-gate` PASS (`BF 1/3`, `Arasan 33/200`)
  - C77 smoke ostava `W=0 D=0 L=2` (2 hry) / `W=0 D=0 L=4` (4 hry)

### Najblizsie uzatvoritelne kroky

1. Rozsirit checkpoint compare z jednej pozicie na viac C77 checkpointov a vybrat jeden stabilny pivot.
2. Prejst C77 checkpointy po ply 20-28 s detailom `root_top + pv`, vybrat dalsi pivot (nie tie-break).
3. Aplikovat jeden cieleny patch na novy pivot (search/eval), bez dalsieho broad sweepu.
4. Ulohu uzavriet az po `C77 smoke != 0-2` a naslednom `make strength-gate` PASS.

## Poznamka k historii

- Uzavrete a historicke session (E0-E9, TB rollout, tuning kampane) su v archive:
  - SESSION_LOG_ARCHIVE_20261002.md

## Session: 2026-10-06 (Rootfull uzaver + smer dalsich prac)

### Uzavrete dnes

- Rootfull hypotéza je formalne uzavreta ako vyvratena pre ship variant.
- Plny depth-based mini A/B (candidate `chess-static-rootfull` vs baseline `chess-static`) bol dokončeny detached behom a ulozeny v [scratch/ab_full_d14_d6_20261006.log](scratch/ab_full_d14_d6_20261006.log).
- Vysledky A/B summary:
  - BF depth 14: `2/3` vs `2/3` (delta `0`)
  - Arasan depth 6: `19/200` vs `19/200` (delta `0`)
  - Cena candidate (nodes/time):
    - BF: `69,209,823 / 401,088 ms` vs baseline `37,212,744 / 174,314 ms`
    - Arasan: `10,700,446 / 57,453 ms` vs baseline `2,721,220 / 14,466 ms`

### Zaver

- Mechanizmus lock-in je reprodukovatelny na konkretnych uzloch, ale jeho agregovany dopad na `arasan2026` pri fixnej hlbke je pod prahom detekcie (delta `0`).
- Globalny rootfull neprinasa meratelne quality zlepsenie a ma vyraznu vykonnostnu dan, preto sa odklada.
- Search linia okolo root full-window variantov je uzavreta; dalsie iteracie na tomto smere neprioritizovat.

### Dalsie priority (poradie)

1. Adaptivny trigger ako hygienicky patch (nie Elo bet): full-window pre top kandidaty z predch. iteracie len pri nestabilite (flip-flop/mala cp marza), cielit node penalty < 5 %.
2. Root ordering vetva (bez globalnej NPS dane): lepsie vyuzitie poradia z predch. iteracie + TT move preferencia na roote.
3. Hlavna investicia mimo search tuning: eval/NNUE pipeline (Bullet trener, HalfKP architektura, kvalitnejsie labelovane data) + priprava robustneho SPRT self-play harnessu.

### Delta update (2026-10-06, po uzavere rootfull)

- Implementovany adaptivny root trigger (hygienicky patch):
  - default PVS full-window len pre prvy root tah,
  - pri nestabilite sa full-window rozsiri iba na root top-3 tahy z predchadzajucej iteracie,
  - nestabilita = mala marza (`top1-top2 <= 20 cp`) alebo flip-flop vzor `best(d-1)==best(d-3)!=best(d-2)`.
- Dotknute subory:
  - [src/search/00_header.asm](src/search/00_header.asm)
  - [src/search/50_root_search.asm](src/search/50_root_search.asm)
- Validacia po patchi:
  - `make chess-static` PASS
  - `make test` PASS
  - `make strength-gate` PASS (`BF 2/3`, `Arasan 19/200`)
- Poznamka k porovnaniu ceny patchu:
  - rychly A/B proti `chess-static-safe` sa v tejto session nespustil, lebo binarka `./chess-static-safe` nebola dostupna/executable (`MISSING chess-static-safe`).
  - na kvantifikaciu node penalty bude treba explicitne ulozit referencny baseline binar (`cp chess-static chess-static-baseline`) pred dalsimi search patchmi.

### Delta update 2 (2026-10-06, retroaktivne node-penalty meranie)

- Baseline vs candidate boli zrekonstruovane retroaktivne bez cakania na dalsi patch:
  - baseline: docasny rollback iba v [src/search/00_header.asm](src/search/00_header.asm) a [src/search/50_root_search.asm](src/search/50_root_search.asm), build -> `chess-static-baseline`
  - candidate: restore backupov tychto dvoch suborov, build -> `chess-static-adaptive`
- Deterministicke fixed-depth porovnanie na `tests/suites/external/arasan2026.epd` (head 100) pri depth 6:
  - baseline: `hits=10/100 nodes=1,446,777 time_ms=8,983`
  - adaptive: `hits=13/100 nodes=553,519 time_ms=3,706`
- Vypocitana node delta (adaptive vs baseline): `-61.7 %` (adaptive prehladal menej uzlov).

### Rozhodnutie

- Adaptivny trigger patch zostava v strome.
- Kriterium node penalty `< 5 %` je splnene s velkou rezervou (delta je zaporna).
- Smer pre dalsiu search pracu: root ordering vetva, potom eval/NNUE hlavna linia.

### Delta update 3 (2026-10-06, integritny audit po podozrivom node delta)

- Predchadzajuci zaznam `-61.7 % nodes` bol oznaceny ako metodicky podozrivy a bol kompletne re-checknuty.
- Audit bol rozdeleny na 3 explicitne kontroly:
  1. clean rebuild integrita pre adaptive aj no-trigger variant,
  2. trigger-frekvencny audit,
  3. diff-scope verifikacia medzi porovnavanymi binarkami.

#### 1) Clean rebuild integrita (PASS)

- Adaptive build reproducibilita:
  - hash #1: `0e12b4ab0545c667f49967a46f9d64809231d86e4cb03700662da3a154f9b64f`
  - hash #2: `0e12b4ab0545c667f49967a46f9d64809231d86e4cb03700662da3a154f9b64f`
  - stav: PASS (bit-identicke)
- No-trigger build reproducibilita:
  - hash #1: `a84f62dc6c678de5920558aad1beed56c4f8ae65ab6cbb56f5cfe73e86c772a8`
  - hash #2: `a84f62dc6c678de5920558aad1beed56c4f8ae65ab6cbb56f5cfe73e86c772a8`
  - stav: PASS (bit-identicke)
- Restore integrita adaptive stromu po docasnom no-trigger prepise:
  - adaptive hash po restore: `0e12b4ab0545c667f49967a46f9d64809231d86e4cb03700662da3a154f9b64f`
  - porovnanie s povodnym adaptive hash: PASS

#### 2) Trigger-frekvencny audit

- Proxy audit cez `root_top` sekvencie na vzorke 50 FEN (depth 6):
  - eligible iteracie: `156`
  - iteracie splnajuce adaptivne trigger podmienky: `143`
  - odhadovana aktivacna miera: `91.67 %`
- Poznamka: ide o aktivaciu podmienky, nie priamy pocet uspesnych PVS re-search udalosti.

#### 3) Diff-scope verifikacia medzi porovnavanymi variantmi

- Dočasny no-trigger variant sa lisil od adaptive presne 1 riadkom v [src/search/50_root_search.asm](src/search/50_root_search.asm):
  - `mov byte [root_adapt_active], 1` -> `mov byte [root_adapt_active], 0`
- Binarne porovnanie adaptive vs no-trigger: NIE su identicke (ocakavane), ale scope zdrojovej zmeny je 1-line.

#### Re-run klucoveho porovnania (strict clean)

- `suite scratch/arasan100.epd 6`:
  - adaptive: `hits=13/100 nodes=553,519 time_ms=3,249`
  - no-trigger: `hits=13/100 nodes=553,519 time_ms=3,246`
- Interpretacia: node delta je `0` (deterministicky identicky), predosle `-61.7 %` nebolo reprodukovatelne na cistom kontrolovanom postupe.

### Upraveny zaver

- Predchadzajuci claim o velkej zapornej node delte sa stahuje ako nereprodukovatelny artefakt.
- Pri strict clean protokole je adaptive vs no-trigger na `arasan100 d6` ekvivalentny (hity aj nodes).
- Adaptivny patch je zatial metodicky neutralny; ak sa ma ponechat/odstranit, rozhodnutie treba opierat o vacsi fixed-depth set a najma o time-control A/B/SPRT.

### Delta update 4 (2026-10-06, forenzna lokalizacia priciny + cleanup)

- Stav trackingu: commit-range diff `pre-trigger..HEAD` pre [src/search/00_header.asm](src/search/00_header.asm) a [src/search/50_root_search.asm](src/search/50_root_search.asm) nebol mozny, lebo `src/search/` je v tejto vetve stale `??` (untracked split modul).
- Nahradna forenzna metoda: izolacne temp buildy s jednou policy zmenou.

#### A) Test historickej root-window politiky (first-8 full-window)

- Dočasny patch iba v [src/search/50_root_search.asm](src/search/50_root_search.asm):
  - namiesto first-move-only PVS bolo zapnute `cmp rcx, 8` -> first-8 full-window.
- `suite scratch/arasan100.epd 6` vysledok:
  - `hits=10/100 nodes=1,160,683 time_ms=5,945`
- Tento profil je v rovnakom smere a rozsahu ako podozrivy "vysoky nodes baseline" (radovo 1M+), t.j. skok je konzistentny s rootfull-like politikou.

#### B) Cleanup dead adaptive trigger

- Adaptive trigger bol odstraneny zo search cesty ako mrtvy patch:
  - odstranene state polia z [src/search/00_header.asm](src/search/00_header.asm),
  - odstranena trigger logika a top-3/margin bookkeeping z [src/search/50_root_search.asm](src/search/50_root_search.asm),
  - explicitny root policy ostava: full-window len pre prvy tah, ostatne PVS/null-window.
- Build po cleanupe: `make clean && make chess-static` PASS.
- Deterministicky check (`arasan100 d6`, 3x):
  - stabilne `hits=13/100 nodes=638,292` (cas kolise, nodes fixne).

### Pracovny zaver po forenznom teste

- Najsilnejsi kandidat povodneho `-61.7 %` artefaktu je rozdiel v root-window politike (rootfull-like rezim), nie adaptivny trigger flag.
- Search branch nie je uzatvorena: treba este presne datovat, v ktorom momente sa do baseline mixol rootfull-like behavior (ked budu split subory commitnute, urobit cisty commit-range blame/diff).

### Delta update 5 (2026-10-06, rozlusknutie 553,519 -> 638,292)

- Rozpor bol vysvetleny: nejde o line 321 restore ani o BSS offset shift.
- Cielena ablacia na [src/search/50_root_search.asm](src/search/50_root_search.asm) ukazala:
  - base (adaptive): `553,519` nodes,
  - `v1_no_init` (bez init resetu adaptive premennych): `553,519`,
  - `v3_no_gate` (bez gate vetvy root_full pre top-3): `553,519`,
  - `v2_no_compute` (bez compute bloku pred move loop): `638,292`,
  - `v4_no_tail` (bez tail bookkeepingu): `638,292`.

#### Priama pricina

- Adaptive compute blok pred `.move_loop` clobberuje `ecx` (loop index root slucky).
- Po `xor rcx, rcx` je `ecx` znovu prepisany (`mov ecx, [root_prev3_best_move]`) a pred vstupom do `.move_loop` sa index neobnovi na 0.
- Dsledok: root loop zacina z nespravneho indexu, prehlada menej root tahov a nodes umelo klesnu.

#### Potvrdenie hypotézy

- Mikrofix `xor ecx, ecx` na `.adapt_ready` (bez inych zmien) okamzite dava `638,292` nodes pri rovnakom hitrate `13/100`.
- T.j. rozdiel `553,519 -> 638,292` je cisty register-clobber side effect, nie „inertny trigger“.

#### Stav po cleanupe

- Adaptive trigger kod bol odstranený zo stromu (non-ship).
- Explicitna root politika: full-window len pre prvy root tah, ostatne PVS/null-window.
- Aktuálny deterministický check (`arasan100 d6`, 2x):
  - `hits=13/100 nodes=638,292` (stabilne),
  - root8 benchmark ostava horsi a drahsi (`1,160,683`, `10/100`) -> definitivne odlozeny.

### Delta update 6 (2026-10-06, baseline commit + 200-case uzaver)

- Baseline bol zafixovany commitom `4134232`:
  - politika: first-move full-window only, zvysok root tahov PVS/null-window,
  - experimentalny adaptive trigger odstranený (non-ship),
  - root loop integrita explicitna (index od 0, bez clobber side effectu).

- Kontrolny fingerprint (external100, depth 6):
  - `hits=13/100 nodes=638,292`.

- Uzatvaracie porovnanie politik (external 200-case suite, depth 6):
  - baseline: `hits=21/200 nodes=1,190,142 time_ms=7,642`,
  - root8: `hits=19/200 nodes=2,718,957 time_ms=13,491`.

- Zaver:
  - root8 je jednoznacne drahsi (~2.28x nodes) a slabsi na hitoch,
  - defaultna politika first-move-only je potvrdena ako finalny root window default.

### Delta update 7 (2026-10-06, post-push fingerprint pre commit 91a2d26)

- Commit `91a2d26` bol pushnuty pred tymto kontrolnym fingerprint runom.
- Ciel kontroly: porovnat ordering-only top-3 root hint proti baseline `4134232`.

#### Baseline fingerprint (4134232)

- external100 d6: `hits=13/100 nodes=638,292`
- external200 d6: `hits=21/200 nodes=1,190,142`

#### Post-push fingerprint (91a2d26, clean build)

- external100 d6: `hits=16/100 nodes=653,196`
- external200 d6: `hits=24/200 nodes=1,262,407`

#### Verdikt vs ordering kriterium

- `hits` neklesli (zlepsenie +3 na 100-case, +3 na 200-case).
- `nodes` neklesli (narast `+14,904` na 100-case, `+72,265` na 200-case).
- Podla prisneho ordering kriterialneho filtra (`nodes <= baseline` a `hits >= baseline`) nejde o cisty gain.

#### Stav

- Commit ostava na remote, ale fingerprint smer je zmiesany: kvalita hore za cenu vyssieho poctu uzlov.
- Pred dalsim rozvojom tejto vetvy je vhodne rozhodnutie: okamzity revert vs. cieleny retune bonusov top-3 hintu.

### Delta update 8 (2026-10-06, SPRT run metadata zapis pred verdictom)

- Bezi dlhy SPRT beh baseline vs hint s limitom `2000` hier.
- Terminal ID: `27a53d0a-bb9b-4a63-9909-0872605d5b3f`.
- Log subor: `scratch/sprt_4134232_vs_91a2d26_10p0.1_elo0_elo1_20261006.log`.
- PGN vystup: `scratch/sprt_4134232_vs_91a2d26_20261006.pgn`.
- Konfiguracia behu:
  - `-sprt elo0=0 elo1=4 alpha=0.05 beta=0.05`
  - `tc=10+0.1`, `Threads=1`, `Hash=64`, `OwnBook=false`, `-repeat`
  - openings: `utils/LumbrasGigaBase_OTB_1990-1999.pgn` (format `pgn`, `order=random`)
- Stav pri zapise: beh prebieha, zatial bez `H0/H1` verdict riadku.

### Delta update 9 (2026-10-06, final SPRT vysledok baseline vs top-3 hint)

- Beh dosiahol limit `2000` hier bez skorého SPRT rozhodnutia.
- Final score (baseline vs hint): `763 - 699 - 538` (`0.516`).
- Split podla farby:
  - baseline White: `401 - 326 - 273` (`0.537`)
  - baseline Black: `362 - 373 - 265` (`0.494`)
  - White vs Black (global): `774 - 688 - 538` (`0.521`)
- Cutechess sumár:
  - `Elo difference: 11.1 +/- 13.0`
  - `LOS: 95.3 %`
  - `SPRT: llr 0.827`, hranice `[-2.94, 2.94]`
  - `Finished match` (bez `H0 accepted` / `H1 accepted`)

#### Interpretacia pre rozhodnutie

- V tejto konfiguracii je stred odhadu v prospech baseline (nie hintu).
- Keďže nejde o potvrdenie zlepšenia hint variantu a bodový odhad je proti hintu,
  prakticky to vychádza na revert top-3 hint zmeny, alebo aspoň nechať mimo ship vetvu.

### Delta update 10 (2026-10-06, final closure ordering line)

- Rozhodnutie podla vopred zaregistrovaneho pravidla: **revert ordering hint**.
- Dovod: fixed-depth hit gain sa nepreniesol do hernej sily pod casom.
- Final metriky z 2000h SPRT (10+0.1):
  - score: `763-699-538` (baseline vs hint)
  - Elo diff: `+11.1 +/- 13.0` pre baseline
  - LOS: `95.3%` pre baseline
  - LLR: `0.827` (nedecided v ramci hranic `[-2.94, 2.94]`)
  - prakticka CI interpretacia: priblizne `[-2, +25]` Elo
- Pragmaticky verdict: cena dalsieho merania prevysuje hodnotu udrzania hint vetvy,
  preto je revert lacnejsi a bezpecnejsi krok.

#### Policy update

- Search zmeny sa odteraz posudzuju primarne cez SPRT.
- Fixed-depth fingerprint je len lokalny diagnosticky signal search spravania,
  nie ship kritérium.

### Delta update 11 (2026-10-06, Bullet/NNUE line open)

- Spusteny prvy Bullet SPRT smoke na overenie NNUE signalu v rychlom TC.
- Pairing: rovnaky binar `./chess-static`, rozdiel iba UCI option `EvalMode`:
  - NEW: `EvalMode=2` (NNUE)
  - BASE: `EvalMode=0` (classic)
- Parametre behu:
  - `tc=1+0.01`, `games=200`, `concurrency=2`, `Hash=64`, `Threads=1`
  - `OwnBook=false` na oboch stranach
  - openings: `utils/LumbrasGigaBase_OTB_1990-1999.pgn` (`random`, `plies=8`, `srand=20261006`)
  - `SPRT: elo0=0 elo1=8 alpha=0.05 beta=0.05`
- Artefakty:
  - log: `scratch/sprt_bullet_nnue2_vs_classic0_20261006.log`
  - pgn: `scratch/sprt_bullet_nnue2_vs_classic0_20261006.pgn`

### Delta update 12 (2026-10-06, Bullet/NNUE smoke verdict)

- Bullet smoke bol ukonceny pred limitom na SPRT hranici.
- Final score (NNUE vs CLASSIC): `0 - 65 - 3` (`0.022`) po 68 zapocitanych hrach.
- Cutechess sumár:
  - `Elo difference: -658.7 +/- nan`
  - `LOS: 0.0%`
  - `DrawRatio: 4.4%`
  - `SPRT: llr -2.95`, hranice `[-2.94, 2.94]` -> `H0 was accepted`
- Poznamka k behu: jedna hra bola ukoncena ako `No result` pri zastaveni matche po dosiahnuti SPRT hranice.

#### Interpretacia

- V aktualnej konfiguracii je `EvalMode=2` neschopny konkurovat `EvalMode=0` ani v bullet smoke.
- Pred dalsim NNUE SPRT je potrebna technicka diagnostika rezimu `EvalMode=2`
  (init/load siete, feature update, scaling, fallback cesty).

### Delta update 13 (2026-10-06, scale/correlation audit pred dalsimi hrami)

- Spusteny lacny audit nad `400` poziciami (`200 arasan + 100 STS1 + 100 SBD`), depth-1,
  `OwnBook=false`, porovnanie `EvalMode=0` vs `EvalMode=2`.
- Sumar metrik:
  - `sign_agree_rate = 0.9821` (219/223 nenulovych parov)
  - `pearson = 0.6966`
  - `spearman = 0.8130`
  - `median |eval2|/|eval0| = 0.4122`
  - rozsah classic: `[-1081, 533]`
  - rozsah NNUE: `[-339, 360]`
- Doplnenie:
  - sign mismatch iba `4` pozicie,
  - no vela pripadov ma velky rozdiel amplitudy (casto `eval2 = 0` pri silno negativnom classic score).
- Interpretacia:
  - nejde primarne o nahodny sum; signal je konzistentny so silnou kompresiou/skalovacim problemom
    v `EvalMode=2` ceste, co vie rozbit pruning kalibraciu pod casom.
- Artefakty auditu:
  - `scratch/evalmode_scale_audit_20261006.tsv`
  - `scratch/evalmode_scale_audit_20261006.txt`

### Delta update 14 (2026-10-06, linear scale trial + smoke verdict)

- Bol otestovany rychly linear post-scale experiment pre `EvalMode=2`
  (fit faktor z LS auditu, kratka inference korekcia v evaluate).
- Re-audit po patchi ukazal len ciastocny posun rozsahu, ale horsiu zhodu:
  - `median |eval2|/|eval0| = 0.4572`
  - `range mode2 = [-713, 582]`
  - `pearson = 0.5355`, `spearman = 0.6737`, `sign_agree_rate = 0.8981`
  - artefakty: `scratch/evalmode_scale_audit_20261006_postscale.tsv` + `.txt`
- Následny bullet SPRT smoke (`tc=1+0.01`) stale skoncil okamzitym killom:
  - score (NNUE_SCALED vs CLASSIC): `0-55-5` (60 zapocitanych)
  - `Elo difference: -544.7 +/- 217.3`
  - `SPRT llr -2.96` -> `H0 was accepted`
  - log: `scratch/sprt_bullet_nnue2_scaled_vs_classic0_20261006.log`
- Verdikt: samotny linear scale fix nevysvetluje/protiopatruje kolaps pod casom.
- Experiment bol po overeni rollbacknuty (zmena sa neudrzala v aktivej vetve).

### Delta update 15 (2026-10-06, accumulator path audit)

- Krok 2 (incremental make/unmake konzistencia) bol preverený na legalnych sekvenciach.
- Random path audit:
  - `500` vzoriek cez `position startpos moves ...` + `evalstate`
  - výsledok: `mismatches=0`, `first_mismatch=none`
  - coverage: `captures=66`, `en-passant=1`, `castles=1`, `promotions=0`
  - artefakty: `scratch/nnue_acc_path_audit_20261006.tsv` + `.txt`
- Cielene special-move scenare:
  - white/black castling, en-passant, promotion (Q/N)
  - výsledok: `cases=5 mismatches=0`
  - artefakt: `scratch/nnue_acc_special_moves_20261006.tsv`

#### Interpretacia

- Pri doteraz pokrytych cestach sa acc drift nepotvrdil.
- Kolaps `EvalMode=2` pod časom teda pravdepodobne nie je trivialny bug v delta update,
  ale skôr interakcia kalibracie/heuristik (pruning gates, post-korekcie, confidence fallback).
