; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; search.asm - NegaMax search s make/unmake
; ============================================================

%include "chess.inc"

DEFAULT REL

; Search pruning konstanty (E9)
RAZOR_MARGIN    equ 250         ; razoring: eval + margin < alpha pri depth 1
FUTILITY_MARGIN equ 150         ; futility: margin = FUTILITY_MARGIN * depth (d1: 150, d2: 300)
EVAL_NONE       equ 0x7FFFFF00  ; sentinel: ziadny static eval (uzol v sachu)

section .data

q_capture_value:
    dd 0, 100, 320, 330, 500, 900, 0

section .bss

undo_stack:     resb 64*16      ; miesto pre 64 undo zaznamov
undo_sp:        resq 1          ; offset (v bajtoch) do undo_stack
search_timespec: resq 2
search_ply:     resq 1          ; vzdialenost od rootu (pre mat skore + kille)
killers:        resd 2*64       ; dva killer tahy na kazdy ply
history:        resd 2*64*64    ; [side][from][to] history heuristic
cap_history:    resd 6*64*6     ; [figura][to][obet] capture history heuristic
countermoves:   resw 64*64      ; [prev_from][prev_to] -> quiet tah, ktory refutoval
move_stack:     resw 64         ; tah odohrany na danom ply (0 = null ply)
eval_stack:     resd 64         ; static eval na kazdom ply (pre improving flag)
root_best_move: resd 1          ; best move z predchadzajucej ID iteracie
null_stack:     resb 64*16      ; ulozene stavy pre null-move (side/ep/hash/halfmove)
asp_alpha:      resd 1          ; aspiration window (root)
asp_beta:       resd 1
asp_delta:      resd 1
asp_use:        resd 1          ; 1 = pouzi asp window (nastavuje uci_go)
asp_retry:      resd 1          ; pocet aspiration re-search retry
asp_prev_depth: resd 1          ; hlbska z predch. iteracie (kontrola continuity ID)
root_alpha:     resd 1          ; aktualne alpha v root slucke

section .text

global make_move, unmake_move, quiescence, negamax, search_best_move, perft
global asp_alpha, asp_beta, asp_delta, asp_use, asp_retry

extern board, side, castle, enpassant, halfmove, fullmove
extern moved_piece, captured_piece
extern move_list, move_count
extern pv_moves, pv_moves_len
extern nodes_searched, search_last_score
extern search_limits, uci_stop_flag
extern apply_move, update_position_state
extern generate_all_moves, is_in_check, evaluate
extern see
extern compute_hash
extern tt_probe, tt_store, position_hash
extern check_repetition
extern hash_history, hash_count
extern tb_piece_count, tb_probe_wdl
extern search_poll_input

; ============================================================
; check_time - periodicka kontrola timeoutu pre UCI search
; Vystup: eax = 1 ak treba zastavit, inak 0
; Pozor: volajuce negamax/quiescence maju v rdi/rsi/rdx/rcx argumenty
; (ukladaju ich az po call), preto su tu okrem rbx ulozene aj tie.
; ============================================================
check_time:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    cmp byte [uci_stop_flag], 0
    je .poll_input
    mov eax, 1
    jmp .ret

.poll_input:
    ; neblokujuce spracovanie stdin (stop/ponderhit/isready/quit)
    ; len kazdych 1024 nodov; aj v mode 3/4, inak by stop nikdy neprisiel
    mov rax, [nodes_searched]
    and rax, 1023
    jnz .check_mode
    call search_poll_input
    cmp byte [uci_stop_flag], 0
    je .check_mode
    mov eax, 1
    jmp .ret

.check_mode:
    movzx eax, byte [search_limits + 0] ; mode
    cmp eax, 3                           ; infinite
    je .no_stop
    cmp eax, 4                           ; ponder
    je .no_stop

    mov rax, [search_limits + 64]        ; hard_limit ms
    test rax, rax
    jz .no_stop

    mov rax, [nodes_searched]
    and rax, 1023
    jnz .no_stop

    mov rax, SYS_CLOCK_GETTIME
    mov rdi, CLOCK_MONOTONIC
    lea rsi, [search_timespec]
    syscall
    test rax, rax
    js .no_stop

    mov rax, [search_timespec]
    imul rax, 1000
    mov rbx, rax
    mov rax, [search_timespec + 8]
    mov rcx, 1000000
    xor rdx, rdx
    div rcx
    add rax, rbx
    sub rax, [search_limits + 48]        ; elapsed ms

    cmp rax, [search_limits + 64]
    jl .no_stop
    mov byte [uci_stop_flag], 1
    mov eax, 1
    jmp .ret

.no_stop:
    xor eax, eax

.ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; make_move - aplikuje tah a ulozi undo informacie do undo_stack
; Vstup: ax = 16-bitovy tah
; ============================================================
make_move:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r15, rax            ; uloz cely tah

    ; vypocitaj adresu undo zaznamu
    lea r14, [undo_stack]
    mov r13, [undo_sp]
    lea r12, [r14 + r13]

    ; uloz from, to, flags
    movzx rax, r15w
    and rax, 0x3F
    mov [r12 + 0], al       ; from
    movzx rax, r15w
    shr rax, 6
    and rax, 0x3F
    mov [r12 + 1], al       ; to
    movzx rax, r15w
    shr rax, 12
    mov [r12 + 2], al       ; flags

    ; uloz staru poziciu
    mov al, [side]
    mov [r12 + 5], al
    mov al, [castle]
    mov [r12 + 6], al
    mov al, [enpassant]
    mov [r12 + 7], al
    mov al, [halfmove]
    mov [r12 + 8], al
    mov ax, [fullmove]
    mov [r12 + 9], ax

    mov rax, r15
    call apply_move

    mov al, [moved_piece]
    mov [r12 + 3], al
    mov al, [captured_piece]
    mov [r12 + 4], al

    mov rax, r15
    call update_position_state

    push r14
    push r15
    call compute_hash
    pop r15
    pop r14

    ; move_stack[ply] = tah (countermove heuristic; null ply nuluje negamax)
    mov rcx, [search_ply]
    cmp rcx, 64
    jae .skip_move_stack
    lea rdx, [move_stack]
    mov [rdx + rcx*2], r15w
.skip_move_stack:

    add r13, 16
    mov [undo_sp], r13

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; unmake_move - obnovi poziciu z undo_stack
; ============================================================
unmake_move:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rax                ; zachovaj vysledok pre volajuceho (telo ho prepise)

    ; posun sa na posledny undo zaznam
    mov r13, [undo_sp]
    sub r13, 16
    mov [undo_sp], r13
    lea r14, [undo_stack]
    lea r12, [r14 + r13]

    ; najprv nacitaj flags a stav (este mame platny base v r12)
    movzx r8, byte [r12 + 2]    ; flags
    movzx r9, byte [r12 + 5]    ; side
    movzx r10, byte [r12 + 6]   ; castle
    movzx r11, byte [r12 + 7]   ; enpassant
    movzx rbx, byte [r12 + 8]   ; halfmove
    movzx rax, word [r12 + 9]   ; fullmove

    ; uloz stav spat do pamate
    mov [side], r9b
    mov [castle], r10b
    mov [enpassant], r11b
    mov [halfmove], bl
    mov [fullmove], ax

    ; nacitaj tahove informacie
    movzx r15, byte [r12 + 3]   ; moved_piece
    movzx r14, byte [r12 + 4]   ; captured_piece
    movzx r13, byte [r12 + 0]   ; from
    movzx r12d, byte [r12 + 1]  ; to (prepise base)

    mov [moved_piece], r15b
    mov [captured_piece], r14b

    ; obnov sachovnicu
    lea rsi, [board]
    mov [rsi + r13], r15b       ; board[from] = moved_piece

    cmp r8, FLAG_ENPASSANT
    je .undo_ep
    cmp r8, FLAG_CASTLE
    je .undo_castle

    ; normalny tah / promocia
    mov [rsi + r12], r14b
    jmp .done

