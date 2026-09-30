; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; legal.asm - legal move filter a detekcia sachu
; ============================================================

%include "chess.inc"

DEFAULT REL

section .text

global find_king, is_square_attacked, is_in_check, filter_legal_moves

extern board, side, move_list, move_count
extern knight_offsets, bishop_dirs, rook_dirs, king_dirs
extern apply_move
extern bb_sync, bb_is_square_attacked
extern is_square_attacked_bb, pos_bb_init

; ============================================================
; find_king - najde policko krala danej strany
; Vstup:  rax = side (0 = biely, 1 = cierny)
; Vystup: rax = index policka 0..63, alebo -1
; ============================================================
find_king:
    push rbx
    push rcx
    push rdx
    push rdi

    mov rbx, rax
    shl rbx, 3              ; farba krala v bitoch 3
    xor rcx, rcx

    lea rdi, [board]
.search:
    movzx rdx, byte [rdi + rcx]
    test rdx, rdx
    jz .next

    mov rax, rdx
    and rax, PIECE_MASK
    cmp rax, KING
    jne .next

    mov rax, rdx
    and rax, COLOR_MASK
    cmp rax, rbx
    je .found

.next:
    inc rcx
    cmp rcx, 64
    jl .search

    mov rax, -1
    jmp .done
.found:
    mov rax, rcx
.done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; is_square_attacked - zisti, ci je policko napadnute superom
; Vstup:  rax = policko (0..63), rbx = side (0 = biely, 1 = cierny)
; Vystup: rax = 1 ak je napadnute, inak 0
; ============================================================
is_square_attacked:
    jmp is_square_attacked_bb

; ============================================================
; is_in_check - zisti, ci je kral danej strany v sachu
; Vstup:  rax = side
; Vystup: rax = 1 ak je v sachu, inak 0
; ============================================================
is_in_check:
    push rbx
    push r12

    mov r12, rax
    call find_king
    cmp rax, 0
    jl .not_in_check

    mov rbx, r12
    call is_square_attacked
    test rax, rax
    jz .not_in_check

    mov rax, 1
    jmp .done
.not_in_check:
    xor rax, rax
.done:
    pop r12
    pop rbx
    ret

; ============================================================
; filter_legal_moves - odstrani z move_list tahy, po ktorych
;                      by vlastny kral zostal v sachu
; ============================================================
filter_legal_moves:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    sub rsp, 64             ; miesto pre kopiu sachovnice

    xor rcx, rcx            ; index i
.loop:
    movzx rdx, word [move_count]
    cmp rcx, rdx
    jge .done

    ; uloz sachovnicu na zasobnik
    lea rsi, [board]
    mov rdi, rsp
    mov r12, rcx
    mov rcx, 64
.copy_to_stack:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .copy_to_stack
    mov rcx, r12

    ; nacitaj tah
    lea rsi, [move_list]
    movzx r12, word [rsi + rcx*2]

    ; aplikuj tah
    mov rax, r12
    call apply_move

    ; pre hot-path legality check prepneme na bitboard attack query
    ; rcx drzi index v move_list, preto ho treba zachovat cez call retazec
    push rcx
    call bb_sync

    ; skontroluj, ci nie je kral v sachu (po aplikovanom tahu)
    movzx rax, byte [side]
    call find_king
    cmp rax, 0
    jl .king_missing
    movzx rbx, byte [side]
    call bb_is_square_attacked
    mov rdx, rax
    pop rcx
    test rdx, rdx
    jnz .remove_move
    jmp .after_king_check

.king_missing:
    pop rcx
    jmp .remove_move

.after_king_check:

    ; specialna kontrola rosady: kral nesmie prechadzat cez sach
    mov rax, r12
    shr rax, 12
    and rax, 0xF
    cmp rax, FLAG_CASTLE
    jne .legal

    movzx rax, r12w
    and rax, 0x3F
    mov r14, rax            ; from (policko krala)
    movzx rax, r12w
    shr rax, 6
    and rax, 0x3F
    sub rax, r14            ; delta = +/-2
    sar rax, 1              ; smer = +/-1
    mov r13, rax

    ; kral nesmie BYT v sachu uz na startovacom policku (is_in_check vyssie
    ; testuje az cielove policko po aplikovani tahu, teda from by uniklo)
    push rcx
    movzx rbx, byte [side]
    mov rax, r14
    call bb_is_square_attacked
    pop rcx
    test rax, rax
    jnz .remove_move

    push rcx
    movzx rbx, byte [side]
    lea rax, [r14 + r13]
    call bb_is_square_attacked
    pop rcx
    test rax, rax
    jnz .remove_move

    push rcx
    movzx rbx, byte [side]
    lea rax, [r14 + r13*2]
    call bb_is_square_attacked
    pop rcx
    test rax, rax
    jnz .remove_move

.legal:
    inc rcx
    jmp .restore

.remove_move:
    ; nelegalny: odstran zo zoznamu
    lea rsi, [move_list]
    movzx rdx, word [move_count]
    dec rdx
    mov [move_count], dx
    cmp rcx, rdx
    je .restore             ; ak posledny, iba zniz pocet
    movzx r13, word [rsi + rdx*2]
    mov [rsi + rcx*2], r13w
    jmp .restore            ; neinkrementuj, skontroluj swapped move

.restore:
    ; obnov sachovnicu zo zasobnika
    mov rsi, rsp
    lea rdi, [board]
    mov r12, rcx
    mov rcx, 64
.copy_from_stack:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .copy_from_stack
    mov rcx, r12

    jmp .loop

.done:
    call pos_bb_init           ; E10/F1: bb stav konzistentny po restore zo stacku

    add rsp, 64

    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret