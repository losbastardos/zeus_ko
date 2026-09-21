; ============================================================
; bb.asm - bitboard scaffold (P3 priprava)
;
; Ciel: rychly is_square_attacked cez bitboardy namiesto mailbox
; scanu. Scaffold faza = data struktury + attack query + validacny
; harness (bbtest). Integracia je zapnuta v legal filter hot-path.
;
; Konvencia zhodna s legal.asm:
;   is_square_attacked(rax=sq, rbx=side 0/1) -> rax=1 ak super napada
;
; Layout: bb_pieces[color_idx*6 + (typ-1)] = bitboard danej figury
;   color_idx: 0 = biely, 1 = cierny (z (piece & 8)>>3)
;   slot: PAWN=0, KNIGHT=1, BISHOP=2, ROOK=3, QUEEN=4, KING=5
; ============================================================

%include "chess.inc"
%include "bitboard_tables.inc"

DEFAULT REL

%define BB_FILE_A 0x0101010101010101
%define BB_FILE_H 0x8080808080808080

section .bss
global bb_pieces, bb_side, bb_occ
bb_pieces:  resq 12          ; [color_idx*6 + typ-1]
bb_side:    resq 2           ; 0 = biela occupancy, 1 = cierna
bb_occ:     resq 1           ; celkova occupancy

section .text
global bb_sync, bb_is_square_attacked, bb_validate_position, bb_debug_mismatch
extern board, is_square_attacked, write_cstr, print_number, print_newline

; ============================================================
; bb_sync - prelozi board[64] do bitboardov
; ============================================================
bb_sync:
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
; bb_is_square_attacked - bitboard verzia
; Vstup:  rax = policko (0..63), rbx = strana (0/8) ktorej kral tam stoji
; Vystup: rax = 1 ak je policko napadnute superom, inak 0
; Pozor: pred volanim treba bb_sync (bitboardy musia byt aktualne)
; ============================================================
bb_is_square_attacked:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rax                 ; sq
    mov r13d, ebx                ; side: 0 = biely, 1 = cierny (ako [side])
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

    ; --- strelci + damy (diagonaly) -> r8 ---
    lea rcx, [r13 + 2]
    mov r8, [r15 + rcx*8]
    lea rcx, [r13 + 4]
    or r8, [r15 + rcx*8]
    ; --- veze + damy (ortogonalne) -> r9 ---
    lea rcx, [r13 + 3]
    mov r9, [r15 + rcx*8]
    lea rcx, [r13 + 4]
    or r9, [r15 + rcx*8]
    ; occupancy -> r10
    lea rcx, [bb_occ]
    mov r10, [rcx]

    ; walker: rsi = dir index, r14 = &delta_dirs (test bit uz netreba)
    lea r14, [delta_dirs]
    xor esi, esi
.dir_loop:
    cmp esi, 8
    jae .not_attacked
    movsx eax, byte [r14 + rsi*2]        ; df
    movsx edx, byte [r14 + rsi*2 + 1]    ; dr
    mov ecx, r12d
    and ecx, 7                   ; file
    mov edi, r12d
    shr edi, 3                   ; rank
.step:
    add ecx, eax
    add edi, edx
    cmp ecx, 0
    jl .next_dir
    cmp ecx, 7
    jg .next_dir
    cmp edi, 0
    jl .next_dir
    cmp edi, 7
    jg .next_dir
    ; square = rank*8 + file -> rbx
    mov ebx, edi
    shl ebx, 3
    add ebx, ecx
    bt r10, rbx                  ; occupied?
    jnc .step
    cmp esi, 4
    jb .diag_hit
    bt r9, rbx                   ; rooklike?
    jc .attacked
    jmp .next_dir
.diag_hit:
    bt r8, rbx                   ; bishlike?
    jc .attacked
.next_dir:
    inc esi
    jmp .dir_loop

.attacked:
    mov rax, 1
    jmp .ret
.not_attacked:
    xor rax, rax
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

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

section .rodata
; 8 smerov: (df, dr) — 0-3 diagonalne, 4-7 ortogonalne
delta_dirs:
    db  1,  1
    db  1, -1
    db -1,  1
    db -1, -1
    db  1,  0
    db -1,  0
    db  0,  1
    db  0, -1