.undo_ep:
    mov byte [rsi + r12], EMPTY
    movzx rax, byte [side]
    test rax, rax
    jz .white_ep
    add r12, 8                  ; cierny bral pesiaca na to + 8
    jmp .do_ep
.white_ep:
    sub r12, 8                  ; biely bral pesiaca na to - 8
.do_ep:
    mov [rsi + r12], r14b
    jmp .done

.undo_castle:
    mov byte [rsi + r12], EMPTY
    cmp r12, 6
    je .castle_wk
    cmp r12, 2
    je .castle_wq
    cmp r12, 62
    je .castle_bk
    cmp r12, 58
    je .castle_bq
    jmp .done

.castle_wk:
    mov byte [rsi + 7], ROOK|WHITE
    mov byte [rsi + 5], EMPTY
    jmp .done
.castle_wq:
    mov byte [rsi + 0], ROOK|WHITE
    mov byte [rsi + 3], EMPTY
    jmp .done
.castle_bk:
    mov byte [rsi + 63], ROOK|BLACK
    mov byte [rsi + 61], EMPTY
    jmp .done
.castle_bq:
    mov byte [rsi + 56], ROOK|BLACK
    mov byte [rsi + 59], EMPTY

.done:
    ; prepocitaj hash obnovenej pozicie (vzdy, na vsetkych cestach)
    ; pozor: telo unmake_move prepisalo rax, povodna hodnota je na stacku
    call compute_hash
    pop rax

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; quiescence - alpha-beta na tactical tahoch (capture/promo/ep)
; Vstup:  rdi = q-hlbka, rsi = alpha, rdx = beta
; Vystup: eax = skore
; ============================================================
quiescence:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbp, rsp

    inc qword [nodes_searched]
    call check_time
    test eax, eax
    jz .qs_continue
    xor eax, eax
    jmp .qs_exit

.qs_continue:

    sub rsp, 544            ; 512B move copy + 32B locals

    mov [rbp - 8], rdi      ; q-depth
    mov [rbp - 16], rsi     ; alpha
    mov [rbp - 24], rdx     ; beta

    ; je strana na tahu v sachu?
    movzx eax, byte [side]
    call is_in_check
    mov [rbp - 40], rax     ; in_check flag (pozor: nepouzivat rbp-36, prekryva stand-pat)

    ; bezpecnostna podlaha: q-depth nechceme do nekonecna (sachove honenie)
    cmp qword [rbp - 8], -32
    jge .qs_floor_ok
    mov qword [rbp - 8], -32
.qs_floor_ok:

    ; bezpecnostny cap ply: undo_stack ma 64 zaznamov (sachove honenie
    ; v qsearch ply nemusi zastavit ani pri q-depth floor)
    cmp qword [search_ply], 60
    jl .qs_ply_ok
    call evaluate
    movzx ebx, byte [side]
    test ebx, ebx
    jz .qs_ply_done
    neg eax
.qs_ply_done:
    jmp .qs_exit
.qs_ply_ok:
    mov rax, [rbp - 40]     ; obnov in_check (evaluate prepisalo rax)

    test rax, rax
    jnz .qs_gen             ; v sachu: ziadny stand-pat, hladaj evasions

    ; stand-pat evaluacia z pohladu strany na tahu
    call evaluate
    movzx ebx, byte [side]
    test ebx, ebx
    jz .qs_eval_done
    neg eax
.qs_eval_done:
    mov dword [rbp - 32], eax

    cmp eax, dword [rbp - 24]
    jge .qs_return_standpat

    cmp eax, dword [rbp - 16]
    jle .qs_after_alpha
    movsxd rdx, eax         ; 64-bit ciste ulozenie alpha (hore bez smeti)
    mov [rbp - 16], rdx
.qs_after_alpha:

    ; q-depth vycerpana a nie v sachu: koniec (stand-pat v alpha)
    cmp qword [rbp - 8], 0
    jg .qs_gen
    mov eax, dword [rbp - 16]
    jmp .qs_exit

.qs_gen:
    call generate_all_moves
    movzx r15, word [move_count]
    test r15, r15
    jz .qs_no_moves

    lea rsi, [move_list]
    lea rdi, [rbp - 544]
    mov rcx, r15
.qs_copy_loop:
    mov ax, [rsi]
    mov [rdi], ax
    add rsi, 2
    add rdi, 2
    dec rcx
    jnz .qs_copy_loop

    mov ebx, dword [rbp - 16] ; best
    xor rcx, rcx

.qs_move_loop:
    cmp rcx, r15
    jge .qs_done

    ; --- selection ordering: brania (MVV-LVA + cap_history) dopredu ---
    ; (drive sa qsearch prehraval v poradi generovania)
    mov r10, rcx            ; best index
    mov r11d, -1            ; best score
    mov r8, rcx             ; scan index
    lea rsi, [board]

.qs_sel_loop:
    cmp r8, r15
    jge .qs_sel_done

    movzx rax, word [rbp - 544 + r8*2]
    xor edx, edx

    mov r9, rax
    shr r9, 12
    and r9, 0xF

    cmp r9, FLAG_ENPASSANT
    je .qs_sel_ep

    cmp r9, FLAG_PROMO_Q
    jb .qs_sel_cap_test
    cmp r9, FLAG_PROMO_N
    ja .qs_sel_cap_test
    add edx, 80000          ; promocia
.qs_sel_cap_test:
    movzx edi, ax
    shr rdi, 6
    and edi, 0x3F           ; to
    movzx edi, byte [rsi + rdi]
    test edi, edi
    jz .qs_sel_cmp          ; tichy tah: skore 0
    ; MVV-LVA: 200000 + 10*obet - utocnik (zaklad bezpecne nad max.
    ; quiet skore 50k+45k+40k, tiche tahy sa nikdy nemiesaju pred brania)
    and edi, PIECE_MASK
    lea r9, [q_capture_value]
    mov edi, dword [r9 + rdi*4]
    imul edi, edi, 10
    add edx, 200000
    add edx, edi
    movzx edi, ax
    and edi, 0x3F           ; from
    movzx edi, byte [rsi + rdi]
    and edi, PIECE_MASK
    sub edx, dword [r9 + rdi*4]
    ; capture history: cap_history[figura][to][obet]
    movzx edi, ax
    and edi, 0x3F           ; from
    movzx edi, byte [rsi + rdi]
    and edi, PIECE_MASK
    dec edi
    imul edi, edi, 384
    mov r9d, eax
    shr r9d, 6
    and r9d, 0x3F           ; to
    imul r9d, r9d, 6
    add edi, r9d
    mov r9d, eax
    shr r9d, 6
    and r9d, 0x3F
    movzx r9d, byte [rsi + r9]  ; obet
    and r9d, PIECE_MASK
    dec r9d
    add edi, r9d
    lea r9, [cap_history]
    add edx, dword [r9 + rdi*4]
    jmp .qs_sel_cmp

.qs_sel_ep:
    add edx, 200900         ; pesiak (EP) berie pesiaka
    mov r9d, eax
    shr r9d, 6
    and r9d, 0x3F           ; to
    imul r9d, r9d, 6        ; (PAWN-1)*384 + to*6 + (PAWN-1)
    lea rdi, [cap_history]
    add edx, dword [rdi + r9*4]

.qs_sel_cmp:
    cmp edx, r11d
    jle .qs_sel_next
    mov r11d, edx
    mov r10, r8

.qs_sel_next:
    inc r8
    jmp .qs_sel_loop

