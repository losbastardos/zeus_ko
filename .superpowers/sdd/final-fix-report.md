# Final review fix report — feature/lazy-smp

Dátum: 2026-09-29
Commit: `smp: fix wave z finalneho review (munmap stackov, spawn guard, clamp threads 0)`

## Implementované body (všetkých 7)

1. **[Important] Munmap helper stackov v `smp_stop_and_reap`** (`src/smp.asm`):
   po reap slučke nová časť `.unmap_stacks`: pre i = 1..7, ak
   `[smp_stack_tops + i*8 - 8] != 0` → `munmap(top - SMP_STACK_SIZE, SMP_STACK_SIZE)`
   (SYS_MUNMAP = 11, nový `%define`), slot sa vynuluje. Uvoľnia sa aj stacky
   helperov, ktorým `clone` zlyhal (ich sloty boli nastavené pri mmap). Predtým
   sa pri každom `go` leaklo až 7×8 MiB.
2. **Spawn guard pri zlyhaní `smp_init`** (`src/uci.asm`, vetva `.no_book`):
   pred `call smp_spawn_helpers` sa testuje `[smp_shared]`, pri 0 sa preskočí
   na `.id_loop` (inak by helperi pri `go infinite` bežali bez stop koordinácie
   do depth 64). Pridaný `extern smp_shared`.
3. **Clamp `go threads 0`** (`src/uci.asm`, `.parse_threads`): odstránené
   `test rax,rax; jz .after_parse` — clamp `0→1` (už existujúci `cmp rax,1/jge`)
   rieši minimum a parsing riadka pokračuje (`go threads 0 depth 7` spracuje
   aj `depth 7`). Overené: rovnaký čas hľadania ako `go depth 10` s OwnBook vypnutým.
4. **Dead `jmp .no_book`** (`src/uci.asm`): mŕtvy unreachable skok za
   `jmp .do_move` zmazaný.
5. **Mŕtvy `push rbx` v `smp_stop_and_reap`** (`src/smp.asm`): push aj pop rbx
   zmazané (rbx sa v reap nepoužíva; v `smp_spawn_helpers` zostal, tam sa používa).
6. **Dead define `SMP_STOP_OK`** (`src/smp.asm`): zmazané.
7. **Komentár do `tt_probe`** (`src/tt.asm`): zakotvený invariant — hash sa číta
   až po payload kvôli lock-free store protokolu v `tt_store`
   (payload → mfence → hash); poradie čítania nesmie byť otočené.

## Diff súhrn

- `src/smp.asm`: +SYS_MUNMAP define, −SMP_STOP_OK, reap slučka presmerovaná
  na `.unmap_stacks`, nová munmap slučka (index `ecx`, len syscalls, žiadne
  callee-saved navyše), odstránené push/pop rbx.
- `src/uci.asm`: +`extern smp_shared`, spawn guard, −test/jz v .parse_threads,
  −dead `jmp .no_book`.
- `src/tt.asm`: +invariant komentár pri `tt_probe`.

## Výsledky testov

- `make chess && make chess-static` — OK.
- `perft 4` = 197 281, `perft 5` = 4 865 609 — OK.
- `go depth 6 threads 2` (UCI, start FEN) — `bestmove b1a3`, čistý exit.
- **VmSize / ulimit meranie (bod 1)**:
  - `ulimit -v 200000; for i in $(seq 20); do printf "uci\ngo depth 8 threads 4\nquit\n" | ./chess-static --uci >/dev/null; done` — všetkých 20 behov prešlo (pri pretrvávajúcom leaku by 20×3×8 MiB ≈ 480 MB limit spadol).
  - Jeden proces, 12× `go depth 8 threads 4` za sebou: peak VmSize stabilných **232 492 kB** (TT mmap), 12× bestmove. Žiadny rast.
- `go threads 0 depth 10` (OwnBook false): rovnaký runtime ~0,23 s ako `go depth 10` → clamp + plné spracovanie riadka OK.
- `bash tests/regression.sh` — passed.
- cutechess-cli smoke (10 hier, 10+0.1, `-recover`, Threads=1 vs Threads=2,
  sequential openings, plies=8): **10/10 hier dokončených, 0 forfeits**
  (6× remíza — 4× 3-fold, 2× pat; 4× rozhodnuté — cand 3 : smp2 1 výhier).
  `-recover` nepripojilo žiadne polacie. Čistý beh bez pádu engine.

## Concerns

- Žiadne zásahy do search/SMP logiky okrem bodov 1–2 podľa zadania; heuristiky
  netknuté.

## Fix round 2

Re-review round 2 odhalil skutočný bug v bode 1: `.unmap_loop` držal counter v
ECX, ale `syscall` vždy prepíše RCX (return RIP) — po prvom munmape slučka
skončila a sloty 2–7 leakovali. Pre Threads=2 (1 helper) to nebolo viditeľné.

Oprava: counter presunutý do EBX s `push rbx` na začiatku `.unmap_stacks` a
`pop rbx` v `.unmap_done` (funkcia zostáva vyvážená; v slučke nie sú call-y,
iba syscalls). Logika munmap sa nemení (base = top − SMP_STACK_SIZE, len
SMP_STACK_SIZE, slot vynulovať, prázdne sloty preskočiť).

Testy po oprave:
- `make chess-static` — OK.
- VmSize v JEDNOM procese, 2× `go depth 10 threads 4` (3 helperi = 24 MiB stackov
  na go): 232 492 kB po starte / po go #1 / po go #2 — identické, žiadny +24 MiB.
- `perft 4` = 197 281 — OK.
- `tests/regression.sh` — passed.

Commit: amend do fix wave commitu.
