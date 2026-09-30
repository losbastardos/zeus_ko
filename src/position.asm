; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; position.asm - bitboard jadro (E10/F1)
;
; Drzi bitboard stav pozicie ako primarnu reprezentaciu pre
; attack query: bb_pieces[color*6 + typ-1], bb_side[2], bb_occ.
; Slider utoky cez magic bitboardy (konstanty v magics.inc,
; runtime tabulka magic_attacks plni pos_magics_init pri starte).
;
; Invariant F1: bb stav je konzistentny s board[64] po kazdej
; zmene boardu - pos_bb_init sa vola v init_board, parse_fen_string,
; apply_move (move.asm) a unmake_move (search.asm). Hot search
; cesty nerobia ziaden re-sync (F2 prejde na inkrementalne bts/btr
; priamo v make/unmake).
; ============================================================

%include "chess.inc"
%include "bitboard_tables.inc"      ; bb_knight_attacks, bb_king_attacks
%include "magics.inc"               ; magics_bishop/rook, MAGICS_* equ

DEFAULT REL

%define BB_FILE_A 0x0101010101010101
%define BB_FILE_H 0x8080808080808080
%define MAGIC_REC_SIZE 32           ; dq mask, magic, shift, offset

section .bss

global bb_pieces, bb_side, bb_occ
bb_pieces:  resq 12                 ; [color_idx*6 + typ-1]
bb_side:    resq 2                  ; 0 = biela occupancy, 1 = cierna
bb_occ:     resq 1                  ; celkova occupancy

global magic_attacks
magic_attacks: resq MAGICS_TOTAL    ; bishop sekcia (5248) + rook (102400)

section .text

global pos_bb_init, pos_magics_init
global bb_attacks_bishop, bb_attacks_rook, bb_attacks_queen
global is_square_attacked_bb

extern board

; ============================================================
; pos_bb_init - prelozi board[64] do bitboardov (plny re-sync)
; Zodpoveda povodnemu bb_sync z bb.asm (ten je teraz alias).
; ============================================================
pos_bb_init:
    push rbx
    push r12
    lea rbx, [board]
    lea rdi, [bb_pieces]
    xor eax, eax
    mov rcx, 15                  ; bb_pieces(12) + bb_side(2) + bb_occ(1), contiguous
    rep stosq
    xor r12, r12                 ; sq 0..63
.loop:
    cmp r12, 64
    jae .done
    movzx eax, byte [rbx + r12]
    test eax, eax
    jz .next
    ; color_idx = (piece & 8) >> 3  ->  edx
    mov edx, eax
    and edx, COLOR_MASK
    shr edx, 3
    ; typ - 1 -> ecx
    mov ecx, eax
    and ecx, PIECE_MASK
    dec ecx
    ; slot = color_idx*6 + typ-1  ->  r8d
    mov r8d, edx
    imul r8d, r8d, 6
    add r8d, ecx
    ; bit = 1 << sq  ->  r9
    mov r9, 1
    mov ecx, r12d
    shl r9, cl
    ; bb_pieces[slot] |= bit
    lea rdi, [bb_pieces]
    mov ecx, r8d
    or [rdi + rcx*8], r9
    ; bb_side[color_idx] |= bit
    lea rdi, [bb_side]
    mov ecx, edx
    or [rdi + rcx*8], r9
    ; bb_occ |= bit
    lea rdi, [bb_occ]
    or [rdi], r9
.next:
    inc r12
    jmp .loop
.done:
    pop r12
    pop rbx
    ret

; ============================================================
; gen_attacks (interne) - ray-casting utoky z policka
; Vstup:  edi = sq, rsi = occupancy, edx = 0 bishop / 1 rook
; Vystup: rax = attack bitboard
; Nici:   rcx, rdx, rsi, rdi, r8-r11
; ============================================================
global gen_attacks
gen_attacks:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                ; sq
    mov r13, rsi                 ; occ
    lea r8, [bb_dirs_bishop]
    test edx, edx
    jz .have_dirs
    lea r8, [bb_dirs_rook]
.have_dirs:
    xor eax, eax                 ; vysledok
    xor r9d, r9d                 ; index smeru
.dir_loop:
    cmp r9d, 4
    jae .done
    mov r10, [r8 + r9*8]         ; df | dr<<32
    movsx r14, r10d              ; df
    shr r10, 32
    movsx r15, r10d              ; dr
    ; start = (f + df, r + dr)
    mov ecx, r12d
    and ecx, 7
    add ecx, r14d                ; f
    mov ebx, r12d
    shr ebx, 3
    add ebx, r15d                ; r
.ray:
    cmp ecx, 0
    jl .next_dir
    cmp ecx, 7
    jg .next_dir
    cmp ebx, 0
    jl .next_dir
    cmp ebx, 7
    jg .next_dir
    mov edi, ebx
    shl edi, 3
    add edi, ecx                 ; s = r*8 + f
    bts rax, rdi
    bt  r13, rdi                 ; blocker?
    jc .next_dir
    add ecx, r14d
    add ebx, r15d
    jmp .ray