.qs_sel_done:
    cmp r10, rcx
    je .qs_sel_picked
    mov ax, [rbp - 544 + rcx*2]
    mov dx, [rbp - 544 + r10*2]
    mov [rbp - 544 + rcx*2], dx
    mov [rbp - 544 + r10*2], ax

.qs_sel_picked:
    movzx rax, word [rbp - 544 + rcx*2]

    ; v sachu su vsetky tahy evasions (bez delta pruning)
    cmp qword [rbp - 40], 0
    jne .qs_tactical

    xor edx, edx               ; tactical = 0

    mov r9, rax
    shr r9, 12
    and r9, 0xF
    cmp r9, FLAG_ENPASSANT
    jne .qs_check_promo

    ; delta pruning pre en-passant (zisk pesiaka + rezerva)
    mov r11d, dword [rbp - 32]
    add r11d, 150
    cmp r11d, dword [rbp - 16]
    jle .qs_next
    jmp .qs_tactical

.qs_check_promo:

    cmp r9, FLAG_PROMO_Q
    jb .qs_check_capture
    cmp r9, FLAG_PROMO_N
    jbe .qs_tactical

.qs_check_capture:
    mov r9, rax
    shr r9, 6
    and r9, 0x3F
    lea rsi, [board]
    movzx edx, byte [rsi + r9]
    test edx, edx
    jz .qs_next

    ; delta pruning pre beznu branu figurku
    mov r10d, edx
    and r10d, PIECE_MASK
    lea r11, [q_capture_value]
    mov r10d, dword [r11 + r10*4]
    mov r11d, dword [rbp - 32]
    add r11d, r10d
    add r11d, 50
    cmp r11d, dword [rbp - 16]
    jle .qs_next

.qs_tactical:
    ; SEE pruning: zle vymenne tahy (see < 0) preskoc; v sachu (evasions) nie
    cmp qword [rbp - 40], 0
    jne .qs_do_move
    push rcx
    call see                ; vstup: ax = aktualny tah
    pop rcx
    test eax, eax
    js .qs_next             ; see < 0: zla vymena, preskoc tah
    movzx rax, word [rbp - 544 + rcx*2] ; obnov tah (see vracia skore v eax)
.qs_do_move:
    push rcx
    call make_move
    inc qword [search_ply]

    mov rdi, [rbp - 8]
    dec rdi                 ; q-depth vzdy klesa (ukoncenie aj pri sachovych honoch)
    mov rsi, [rbp - 24]
    neg rsi
    mov rdx, [rbp - 16]
    neg rdx
    call quiescence
    neg eax
    dec qword [search_ply]

    call unmake_move
    pop rcx

    cmp eax, ebx
    jle .qs_alpha_update
    mov ebx, eax

.qs_alpha_update:
    cmp eax, dword [rbp - 16]
    jle .qs_check_cutoff
    movsxd rdx, eax         ; 64-bit ciste ulozenie alpha (hore bez smeti)
    mov [rbp - 16], rdx

.qs_check_cutoff:
    mov edx, dword [rbp - 16]
    cmp edx, dword [rbp - 24]
    jge .qs_done

.qs_next:
    inc rcx
    jmp .qs_move_loop

.qs_no_moves:
    ; ziaden tah: mat (kral v sachu) alebo pat (stand-pat)
    movzx eax, byte [side]
    call is_in_check
    test rax, rax
    jz .qs_stalemate
    mov eax, dword [search_ply]
    sub eax, MATE_SCORE
    jmp .qs_exit
.qs_stalemate:
    mov eax, dword [rbp - 32]
    jmp .qs_exit

.qs_done:
    mov eax, ebx
    jmp .qs_exit

.qs_return_standpat:
    mov eax, dword [rbp - 32]

.qs_exit:
    mov rsp, rbp
.qs_fast_exit:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================
; negamax - rekurzivny negamax s alpha-beta pruningom
; ============================================================
negamax:
    push rbp
    push rbx                ; best score
    push r12                ; quiet flag aktualneho tahu
    push r13                ; best move
    push r14                ; tt_move
    push r15                ; move count
    mov rbp, rsp

    inc qword [nodes_searched]
    call check_time
    test eax, eax
    jz .neg_continue
    xor eax, eax
    jmp .neg_exit

.neg_continue:

    ; bezpecnostny cap ply: undo_stack ma 64 zaznamov; pri ply >= 60
    ; vratime staticky eval (check extension + qsearch floor -32 by inak
    ; prekrocili kapacitu a make_move by prepisal pamat za undo_stack)
    cmp qword [search_ply], 60
    jl .ply_cap_ok
    call evaluate
    movzx ebx, byte [side]
    test ebx, ebx
    jz .ply_cap_done
    neg eax
.ply_cap_done:
    jmp .neg_exit
.ply_cap_ok:

    sub rsp, 1608           ; 512B move_list kopia + 1KB ordering klucov + lokaly

    mov [rbp - 8], rdi      ; depth
    mov [rbp - 16], rsi     ; alpha
    mov [rbp - 24], rdx     ; beta
    mov [rbp - 40], rcx     ; allow_null

    cmp qword [rbp - 8], 0
    jne .not_leaf

    mov rdi, 4              ; maximalna q-hlbka
    mov rsi, [rbp - 16]
    mov rdx, [rbp - 24]
    call quiescence
    jmp .neg_exit

.not_leaf:
    ; --- MATE DISTANCE PRUNING ---
    ; alpha >= -MATE+ply, beta <= MATE-ply; ak sa stretnu, vrat alpha
    mov rax, [search_ply]
    lea rdx, [rax - MATE_SCORE]     ; -MATE + ply (dolna hranica)
    cmp rdx, [rbp - 16]
    jle .mdp_alpha_ok
    mov [rbp - 16], rdx
.mdp_alpha_ok:
    mov rdx, MATE_SCORE
    sub rdx, rax                    ; MATE - ply (horna hranica)
    cmp rdx, [rbp - 24]
    jge .mdp_beta_ok
    mov [rbp - 24], rdx
.mdp_beta_ok:
    mov rax, [rbp - 16]
    cmp rax, [rbp - 24]
    jl .mdp_ok
    jmp .neg_exit                   ; alpha >= beta: uz nemoze byt lepsi mat
.mdp_ok:

    ; in_check flag pre cely uzol (null move, LMR, extension)
    movzx eax, byte [side]
    call is_in_check
    mov dword [rbp - 44], eax

    ; --- DETEKCIA REMIZY v search ---
    ; 50-tahove pravidlo: halfmove >= 100 -> remiza
    movzx eax, byte [halfmove]
    cmp eax, 100
    jae .draw_score
    ; opakovanie pozicie z historie hry (2. vyskyt = remiza)
    ; repetitia nemoze nastat skor ako po 4 ply od rootu
    cmp qword [search_ply], 4
    jl .no_draw
    lea rsi, [hash_history]
    mov rdx, [hash_count]
    mov rdi, [position_hash]
.draw_loop:
    test rdx, rdx
    jz .no_draw
    dec rdx
    cmp [rsi + rdx*8], rdi
    je .draw_score
    jmp .draw_loop
.draw_score:
    xor eax, eax
    jmp .neg_exit
.no_draw:

    ; --- SYZYGY TB PROBE (stub) ---
    ; ak je na sachovnici <= 7 kamenov, skus WDL probe
    ; zname skore vratime okamzite; TB_NOT_FOUND = normalny search
    ; (pouzivame len caller-saved registre, nic nie je live)
    call tb_piece_count
    cmp eax, 7
    jg .tb_skip
    call tb_probe_wdl
    cmp eax, TB_NOT_FOUND
    je .tb_skip
    cmp eax, TB_WIN
    je .tb_win
    cmp eax, TB_LOSS
    je .tb_loss
    xor eax, eax            ; TB_DRAW -> 0
    jmp .neg_exit
.tb_win:
    mov eax, 20000
    jmp .neg_exit
.tb_loss:
    mov eax, -20000
    jmp .neg_exit
.tb_skip:

    ; uloz povodne alpha pre urcenie TT flagu
    mov rax, [rbp - 16]
    mov [rbp - 32], rax     ; original_alpha
    xor r14d, r14d          ; tt_move = 0

    ; TT probe: rdi=hash, rsi=depth, rdx=alpha, rcx=beta
    mov rdi, [position_hash]
    mov rsi, [rbp - 8]
    mov rdx, [rbp - 16]
    mov rcx, [rbp - 24]
    call tt_probe
    cmp edx, 1
    je .tt_score_hit
    cmp edx, 2
    jne .tt_probe_done
    mov r14d, r8d           ; zapamataj si TT tah pre ordering
.tt_probe_done:

    ; --- IIR: pri vysokej hlbke bez TT tahu zniz hlbku o 1 ---
    cmp qword [rbp - 8], 4
    jl .iir_done
    test r14d, r14d
    jnz .iir_done
    dec qword [rbp - 8]
.iir_done:

    ; --- STATICKY EVAL + IMPROVING FLAG ---
    ; eval z pohladu strany na tahu pre kazdy ne-check uzol -> [rbp - 56]
    ; a eval_stack[ply]. improving = ply>=2 && eval > eval_stack[ply-2]
    ; (obe hodnoty musia byt platne, inak improving = 0) -> [rbp - 64]
    mov ecx, EVAL_NONE
    cmp dword [rbp - 44], 0
    jne .eval_ready                 ; v sachu: ziadny static eval
    call evaluate
    movzx ecx, byte [side]
    test ecx, ecx
    jz .eval_side_ok
    neg eax
.eval_side_ok:
    mov ecx, eax
.eval_ready:
    mov [rbp - 56], ecx             ; static eval (EVAL_NONE v sachu)
    mov rax, [search_ply]
    lea rsi, [eval_stack]
    mov [rsi + rax*4], ecx
    xor edx, edx
    cmp rax, 2
    jl .improving_done
    cmp ecx, EVAL_NONE
    je .improving_done
    mov r8d, [rsi + rax*4 - 8]      ; eval_stack[ply - 2]
    cmp r8d, EVAL_NONE
    je .improving_done
    cmp ecx, r8d
    setg dl
.improving_done:
    mov [rbp - 64], edx

    ; --- REVERSE FUTILITY PRUNING (static null move) ---
    ; !in_check && depth <= 3: eval - margin >= beta -> return eval - margin
    ; margin = 120*depth; improving (eval stupa) -> 120*(depth-1), prunej menej
    cmp dword [rbp - 44], 0
    jne .rfp_done
    cmp qword [rbp - 8], 3
    jg .rfp_done
    mov ecx, dword [rbp - 56]
    mov rdx, [rbp - 8]
    imul edx, edx, 120              ; margin = 120 * depth
    cmp dword [rbp - 64], 0
    je .rfp_margin_ok
    sub edx, 120                    ; improving: margin = 120 * (depth - 1)
.rfp_margin_ok:
    sub ecx, edx
    cmp ecx, dword [rbp - 24]       ; eval - margin >= beta?
    jl .rfp_done
    mov eax, ecx
    jmp .neg_exit
.rfp_done:

    ; --- RAZORING ---
    ; depth == 1 && !in_check && eval + RAZOR_MARGIN < alpha -> rovno qsearch
    ; (vynechame generovanie/search celeho zoznamu tahov, vratime vysledok qsearch)
    cmp qword [rbp - 8], 1
    jne .no_razoring
    cmp dword [rbp - 44], 0
    jne .no_razoring
    mov eax, dword [rbp - 56]
    add eax, RAZOR_MARGIN
    cmp eax, dword [rbp - 16]       ; eval + margin < alpha?
    jge .no_razoring
    mov rdi, 4                      ; maximalna q-hlbka (ako pri prechode do qsearch)
    mov rsi, [rbp - 16]
    mov rdx, [rbp - 24]
    call quiescence
    jmp .neg_exit
.no_razoring:

    ; --- NULL MOVE PRUNING (TT probe je vyssie, po RFP/IIR) ---
    ; ak povolene, depth >= 3, nie v sachu, nie koncovka, ply < 60
    cmp qword [rbp - 40], 0
    je .skip_null
    cmp qword [rbp - 8], 3
    jl .skip_null
    cmp dword [rbp - 44], 0
    jne .skip_null
    cmp qword [search_ply], 60
    jge .skip_null
    ; strana na tahu musi mat aspon jednu nepesiacu figuru (zugzwang)
    lea rdi, [board]
    movzx ecx, byte [side]
    shl ecx, 3
    xor edx, edx
.nn_scan:
    movzx eax, byte [rdi + rdx]
    test eax, eax
    jz .nn_next
    mov r8d, eax
    and r8d, COLOR_MASK
    cmp r8d, ecx
    jne .nn_next
    and eax, PIECE_MASK
    cmp eax, PAWN
    je .nn_next
    cmp eax, KING
    je .nn_next
    jmp .nn_ok
.nn_next:
    inc edx
    cmp edx, 64
    jl .nn_scan
    jmp .skip_null              ; same pesiaci -> ziadny null move
.nn_ok:
    ; uloz stav na null_stack[ply]
    mov rax, [search_ply]
    shl rax, 4
    lea rdi, [null_stack]
    add rdi, rax
    mov cl, [side]
    mov [rdi], cl
    mov cl, [enpassant]
    mov [rdi + 1], cl
    mov rdx, [position_hash]
    mov [rdi + 8], rdx
    ; move_stack[ply] = 0: null tah nesmie byt klucom pre countermove
    mov rcx, [search_ply]
    lea rdx, [move_stack]
    mov word [rdx + rcx*2], 0
    ; prehod stranu, zrus en passant, prepocitaj hash
    xor byte [side], 1
    mov byte [enpassant], 255
    call compute_hash
    inc qword [search_ply]
    ; search: -negamax(depth-3, -beta, -beta+1, allow_null=0)
    mov rdi, [rbp - 8]
    sub rdi, 3
    mov rsi, [rbp - 24]
    neg rsi
    mov rdx, rsi
    inc rdx                     ; -beta+1
    xor ecx, ecx
    call negamax
    neg eax
    mov ebx, eax            ; uloz skore (unmake null prepise rax)
    dec qword [search_ply]
    ; unmake null
    mov rax, [search_ply]
    shl rax, 4
    lea rdi, [null_stack]
    add rdi, rax
    mov cl, [rdi]
    mov [side], cl
    mov cl, [rdi + 1]
    mov [enpassant], cl
    mov rdx, [rdi + 8]
    mov [position_hash], rdx
    ; fail high? (ale ne mat - ten by mohol byt falesny kvoli zugzwangu)
    cmp ebx, dword [rbp - 24]
    jl .skip_null
    cmp ebx, MATE_SCORE - 100
    jge .skip_null
    mov eax, ebx
    jmp .neg_exit               ; vracia beta (fail-soft)
.skip_null:

    call generate_all_moves
    movzx r15, word [move_count]
    test r15, r15
    jnz .has_moves

    ; ziadne tahy - mat alebo pat
    movzx eax, byte [side]
    call is_in_check
    test rax, rax
    jz .stalemate
    mov eax, dword [search_ply] ; -MATE + ply: rychlejsi mat = lepsie
    sub eax, MATE_SCORE
    ; store matu do TT (EXACT, tah 0): r12 je volny
    mov r12d, eax
    mov rdi, [position_hash]
    mov rsi, [rbp - 8]
    mov edx, r12d
    xor ecx, ecx
    xor r8d, r8d
    call tt_store
    mov eax, r12d
    jmp .neg_exit
