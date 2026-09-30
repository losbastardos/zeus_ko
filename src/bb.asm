; ============================================================
; bb.asm - bitboard scaffold (P3 priprava)
;
; POZNAMKA E10/F1: bitboard stav (bb_pieces/bb_side/bb_occ) a
; attack query zili do position.asm. Tento modul drzi uz len
; kompatibilne aliasy (bb_sync -> pos_bb_init, bb_is_square_attacked
; -> is_square_attacked_bb) a validacny harness (bbtest).
;
; Konvencia zhodna s legal.asm:
;   is_square_attacked(rax=sq, rbx=side 0/1) -> rax=1 ak super napada
;
; Layout: bb_pieces[color_idx*6 + (typ-1)] = bitboard danej figury
;   color_idx: 0 = biely, 1 = cierny (z (piece & 8)>>3)
;   slot: PAWN=0, KNIGHT=1, BISHOP=2, ROOK=3, QUEEN=4, KING=5
; ============================================================

%include "chess.inc"

DEFAULT REL

section .text
global bb_sync, bb_is_square_attacked, bb_validate_position, bb_debug_mismatch
extern board, is_square_attacked, write_cstr, print_number, print_newline
extern bb_pieces, bb_side, bb_occ
extern pos_bb_init, is_square_attacked_bb

; ============================================================
; bb_sync - prelozi board[64] do bitboardov (alias za pos_bb_init)
; ============================================================
bb_sync:
    jmp pos_bb_init

; ============================================================
; bb_is_square_attacked - bitboard verzia (alias za is_square_attacked_bb)
; Vstup:  rax = policko (0..63), rbx = strana (0/1) ktorej kral tam stoji
; Vystup: rax = 1 ak je policko napadnute superom, inak 0
; ============================================================
bb_is_square_attacked:
    jmp is_square_attacked_bb
; ============================================================
; bb_validate_position - porovna mailbox vs bitboard pre celu poziciu
; Vystup: rax = pocet nesuhladov (0 = OK)
; ============================================================
bb_validate_position:
    push rbx
    push r12
    push r13
    push r14
    call bb_sync
    xor r14, r14                 ; mismatch count
    xor r12, r12                 ; sq
.sq_loop:
    cmp r12, 64
    jae .done
    xor r13d, r13d               ; side 0/8
.side_loop:
    cmp r13d, 2
    jae .next_sq
    mov rax, r12
    mov rbx, r13
    call is_square_attacked      ; mailbox (zachova r12-r15, rbx pushuje)
    mov rcx, rax
    mov rax, r12
    mov rbx, r13
    push rcx
    call bb_is_square_attacked   ; bitboard
    pop rcx
    cmp rax, rcx
    je .side_ok
    inc r14
.side_ok:
    inc r13d
    jmp .side_loop
.next_sq:
    inc r12
    jmp .sq_loop
.done:
    mov rax, r14
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; bb_debug_mismatch - vypise detail prveho najdeneho mismatchu
; Vystup: rax = 1 ak bol najdeny (a vytlaceny), inak 0
; ============================================================
global bb_debug_mismatch
bb_debug_mismatch:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call bb_sync
    xor r12, r12
.sq_loop:
    cmp r12, 64
    jae .none
    xor r13d, r13d
.side_loop:
    cmp r13d, 2
    jae .next_sq
    mov rax, r12
    mov rbx, r13
    call is_square_attacked
    mov r14, rax
    mov rax, r12
    mov rbx, r13
    call bb_is_square_attacked
    cmp rax, r14
    jne .found
    inc r13d
    jmp .side_loop
.next_sq:
    inc r12
    jmp .sq_loop
.found:
    ; "BBDBG sq=<r12> side=<r13> mailbox=<r14> bb=<rax>"
    mov r15, rax
    push r15
    lea rdi, [dbg_bb_sq]
    call write_cstr
    mov rax, r12
    call print_number
    lea rdi, [dbg_bb_side]
    call write_cstr
    mov rax, r13
    call print_number
    lea rdi, [dbg_bb_mail]
    call write_cstr
    mov rax, r14
    call print_number
    lea rdi, [dbg_bb_bb]
    call write_cstr
    pop r15
    mov rax, r15
    call print_number
    call print_newline
    mov rax, 1
    jmp .ret
.none:
    xor rax, rax
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
dbg_bb_sq:   db "BBDBG sq=", 0
dbg_bb_side: db " side=", 0
dbg_bb_mail: db " mailbox=", 0
dbg_bb_bb:   db " bb=", 0