.next_dir:
    inc r9d
    jmp .dir_loop
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; pos_magics_init - runtime naplnenie magic_attacks
; Pre kazde policko, pre bishop aj rook sekciu: enumeruje vsetky
; podmnoziny relevantnej masky (carry-ripple), vypocita ray-casting
; utoky a ulozi ich na magic_attacks[offset + ((sub * magic) >> shift)].
; Volat raz pri starte (main _start).
; ============================================================
pos_magics_init:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 24                  ; [rsp]=magic, [rsp+8]=shift, [rsp+16]=offset
%ifdef POS_MAGICS_DEBUG
    lea rdi, [dbg_pm_start]
    call write_cstr
%endif
    lea r15, [magics_bishop]
    xor ebp, ebp                 ; 0 = bishop sekcia
%ifdef POS_MAGICS_DEBUG
    lea rdi, [dbg_pm_bishop]
    call write_cstr
%endif
.sect_loop:
    xor r12d, r12d               ; sq
.sq_loop:
    cmp r12d, 64
    jae .sect_done
%ifdef POS_MAGICS_DEBUG
    mov eax, r12d
    and eax, 15
    jnz .no_dbg_sq
    lea rdi, [dbg_pm_sq]
    call write_cstr
    mov rax, r12
    call print_number
    call print_newline
.no_dbg_sq:
%endif
    mov r13, r12
    shl r13, 5                   ; sq * MAGIC_REC_SIZE
    add r13, r15                 ; adresa zaznamu
    mov rbx, [r13]               ; mask
    mov rax, [r13 + 8]
    mov [rsp], rax               ; magic
    mov rax, [r13 + 16]
    mov [rsp + 8], rax           ; shift
    mov rax, [r13 + 24]
    mov [rsp + 16], rax          ; offset
    xor r14, r14                 ; subset = 0
.sub_loop:
%ifdef POS_MAGICS_DEBUG
    test ebp, ebp
    jz .no_dbg_sub
    test r12d, r12d
    jnz .no_dbg_sub
    cmp qword [dbg_pm_cnt], 20
    jae .no_dbg_sub
    inc qword [dbg_pm_cnt]
    lea rdi, [dbg_pm_sub]
    call write_cstr
    mov rax, r14
    call print_number
    call print_newline
.no_dbg_sub:
%endif
    mov rax, r14
    imul rax, [rsp]              ; sub * magic
    mov rcx, [rsp + 8]
    shr rax, cl                  ; idx
    push rax
    mov edi, r12d
    mov rsi, r14
    mov edx, ebp
    call gen_attacks
    pop rcx                      ; idx
    add rcx, [rsp + 16]          ; offset + idx
    lea rdx, [magic_attacks]
    mov [rdx + rcx*8], rax
    ; dalsia podmnozina: (sub - mask) & mask
    mov rax, r14
    sub rax, rbx
    and rax, rbx
    test rax, rax
    jz .sq_next
    mov r14, rax
    jmp .sub_loop
.sq_next:
    inc r12d
    jmp .sq_loop
.sect_done:
%ifdef POS_MAGICS_DEBUG
    lea rdi, [dbg_pm_sect]
    call write_cstr
    mov rax, r12
    call print_number
    call print_newline
%endif
    test ebp, ebp
    jnz .fin
    lea r15, [magics_rook]
    mov ebp, 1
    jmp .sect_loop
.fin:
    add rsp, 24
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; bb_attacks_common (interne) - magic hash lookup
; Vstup:  eax = sq, rdx = occupancy, r8 = tabulka zaznamov
; Vystup: rax = attack bitboard
; Nici:   rcx, rdx, r8, r9
; ============================================================
bb_attacks_common:
    mov r9d, eax
    shl r9, 5                    ; sq * MAGIC_REC_SIZE
    and rdx, [r8 + r9]           ; occ & mask
    imul rdx, [r8 + r9 + 8]      ; * magic
    mov rcx, [r8 + r9 + 16]
    shr rdx, cl                  ; >> shift
    mov rax, [r8 + r9 + 24]      ; offset
    add rax, rdx
    lea r8, [magic_attacks]
    mov rax, [r8 + rax*8]
    ret

; ============================================================
; bb_attacks_bishop - utoky strelca cez magics
; Vstup: eax = sq, rdx = occupancy -> rax = attack bitboard
; ============================================================
bb_attacks_bishop:
    lea r8, [magics_bishop]
    jmp bb_attacks_common

; ============================================================
; bb_attacks_rook - utoky veze cez magics
; Vstup: eax = sq, rdx = occupancy -> rax = attack bitboard
; ============================================================
bb_attacks_rook:
    lea r8, [magics_rook]
    jmp bb_attacks_common