.stalemate:
    ; store patu do TT (EXACT 0)
    mov rdi, [position_hash]
    mov rsi, [rbp - 8]
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call tt_store
    xor eax, eax
    jmp .neg_exit

.has_moves:
    ; lokalna kopia zoznamu tahov, lebo rekurzia prepise globalny move_list
    lea rsi, [move_list]
    lea rdi, [rbp - 584]
    mov rcx, r15
.copy_loop:
    mov ax, [rsi]
    mov [rdi], ax
    add rsi, 2
    add rdi, 2
    dec rcx
    jnz .copy_loop

    ; countermove kluc: tah odohrany na ply-1 (0 = root/null ply)
    mov rax, [search_ply]
    test rax, rax
    jz .no_prev_move
    lea rcx, [move_stack]
    movzx eax, word [rcx + rax*2 - 2]
    jmp .prev_move_done
.no_prev_move:
    xor eax, eax
.prev_move_done:
    mov [rbp - 60], eax

    ; --- predvypocet ordering klucov (jeden SEE pass pre brania) ---
    ; kluce: [rbp-1608 + i*4]; zle brania (SEE<0) = kluc SEE < 0 (pod tiche)
    xor rcx, rcx
.key_loop:
    cmp rcx, r15
    jge .key_done

    movzx rax, word [rbp - 584 + rcx*2]
    xor edx, edx                 ; kluc = 0

    mov r9, rax
    shr r9, 12
    and r9, 0xF                  ; flags

    ; promocia?
    cmp r9, FLAG_PROMO_Q
    jb .key_not_promo
    cmp r9, FLAG_PROMO_N
    ja .key_not_promo
    add edx, 80000
.key_not_promo:

    cmp r9, FLAG_ENPASSANT
    je .key_ep                   ; EP: fixne skore (ako povodne), bez SEE

    ; branie?
    movzx edi, ax
    shr rdi, 6
    and edi, 0x3F                ; to
    lea rsi, [board]
    movzx edi, byte [rsi + rdi]
    test edi, edi
    jz .key_quiet

.key_capture:
    ; SEE ordering zlych brani (see < 0 za tiche tahy) je ZATIAL VYPNUTE:
    ; meranie d8 startpos/e4e5 = 8094/22243 uzlov (+29%/+28%) - quiet
    ; ordering v tomto engine nie je dostatocne silny, aby ich predbehol.
    ; Povodny kod: push rcx / call see / pop rcx / test eax,eax /
    ;   js .key_bad_capture / movzx rax, word [rbp - 584 + rcx*2]
    movzx rax, word [rbp - 584 + rcx*2]
    ; dobre branie: 200000 + MVV-LVA (+ live cap_history v selection)
    movzx edi, ax
    shr rdi, 6
    and edi, 0x3F                ; to
    lea rsi, [board]
    movzx edi, byte [rsi + rdi]
    and edi, PIECE_MASK
    lea r9, [q_capture_value]
    mov edi, dword [r9 + rdi*4]
    imul edi, edi, 10
    add edx, 200000
    add edx, edi
    movzx edi, ax
    and edi, 0x3F                ; from
    movzx edi, byte [rsi + rdi]
    and edi, PIECE_MASK
    sub edx, dword [r9 + rdi*4]
    jmp .key_tt_check

.key_ep:
    add edx, 200900              ; pesiak (EP) berie pesiaka
    jmp .key_tt_check

.key_bad_capture:
    ; kluc = SEE (zaporne): pod vsetky tiche tahy, menej zle prve
    add edx, eax
    jmp .key_tt_check

.key_quiet:
    test edx, edx                ; promo bez brania? nechaj 80000
    jnz .key_tt_check

    ; killer bonus
    mov r9, [search_ply]
    cmp r9, 63
    ja .key_countermove
    lea rdi, [killers]
    cmp eax, dword [rdi + r9*8]
    je .key_killer
    cmp eax, dword [rdi + r9*8 + 4]
    jne .key_countermove
.key_killer:
    add edx, 50000
.key_countermove:
    ; countermove heuristic (ply-1; 0 = root/null ply -> preskoc)
    movzx edi, word [rbp - 60]
    test edi, edi
    jz .key_tt_check
    mov r9d, edi
    and r9d, 0x3F                ; prev from
    shl r9d, 6
    shr edi, 6
    and edi, 0x3F                ; prev to
    add edi, r9d
    lea r9, [countermoves]
    movzx edi, word [r9 + rdi*2]
    cmp edi, eax
    jne .key_tt_check
    add edx, 45000               ; pod killerom, nad history
.key_tt_check:
    cmp r14w, ax                 ; TT tah ma absolutnu prioritu
    jne .key_store
    add edx, 1000000
.key_store:
    mov [rbp - 1608 + rcx*4], edx
    inc rcx
    jmp .key_loop
.key_done:

    mov rbx, -INF           ; best
    xor r13d, r13d          ; best move
    xor rcx, rcx            ; index

.move_loop:
    cmp rcx, r15
    jge .loop_done

    ; selection ordering podla predvypocitanych klucov (swap tah + kluc)
    mov r10, rcx            ; best index
    mov r11d, -1            ; best score
    mov r8, rcx             ; scan index

.sel_loop:
    cmp r8, r15
    jge .sel_done
    movzx eax, word [rbp - 584 + r8*2]
    mov edx, [rbp - 1608 + r8*4]
    ; live tabulky (history/cap_history): deti/grandeti ich pocas slucky
    ; aktualizuju, zamrznute kluce ich preto neobsahuju:
    ;   quiet (flags==0, prazdny ciel)  -> live history[side][from][to]
    ;   ostatne brania (vc. EP/castle/promo brania) -> live cap_history
    ;   promo bez brania, zle brania (kluc < 0) -> len zamrznuty kluc
    test edx, edx
    js .sel_cmp
    mov r9, rax
    shr r9, 12
    and r9, 0xF                  ; flags
    cmp r9, FLAG_ENPASSANT
    je .sel_caplive_ep
    cmp r9, FLAG_PROMO_Q
    jb .sel_flags0               ; flags == 0
    cmp r9, FLAG_PROMO_N
    jbe .sel_promo               ; promo 1-4
    jmp .sel_caplive_to          ; castle (6): obet = board[to]
.sel_flags0:
    movzx edi, ax
    shr rdi, 6
    and edi, 0x3F                ; to
    lea rsi, [board]
    movzx esi, byte [rsi + rdi]
    test esi, esi
    jnz .sel_caplive_v           ; branie
    ; ---- quiet: live history[side][from][to] ----
    movzx edi, byte [side]
    shl edi, 12
    mov r9d, eax
    and r9d, 0x3F
    shl r9d, 6
    add edi, r9d
    mov r9d, eax
    shr r9d, 6
    and r9d, 0x3F
    add edi, r9d
    lea rsi, [history]
    add edx, dword [rsi + rdi*4]
    jmp .sel_cmp
.sel_promo:
    movzx edi, ax
    shr rdi, 6
    and edi, 0x3F                ; to
    lea rsi, [board]
    movzx esi, byte [rsi + rdi]
    test esi, esi
    jz .sel_cmp                  ; promo bez brania: bez live tabuliek
.sel_caplive_v:
    mov r9d, esi
    and r9d, PIECE_MASK
    dec r9d                      ; obet 0..5
    jmp .sel_caplive
.sel_caplive_ep:
    xor r9d, r9d                 ; EP: obet = PESIAK -> index 0
    jmp .sel_caplive