; ============================================================
; bb_attacks_queen - utoky damy (or bishop, rook)
; Vstup: eax = sq, rdx = occupancy -> rax = attack bitboard
; ============================================================
bb_attacks_queen:
    push rbx
    mov rbx, rdx                 ; occ
    mov r11d, eax                ; sq
    lea r8, [magics_bishop]
    call bb_attacks_common
    mov r10, rax
    mov rdx, rbx
    mov eax, r11d
    lea r8, [magics_rook]
    call bb_attacks_common
    or rax, r10
    pop rbx
    ret

; ============================================================
; is_square_attacked_bb - zisti, ci je policko napadnute superom
; Vstup:  eax = policko (0..63), ebx = side (0/1) ktoreho kral tam stoji
; Vystup: eax = 1 ak je policko napadnute superom, inak 0
; Poziadavka: bb stav je aktualny (invariant F1)
; Pesiaci/jazdec/kral identicky s povodnou logikou bb.asm,
; slidery cez bb_attacks_* s rdx = bb_occ.
; ============================================================
is_square_attacked_bb:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, eax                ; sq
    mov r13d, ebx                ; side: 0 = biely, 1 = cierny
    xor r13d, 1                  ; enemy_idx
    imul r13d, r13d, 6           ; enemy base slot
    mov r14, 1
    mov ecx, r12d
    shl r14, cl                  ; test bit = 1<<sq
    lea r15, [bb_pieces]

    ; --- pesiaci ---
    mov rax, [r15 + r13*8]
    test r13d, r13d
    jnz .black_pawns
    mov rdx, rax                 ; biele: (bb<<7 & ~FILE_H) | (bb<<9 & ~FILE_A)
    shl rdx, 7
    mov rcx, ~BB_FILE_H
    and rdx, rcx
    shl rax, 9
    mov rcx, ~BB_FILE_A
    and rax, rcx
    or rax, rdx
    jmp .pawn_test
.black_pawns:                    ; cierne: (bb>>9 & ~FILE_H) | (bb>>7 & ~FILE_A)
    mov rdx, rax
    shr rdx, 9
    mov rcx, ~BB_FILE_H
    and rdx, rcx
    shr rax, 7
    mov rcx, ~BB_FILE_A
    and rax, rcx
    or rax, rdx
.pawn_test:
    test rax, r14
    jnz .attacked

    ; --- jazdci ---
    lea rax, [bb_knight_attacks]
    mov rcx, r12
    mov rax, [rax + rcx*8]
    lea rcx, [r13 + 1]
    and rax, [r15 + rcx*8]
    jnz .attacked

    ; --- kral ---
    lea rax, [bb_king_attacks]
    mov rcx, r12
    mov rax, [rax + rcx*8]
    lea rcx, [r13 + 5]
    and rax, [r15 + rcx*8]
    jnz .attacked

    ; --- slidery: ciele do r8 (bishop|queen), r9 (rook|queen) ---
    lea rcx, [r13 + 2]
    mov r8, [r15 + rcx*8]
    lea rcx, [r13 + 4]
    or r8, [r15 + rcx*8]
    lea rcx, [r13 + 3]
    mov r9, [r15 + rcx*8]
    lea rcx, [r13 + 4]
    or r9, [r15 + rcx*8]
    lea rcx, [bb_occ]
    mov r10, [rcx]               ; occupancy

    test r8, r8
    jz .rook_part                ; nema zmysel dotaz bez cielovej figury
    push r8
    push r9
    mov eax, r12d
    mov rdx, r10
    call bb_attacks_bishop
    pop r9
    pop r8
    test rax, r8
    jnz .attacked

.rook_part:
    test r9, r9
    jz .not_attacked
    push r8
    push r9
    mov eax, r12d
    mov rdx, r10
    call bb_attacks_rook
    pop r9
    pop r8
    test rax, r9
    jnz .attacked

.not_attacked:
    xor eax, eax
    jmp .ret
.attacked:
    mov eax, 1
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .bss
dbg_pm_cnt: resq 1
section .rodata
%ifdef POS_MAGICS_DEBUG
extern write_cstr, print_number, print_newline
dbg_pm_start: db "PM: start", 10, 0
dbg_pm_bishop: db "PM: bishop sect", 10, 0
dbg_pm_sect: db "PM: sect done sq=", 0
dbg_pm_sq: db "PM: sq=", 0
dbg_pm_sub: db "PM:  sub=", 0
%endif
; smerove vektory pre gen_attacks: 1 qword = df | dr<<32 (index r9*8)
bb_dirs_bishop:
    dq 0x0000000100000001        ; (+1, +1)
    dq 0xFFFFFFFF00000001        ; (+1, -1)
    dq 0x00000001FFFFFFFF        ; (-1, +1)
    dq 0xFFFFFFFFFFFFFFFF        ; (-1, -1)
bb_dirs_rook:
    dq 0x0000000000000001        ; (+1,  0)
    dq 0x00000000FFFFFFFF        ; (-1,  0)
    dq 0x0000000100000000        ; ( 0, +1)
    dq 0xFFFFFFFF00000000        ; ( 0, -1)
section .text