.sel_caplive_to:
    movzx edi, ax
    shr rdi, 6
    and edi, 0x3F                ; to
    lea rsi, [board]
    movzx r9d, byte [rsi + rdi]
    and r9d, PIECE_MASK
    dec r9d
.sel_caplive:
    ; index = (figura-1)*384 + to*6 + obet; figura = board[from]
    movzx edi, ax
    and edi, 0x3F                ; from
    lea rsi, [board]
    movzx edi, byte [rsi + rdi]
    and edi, PIECE_MASK
    dec edi                      ; figura 0..5
    imul edi, edi, 384
    mov esi, eax
    shr esi, 6
    and esi, 0x3F                ; to
    imul esi, esi, 6
    add edi, esi
    add edi, r9d
    lea rsi, [cap_history]
    add edx, dword [rsi + rdi*4]
.sel_cmp:
    cmp edx, r11d
    jle .sel_next
    mov r11d, edx
    mov r10, r8
.sel_next:
    inc r8
    jmp .sel_loop

.sel_done:
    cmp r10, rcx
    je .sel_picked
    mov ax, [rbp - 584 + rcx*2]
    mov dx, [rbp - 584 + r10*2]
    mov [rbp - 584 + rcx*2], dx
    mov [rbp - 584 + r10*2], ax
    mov edx, [rbp - 1608 + rcx*4]
    mov esi, [rbp - 1608 + r10*4]
    mov [rbp - 1608 + rcx*4], esi
    mov [rbp - 1608 + r10*4], edx

.sel_picked:

    movzx rax, word [rbp - 584 + rcx*2]
    ; r12 = 1 ak je to QUIET tah (flags==0 && board[to]==EMPTY) - pre LMR
    xor r12d, r12d
    mov r9d, eax
    shr r9d, 12
    test r9d, r9d
    jnz .quiet_done
    movzx edi, ax
    shr edi, 6
    and edi, 0x3F
    lea rsi, [board]
    cmp byte [rsi + rdi], EMPTY
    jne .quiet_done
    mov r12d, 1
.quiet_done:

    ; --- LMP: neskore tiche tahy pri nizkej hlbke preskoc ---
    ; !in_check && quiet && depth <= 3 && index >= 3 + depth^2
    cmp r12d, 1
    jne .no_lmp
    cmp dword [rbp - 44], 0
    jne .no_lmp
    mov rdx, [rbp - 8]      ; pozor: rax = aktualny tah pre make_move!
    cmp rdx, 3
    jg .no_lmp
    imul rdx, rdx           ; depth^2
    add rdx, 3
    cmp rcx, rdx
    jl .no_lmp
    inc rcx                 ; preskoc tah
    jmp .move_loop
.no_lmp:

    ; --- FUTILITY PRUNING: beznadejne tiche tahy pri nizkej hlbke preskoc ---
    ; !in_check && quiet && depth <= 2 && index >= 1 &&
    ; static_eval + FUTILITY_MARGIN*depth <= alpha && alpha daleko od matu
    cmp r12d, 1
    jne .no_futility
    cmp dword [rbp - 44], 0
    jne .no_futility
    mov rdx, [rbp - 8]      ; pozor: rax = aktualny tah pre make_move!
    cmp rdx, 2
    jg .no_futility
    test rcx, rcx           ; prvy tah vzdy hladaj (mat/pat detekcia)
    jz .no_futility
    imul edx, edx, FUTILITY_MARGIN  ; margin = 150 * depth (d1: 150, d2: 300)
    cmp dword [rbp - 64], 0         ; improving: eval stupa, prunej menej
    je .fut_margin_ok
    sub edx, FUTILITY_MARGIN        ; margin = 150 * (depth - 1)
.fut_margin_ok:
    add edx, dword [rbp - 56]       ; static eval + margin
    cmp edx, dword [rbp - 16]       ; eval + margin <= alpha?
    jg .no_futility
    cmp dword [rbp - 16], MATE_SCORE - 60
    jge .no_futility        ; alpha blizko matu: neprunej
    inc rcx                 ; preskoc tah
    jmp .move_loop
.no_futility:

    ; --- SEE PRUNING tichych tahov: tiche tahy stracajuce material ---
    ; !in_check && quiet && depth <= 4 && index >= 1 && alpha daleko od
    ; matu && see(tah) < -50*depth (figura skonci en prise bez kompenzacie)
    cmp r12d, 1
    jne .no_see_prune
    cmp dword [rbp - 44], 0
    jne .no_see_prune
    mov rdx, [rbp - 8]      ; pozor: rax = aktualny tah pre make_move!
    cmp rdx, 4
    jg .no_see_prune
    test rcx, rcx           ; prvy tah vzdy hladaj (mat/pat detekcia)
    jz .no_see_prune
    cmp dword [rbp - 16], MATE_SCORE - 60
    jge .no_see_prune       ; alpha blizko matu: neprunej
    imul edx, edx, -100     ; prah = -100 * depth (d4: -400)
    push rcx
    push rdx
    call see                ; ax = tah (tichy; gain[0] = 0)
    mov esi, eax            ; SEE vysledok (see prepisalo rax aj rdx)
    pop rdx                 ; prah
    pop rcx
    movzx rax, word [rbp - 584 + rcx*2]   ; obnov tah pre make_move
    cmp esi, edx
    jge .no_see_prune
    inc rcx                 ; preskoc tah
    jmp .move_loop
.no_see_prune:

    push rcx
    call make_move
    inc qword [search_ply]
    mov rcx, [rsp]          ; obnov index (make_move moze clobberovat rcx)

    ; --- child depth: +1 extension ak je vlastny kral v sachu (cap ply 40) ---
    mov rdi, [rbp - 8]
    cmp dword [rbp - 44], 0
    je .child_depth
    cmp qword [search_ply], 40
    jae .child_depth
    jmp .depth_ready          ; extension: depth sa neznizuje
.child_depth:
    dec rdi
.depth_ready:
    mov [rbp - 52], rdi     ; child depth (pre PVS/LMR re-search)

    test rcx, rcx
    jnz .pvs_window

.first_full:
    ; --- PRVY TAH: plne okno ---
    mov rsi, [rbp - 24]
    neg rsi                 ; -beta
    mov rdx, [rbp - 16]
    neg rdx                 ; -alpha
    mov rcx, 1              ; allow_null = 1
    call negamax
    neg eax                 ; -score
    jmp .after_search

.pvs_window:
    ; --- LMR: quiet tah, index >= 4, depth >= 3, nie v sachu ---
    cmp r12d, 1
    jne .no_lmr
    cmp rcx, 4
    jl .no_lmr
    cmp qword [rbp - 8], 3
    jl .no_lmr
    cmp dword [rbp - 44], 0
    jne .no_lmr
    ; redukovany search: depth-2, null window (alpha, alpha+1)
    ; !improving (eval klesa/stagnuje): redukuj este o 1 (min. child depth 1)
    dec rdi
    cmp dword [rbp - 64], 0
    jne .lmr_red_done
    cmp rdi, 2
    jl .lmr_red_done
    dec rdi
.lmr_red_done:
    mov rsi, [rbp - 16]
    neg rsi
    dec rsi                 ; -(alpha+1)
    mov rdx, [rbp - 16]
    neg rdx                 ; -alpha
    mov rcx, 1
    push rdi                ; zachovaj child depth
    call negamax
    pop rdi
    neg eax
    cmp eax, dword [rbp - 16]
    jle .after_search       ; fail-low: prijmi redukovany vysledok
    ; uspel: re-search na plnej hlbke null window (fall through)
.no_lmr:
    mov rsi, [rbp - 16]
    neg rsi
    dec rsi                 ; -(alpha+1)
    mov rdx, [rbp - 16]
    neg rdx                 ; -alpha
    mov rcx, 1
    call negamax
    neg eax
    ; PVS: ak alpha < score < beta -> re-search plne okno
    cmp eax, dword [rbp - 16]
    jle .after_search
    cmp eax, dword [rbp - 24]
    jge .after_search
    mov rdi, [rbp - 52]     ; obnov child depth
    mov rsi, [rbp - 24]
    neg rsi                 ; -beta
    mov rdx, [rbp - 16]
    neg rdx                 ; -alpha
    mov rcx, 1
    call negamax
    neg eax

.after_search:
    dec qword [search_ply]

    call unmake_move
    pop rcx

    cmp eax, ebx
    jle .alpha_update
    mov ebx, eax
    movzx r13d, word [rbp - 584 + rcx*2]   ; best move

.alpha_update:
    cmp eax, dword [rbp - 16]
    jle .check_cutoff
    movsxd rdx, eax         ; 64-bit ciste ulozenie alpha (hore bez smeti)
    mov [rbp - 16], rdx

.check_cutoff:
    mov edx, dword [rbp - 16]
    cmp edx, dword [rbp - 24]
    jl .no_cutoff

    ; --- beta cutoff: aktualizuj killers/history/cap_history/countermove ---
    movzx eax, word [rbp - 584 + rcx*2]
    mov r9d, eax
    shr r9d, 12
    test r9d, r9d
    jz .cutoff_plain             ; bezny tah: quiet alebo branie
    cmp r9d, FLAG_ENPASSANT
    je .cutoff_ep
    cmp r9d, FLAG_PROMO_Q
    jb .cutoff_done              ; castle: nikdy nie je branie
    cmp r9d, FLAG_PROMO_N
    ja .cutoff_done
    ; promo: spadni do testu brania (board[to] rozhodne)
.cutoff_plain:
    movzx edi, ax
    shr edi, 6
    and edi, 0x3F                ; to
    lea rsi, [board]
    cmp byte [rsi + rdi], EMPTY
    jne .cutoff_capture
    test r9d, r9d
    jnz .cutoff_done             ; promo bez brania: nie je to cisty quiet tah
    ; killers: posun a uloz (ak uz nie je killer1)
    mov r9, [search_ply]
    cmp r9, 63
    ja .cutoff_history
    lea rsi, [killers]
    cmp eax, dword [rsi + r9*8]
    je .cutoff_history
    mov edi, dword [rsi + r9*8]
    mov dword [rsi + r9*8 + 4], edi   ; killer2 = stary killer1
    mov dword [rsi + r9*8], eax       ; killer1 = tah
.cutoff_history:
    ; history[side][from][to] += depth^2 so saturaciou
    movzx r9d, byte [side]
    shl r9d, 12
    movzx edi, ax
    and edi, 0x3F
    shl edi, 6
    mov esi, eax
    shr esi, 6
    and esi, 0x3F
    add edi, esi
    add edi, r9d
    lea r9, [history]
    mov esi, dword [r9 + rdi*4]
    mov edx, dword [rbp - 8]     ; depth
    imul edx, edx
    add esi, edx
    cmp esi, 40000
    jle .cutoff_hist_store
    mov esi, 40000
.cutoff_hist_store:
    mov dword [r9 + rdi*4], esi
    ; countermove: uloz tah ako refutaciu opponentovho posledneho tahu
    ; (kluc = tah na ply-1; pri root/null ply klucom nie je -> preskoc)
    mov r9, [search_ply]
    test r9, r9
    jz .cutoff_done
    lea rdx, [move_stack]
    movzx edx, word [rdx + r9*2 - 2]
    test edx, edx
    jz .cutoff_done
    mov esi, edx
    and esi, 0x3F                ; prev from
    shl esi, 6
    shr edx, 6
    and edx, 0x3F                ; prev to
    add edx, esi
    lea rsi, [countermoves]
    mov [rsi + rdx*2], ax        ; countermove = cutoff tah
    jmp .cutoff_done

.cutoff_ep:
    ; en passant: obet = PESIAK, iduca figura = PESIAK
    movzx edi, ax
    shr edi, 6
    and edi, 0x3F                ; to
    imul edi, edi, 6             ; (PAWN-1)*384 + to*6 + (PAWN-1)
    lea rsi, [cap_history]
    jmp .cutoff_cap_bonus

.cutoff_capture:
    ; cap_history[figura][to][obet] += depth^2 so saturaciou 40000
    ; (rsi = board, rdi = to z .cutoff_plain)
    movzx r9d, byte [rsi + rdi]  ; obet
    and r9d, PIECE_MASK
    dec r9d
    imul edi, edi, 6
    add edi, r9d
    movzx r9d, ax
    and r9d, 0x3F                ; from
    movzx r9d, byte [rsi + r9]   ; iduca figura
    and r9d, PIECE_MASK
    dec r9d
    imul r9d, r9d, 384
    add edi, r9d
    lea rsi, [cap_history]
.cutoff_cap_bonus:
    mov r9d, dword [rsi + rdi*4]
    mov edx, dword [rbp - 8]     ; depth
    imul edx, edx
    add r9d, edx
    cmp r9d, 40000
    jle .cutoff_cap_store
    mov r9d, 40000
.cutoff_cap_store:
    mov dword [rsi + rdi*4], r9d
.cutoff_done:
    jmp .loop_done

.no_cutoff:
    inc rcx
    jmp .move_loop

.loop_done:
    cmp ebx, -INF
    jne .best_ok
    mov eax, dword [rbp - 16]
    jmp .neg_exit
.best_ok:
    mov eax, ebx

    ; pri aborte (uci_stop_flag) neukladaj do TT
    cmp byte [uci_stop_flag], 0
    jne .neg_exit

    ; store do TT: rdi=hash, rsi=depth, edx=score, ecx=flag, r8w=move
    cmp ebx, dword [rbp - 32]   ; best <= original_alpha -> UPPER
    jle .tt_upper
    cmp ebx, dword [rbp - 24]   ; best >= beta -> LOWER
    jge .tt_lower
    xor ecx, ecx                ; TT_EXACT
    jmp .tt_do_store
.tt_upper:
    mov ecx, TT_UPPER
    jmp .tt_do_store
.tt_lower:
    mov ecx, TT_LOWER
.tt_do_store:
    mov rdi, [position_hash]
    mov rsi, [rbp - 8]
    mov edx, ebx
    movzx r8d, r13w
    call tt_store
    mov eax, ebx            ; tt_store clobberuje rax, vrat skore
    jmp .neg_exit

.tt_score_hit:
    ; eax = skore z TT, priamo ho vratime
    jmp .neg_exit

.neg_exit:
    mov rsp, rbp
.neg_fast_exit:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================
; search_best_move - najde najlepsi tah pre aktualnu stranu
; Vstup:  rdi = hlbka
; Vystup: ax = najlepsi 16-bitovy tah (0 ak niet tahu)
; ============================================================
search_best_move:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbp, rsp

    mov qword [nodes_searched], 0
    mov dword [search_last_score], 0
    mov qword [search_ply], 0
    mov rbx, rdi            ; odloz hlbku searchu (generate_all_moves prepise r12-r15)

    ; vynuluj killer tabulku; history/cap_history/countermoves len pri prvej ID iteracii
    lea rdi, [killers]
    mov rcx, 2*64
    xor eax, eax
    rep stosd
    cmp rbx, 1
    jne .skip_history_clear
    lea rdi, [history]
    mov rcx, 2*64*64
    rep stosd
    lea rdi, [cap_history]
    mov rcx, 6*64*6
    rep stosd
    lea rdi, [countermoves]
    mov rcx, 64*64/2          ; slova -> po dvoch v dworde
    rep stosd
.skip_history_clear:

    call generate_all_moves
    mov r15, rbx
    movzx r12, word [move_count]
    test r12, r12
    jz .no_moves

    ; lokalna kopia tahov
    mov rax, r12
    shl rax, 1
    add rax, 7
    and rax, ~7
    sub rsp, rax

    lea rsi, [move_list]
    mov rdi, rsp
    mov rcx, r12
.copy_loop:
    mov ax, [rsi]
    mov [rdi], ax
    add rsi, 2
    add rdi, 2
    dec rcx
    jnz .copy_loop

    mov r13, -INF           ; best score
    xor r14d, r14d          ; best move
    xor rcx, rcx
    ; aspiration: ak nepoziadane, pouzi plne okno
    cmp dword [asp_use], 0
    jne .asp_ready
    mov dword [asp_alpha], -INF
    mov dword [asp_beta], INF
.asp_ready:
    mov eax, [asp_alpha]
    mov [root_alpha], eax

.move_loop:
    cmp byte [uci_stop_flag], 0
    jne .loop_done

    cmp rcx, r12
    jge .loop_done

    ; jednoduche ordering: captures/promocie dopredu (selection)
    mov r10, rcx            ; best index
    mov r11d, -1            ; best score
    mov r8, rcx             ; scan index
    lea rsi, [board]

.root_sel_loop:
    cmp r8, r12
    jge .root_sel_done

    movzx rax, word [rsp + r8*2]
    xor edx, edx

    mov r9, rax
    shr r9, 12
    and r9, 0xF
    cmp r9, FLAG_ENPASSANT
    jne .root_check_capture
    mov edx, 150
    jmp .root_check_promo

.root_check_capture:
    mov r9, rax
    shr r9, 6
    and r9, 0x3F
    movzx edi, byte [rsi + r9]
    test edi, edi
    jz .root_check_promo
    mov edx, 100

.root_check_promo:
    mov r9, rax
    shr r9, 12
    and r9, 0xF
    cmp r9, FLAG_PROMO_Q
    jb .root_score_done
    cmp r9, FLAG_PROMO_N
    ja .root_score_done
    add edx, 80

.root_score_done:
    ; best move z predchadzajucej ID iteracie ma prioritu
    cmp ax, word [root_best_move]
    jne .root_score_cmp
    add edx, 1000000
.root_score_cmp:
    cmp edx, r11d
    jle .root_sel_next
    mov r11d, edx
    mov r10, r8

.root_sel_next:
    inc r8
    jmp .root_sel_loop

.root_sel_done:
    cmp r10, rcx
    je .root_sel_picked
    mov ax, [rsp + rcx*2]
    mov dx, [rsp + r10*2]
    mov [rsp + rcx*2], dx
    mov [rsp + r10*2], ax

.root_sel_picked:

    movzx rax, word [rsp + rcx*2]
    push rcx
    call make_move
    mov rcx, [rsp]          ; obnov index

    mov rdi, r15
    dec rdi
    test rcx, rcx
    jz .root_full
    ; PVS null window: child (-(alpha+1), -alpha) ako v negamax slucke
    movsxd rsi, dword [root_alpha]
    neg rsi
    dec rsi                 ; -(alpha+1)
    movsxd rdx, dword [root_alpha]
    neg rdx                 ; -alpha
    jmp .root_call
.root_full:
    movsxd rsi, dword [asp_beta]
    neg rsi                 ; -beta
    movsxd rdx, dword [asp_alpha]
    neg rdx                 ; -alpha
.root_call:
    mov rcx, 1              ; allow_null = 1
    call negamax
    neg eax
    ; PVS re-search: null-window tah s alpha < score < beta
    cmp qword [rsp], 0
    je .root_searched
    cmp eax, dword [root_alpha]
    jle .root_searched
    cmp eax, dword [asp_beta]
    jge .root_searched
    mov rdi, r15
    dec rdi
    movsxd rsi, dword [asp_beta]
    neg rsi
    movsxd rdx, dword [asp_alpha]
    neg rdx
    mov rcx, 1
    call negamax
    neg eax
.root_searched:
    call unmake_move
    pop rcx

    cmp byte [uci_stop_flag], 0
    jne .loop_done

    cmp eax, r13d
    jle .next
    mov r13d, eax
    mov dword [root_alpha], eax   ; alpha = best
    movzx r14d, word [rsp + rcx*2]

.next:
    inc rcx
    jmp .move_loop

.loop_done:
    test r14d, r14d
    jnz .have_best
    cmp r12, 0
    je .have_best
    movzx r14d, word [rsp]
    mov r13d, 0

.have_best:
    mov dword [root_best_move], r14d   ; pre ordering v dalsej ID iteracii
    mov dword [search_last_score], r13d
    mov edi, r14d
    call collect_pv         ; naplni pv_moves[] pre panel/UCI vypis
    mov eax, r14d
    jmp .sbm_exit

.no_moves:
    xor eax, eax

.sbm_exit:
    mov rsp, rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================
; perft - spocita legalne listove uzly do danej hlbky
; Vstup:  rdi = hlbka
; Vystup: rax = pocet uzlov (64-bit)
; ============================================================
perft:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbp, rsp

    mov r15, rdi            ; depth
    test r15, r15
    jnz .recurse
    mov rax, 1
    jmp .done

.recurse:
    call generate_all_moves
    movzx r14, word [move_count]
    test r14, r14
    jz .zero

    ; lokalna kopia zoznamu tahov
    mov rax, r14
    shl rax, 1
    add rax, 15
    and rax, ~15
    sub rsp, rax

    lea rsi, [move_list]
    mov rdi, rsp
    mov rcx, r14
.copy_loop:
    mov ax, [rsi]
    mov [rdi], ax
    add rsi, 2
    add rdi, 2
    dec rcx
    jnz .copy_loop

    xor r13, r13            ; celkovy pocet
    xor r12, r12            ; index tahu

.move_loop:
    cmp r12, r14
    jge .loop_done

    movzx rax, word [rsp + r12*2]

    push r12
    push r13
    call make_move

    mov rdi, r15
    dec rdi
    call perft
    mov rbx, rax            ; uloz vysledok

    call unmake_move

    pop r13
    pop r12
    add r13, rbx
    inc r12
    jmp .move_loop

.loop_done:
    mov rax, r13
    jmp .done

.zero:
    xor rax, rax

.done:
    mov rsp, rbp
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; collect_pv - ulozi celu PV do pv_moves[] (pre panel)
; Vstup: rdi = prvy tah (root best move)
; Pozor: volat az po skonceni searchu (undo_stack musi byt prazdny)
; ============================================================
collect_pv:
    push rbx
    push r12
    push r13

    mov qword [pv_moves_len], 0
    mov r12, rdi            ; aktualny tah
    xor r13, r13            ; pocet spravenych tahov

.loop:
    test r12, r12
    jz .done
    cmp r13, 40
    jge .done

    ; uloz tah do pv_moves
    mov rbx, [pv_moves_len]
    lea rax, [pv_moves]
    mov [rax + rbx*2], r12w
    inc rbx
    mov [pv_moves_len], rbx

    ; aplikuj tah
    mov rax, r12
    call make_move
    inc r13

    ; dalsi tah z TT
    mov rdi, [position_hash]
    xor esi, esi
    mov rdx, -INF
    mov rcx, INF
    call tt_probe
    test edx, edx
    jz .done
    movzx r12, r8w
    jmp .loop

.done:
    ; vraciam poziciu
.unmake_loop:
    test r13, r13
    jz .ret
    call unmake_move
    dec r13
    jmp .unmake_loop
.ret:
    pop r13
    pop r12
    pop rbx
    ret