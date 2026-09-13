; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; movegen.asm - generator pseudo-legálnych tahov
; ============================================================

%include "chess.inc"

DEFAULT REL

section .text

global generate_all_moves

extern board, side, castle, enpassant, move_list, move_count
extern knight_offsets, bishop_dirs, rook_dirs, king_dirs
extern print_number, print_newline
extern filter_legal_moves

; ============================================================
; add_move - prida tah do move_list
; Vstup: r12 = from, r13 = to, r14 = flags
; ============================================================
add_move:
    push rax
    push rbx
    push rsi

    movzx rbx, word [move_count]
    cmp rbx, 255
    jge .done

    lea rsi, [move_list]
    mov rax, r12
    shl r13, 6
    or rax, r13
    mov r13, r14
    shl r13, 12
    or rax, r13
    mov [rsi + rbx*2], ax

    inc rbx
    mov [move_count], bx

.done:
    pop rsi
    pop rbx
    pop rax
    ret

; ============================================================
; get_piece_type / get_piece_color
; ============================================================
get_piece_type:
    lea rdi, [board]
    movzx rax, byte [rdi + rax]
    and rax, PIECE_MASK
    ret

get_piece_color:
    lea rdi, [board]
    movzx rax, byte [rdi + rax]
    and rax, COLOR_MASK
    ret

; ============================================================
; is_square_empty / is_enemy_piece / is_own_piece
; ============================================================
is_square_empty:
    lea rdi, [board]
    movzx rax, byte [rdi + rax]
    test rax, rax
    setz al
    movzx rax, al
    ret

is_enemy_piece:
    push rbx
    lea rdi, [board]
    movzx rbx, byte [rdi + rax]
    test rbx, rbx
    jz .no
    movzx rax, byte [side]
    shl rax, 3
    xor rbx, rax
    test rbx, COLOR_MASK
    jnz .yes
.no:
    xor rax, rax
    pop rbx
    ret
.yes:
    mov rax, 1
    pop rbx
    ret

is_own_piece:
    push rbx
    lea rdi, [board]
    movzx rbx, byte [rdi + rax]
    test rbx, rbx
    jz .no
    movzx rax, byte [side]
    shl rax, 3
    xor rbx, rax
    test rbx, COLOR_MASK
    jz .yes
.no:
    xor rax, rax
    pop rbx
    ret
.yes:
    mov rax, 1
    pop rbx
    ret

; ============================================================
; generate_all_moves
; ============================================================
generate_all_moves:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov word [move_count], 0

    xor rax, rax
.square_loop:
    lea rdi, [board]
    movzx rbx, byte [rdi + rax]
    test rbx, rbx
    jz .next_square

    mov r12, rax
    call is_own_piece
    mov rbx, rax            ; uloz vysledok is_own_piece
    mov rax, r12            ; obnov cislo policka
    test rbx, rbx
    jz .next_square

    movzx rbx, byte [rdi + rax]
    and rbx, PIECE_MASK
    cmp rbx, PAWN
    je .gen_pawn
    cmp rbx, KNIGHT
    je .gen_knight
    cmp rbx, BISHOP
    je .gen_bishop
    cmp rbx, ROOK
    je .gen_rook
    cmp rbx, QUEEN
    je .gen_queen
    cmp rbx, KING
    je .gen_king
    jmp .next_square

.gen_pawn:
    mov rax, r12
    call generate_pawn_moves
    jmp .next_square
.gen_knight:
    mov rax, r12
    call generate_knight_moves
    jmp .next_square
.gen_bishop:
    mov rax, r12
    call generate_bishop_moves
    jmp .next_square
.gen_rook:
    mov rax, r12
    call generate_rook_moves
    jmp .next_square
.gen_queen:
    mov rax, r12
    call generate_queen_moves
    jmp .next_square
.gen_king:
    mov rax, r12
    call generate_king_moves
    call generate_castling
    jmp .next_square

.next_square:
    inc rax
    cmp rax, 64
    jl .square_loop

    call filter_legal_moves

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; generate_pawn_moves
; ============================================================
generate_pawn_moves:
    push rax
    push rbx
    push rcx
    push rdx
    push r12
    push r13
    push r14

    mov r12, rax
    mov rbx, rax
    and rbx, 7
    mov rcx, rax
    shr rcx, 3

    movzx rdx, byte [side]
    test rdx, rdx
    jnz .black

.white:
    cmp rcx, 7
    je .white_done
    mov r13, r12
    add r13, 8
    mov rax, r13
    call is_square_empty
    test rax, rax
    jz .white_captures
    cmp rcx, 6
    je .white_promote_single
    mov r14, FLAG_NORMAL
    call add_move

    cmp rcx, 1
    jne .white_captures
    mov r13, r12
    add r13, 16
    mov rax, r13
    call is_square_empty
    test rax, rax
    jz .white_captures
    mov r14, FLAG_NORMAL
    call add_move
    jmp .white_captures

.white_promote_single:
    call add_all_promotions
    jmp .white_captures

.white_captures:
    cmp rbx, 0
    je .white_cap_right
    mov r13, r12
    add r13, 7
    mov rax, r13
    call is_enemy_piece
    test rax, rax
    jz .white_ep_left
    cmp rcx, 6
    je .white_promote_cap_l
    mov r14, FLAG_NORMAL
    call add_move
    jmp .white_cap_right
.white_promote_cap_l:
    call add_all_promotions
    jmp .white_cap_right
.white_ep_left:
    movzx rax, byte [enpassant]
    cmp rax, r13
    jne .white_cap_right
    mov r14, FLAG_ENPASSANT
    call add_move

.white_cap_right:
    cmp rbx, 7
    je .white_done
    mov r13, r12
    add r13, 9
    mov rax, r13
    call is_enemy_piece
    test rax, rax
    jz .white_ep_right
    cmp rcx, 6
    je .white_promote_cap_r
    mov r14, FLAG_NORMAL
    call add_move
    jmp .white_done
.white_promote_cap_r:
    call add_all_promotions
    jmp .white_done
.white_ep_right:
    movzx rax, byte [enpassant]
    cmp rax, r13
    jne .white_done
    mov r14, FLAG_ENPASSANT
    call add_move

.white_done:
    jmp .done

.black:
    cmp rcx, 0
    je .done
    mov r13, r12
    sub r13, 8
    mov rax, r13
    call is_square_empty
    test rax, rax
    jz .black_captures
    cmp rcx, 1
    je .black_promote_single
    mov r14, FLAG_NORMAL
    call add_move

    cmp rcx, 6
    jne .black_captures
    mov r13, r12
    sub r13, 16
    mov rax, r13
    call is_square_empty
    test rax, rax
    jz .black_captures
    mov r14, FLAG_NORMAL
    call add_move
    jmp .black_captures

.black_promote_single:
    call add_all_promotions
    jmp .black_captures

.black_captures:
    cmp rbx, 0
    je .black_cap_right
    mov r13, r12
    sub r13, 9
    mov rax, r13
    call is_enemy_piece
    test rax, rax
    jz .black_ep_left
    cmp rcx, 1
    je .black_promote_cap_l
    mov r14, FLAG_NORMAL
    call add_move
    jmp .black_cap_right
.black_promote_cap_l:
    call add_all_promotions
    jmp .black_cap_right
.black_ep_left:
    movzx rax, byte [enpassant]
    cmp rax, r13
    jne .black_cap_right
    mov r14, FLAG_ENPASSANT
    call add_move

.black_cap_right:
    cmp rbx, 7
    je .done
    mov r13, r12
    sub r13, 7
    mov rax, r13
    call is_enemy_piece
    test rax, rax
    jz .black_ep_right
    cmp rcx, 1
    je .black_promote_cap_r
    mov r14, FLAG_NORMAL
    call add_move
    jmp .done
.black_promote_cap_r:
    call add_all_promotions
    jmp .done
.black_ep_right:
    movzx rax, byte [enpassant]
    cmp rax, r13
    jne .done
    mov r14, FLAG_ENPASSANT
    call add_move

.done:
    pop r14
    pop r13
    pop r12
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; add_all_promotions - prida 4 promocne tahy z r12 -> r13
; ============================================================
add_all_promotions:
    push r14
    mov r14, FLAG_PROMO_Q
    call add_move
    mov r14, FLAG_PROMO_R
    call add_move
    mov r14, FLAG_PROMO_B
    call add_move
    mov r14, FLAG_PROMO_N
    call add_move
    pop r14
    ret

; ============================================================
; generate_knight_moves
; ============================================================
generate_knight_moves:
    push rax
    push rbx
    push rcx
    push rdx
    push r12
    push r13
    push r14
    push rsi

    mov r12, rax
    mov rbx, rax
    and rbx, 7
    mov rcx, rax
    shr rcx, 3

    lea rsi, [knight_offsets]
    xor rdx, rdx
.loop:
    movsx r13, byte [rsi + rdx]
    add r13, r12

    mov rax, r13
    and rax, 7
    sub rax, rbx
    mov r8, rax
    test r8, r8
    jns .check_file2
    neg r8
.check_file2:
    cmp r8, 2
    jg .next

    mov rax, r13
    shr rax, 3
    sub rax, rcx
    mov r8, rax
    test r8, r8
    jns .check_rank2
    neg r8
.check_rank2:
    cmp r8, 2
    jg .next

    cmp r13, 0
    jl .next
    cmp r13, 63
    jg .next

    mov rax, r13
    call is_own_piece
    test rax, rax
    jnz .next

    mov r14, FLAG_NORMAL
    call add_move

.next:
    inc rdx
    cmp rdx, 8
    jl .loop

    pop rsi
    pop r14
    pop r13
    pop r12
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; generate_bishop / rook / queen
; ============================================================
generate_bishop_moves:
    push rax
    lea rsi, [bishop_dirs]
    mov rcx, 4
    call generate_sliding
    pop rax
    ret

generate_rook_moves:
    push rax
    lea rsi, [rook_dirs]
    mov rcx, 4
    call generate_sliding
    pop rax
    ret

generate_queen_moves:
    push rax
    push rsi
    push rcx
    lea rsi, [bishop_dirs]
    mov rcx, 4
    call generate_sliding
    lea rsi, [rook_dirs]
    mov rcx, 4
    call generate_sliding
    pop rcx
    pop rsi
    pop rax
    ret

; ============================================================
; generate_sliding
; Vstup: rax = from, rsi = smerova tabulka, rcx = pocet smerov
; ============================================================
generate_sliding:
    push rax
    push rbx
    push rcx
    push rdx
    push r12
    push r13
    push r14
    push rsi

    mov r12, rax

.sdir_loop:
    movsx r14, byte [rsi]
    mov r13, r12

.ray_loop:
    cmp r13, 0
    jl .next_dir
    cmp r13, 63
    jg .next_dir
    mov rax, r13
    and rax, 7

    cmp r14, -9
    je .diag
    cmp r14, -7
    je .diag
    cmp r14, 7
    je .diag
    cmp r14, 9
    je .diag
    cmp r14, -1
    je .west
    cmp r14, 1
    je .east
    jmp .north_south

.diag:
    cmp r14, -9
    je .diag_sw
    cmp r14, -7
    je .diag_se
    cmp r14, 7
    je .diag_nw
    ; NE (9)
    cmp rax, 7
    je .next_dir
    mov rax, r13
    shr rax, 3
    cmp rax, 7
    je .next_dir
    jmp .do_step
.diag_sw:
    cmp rax, 0
    je .next_dir
    mov rax, r13
    shr rax, 3
    cmp rax, 0
    je .next_dir
    jmp .do_step
.diag_se:
    cmp rax, 7
    je .next_dir
    mov rax, r13
    shr rax, 3
    cmp rax, 0
    je .next_dir
    jmp .do_step
.diag_nw:
    cmp rax, 0
    je .next_dir
    mov rax, r13
    shr rax, 3
    cmp rax, 7
    je .next_dir
    jmp .do_step

.west:
    cmp rax, 0
    je .next_dir
    jmp .do_step
.east:
    cmp rax, 7
    je .next_dir
    jmp .do_step
.north_south:
    mov rax, r13
    shr rax, 3
    cmp r14, -8
    je .north
    cmp rax, 7
    je .next_dir
    jmp .do_step
.north:
    cmp rax, 0
    je .next_dir

.do_step:
    add r13, r14

    mov rax, r13
    call is_own_piece
    test rax, rax
    jnz .next_dir

    push r14
    push r13                ; uloz cielove policko, add_move ho nici
    mov r14, FLAG_NORMAL
    call add_move
    pop r13                 ; obnov cielove policko
    pop r14

    mov rax, r13
    call is_enemy_piece
    test rax, rax
    jnz .next_dir

    jmp .ray_loop

.next_dir:
    inc rsi
    dec rcx
    jnz .sdir_loop

    pop rsi
    pop r14
    pop r13
    pop r12
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; generate_king_moves
; ============================================================
generate_king_moves:
    push rax
    push rbx
    push rcx
    push rdx
    push r12
    push r13
    push r14
    push rsi

    mov r12, rax
    mov rbx, rax
    and rbx, 7
    mov rcx, rax
    shr rcx, 3

    lea rsi, [king_dirs]
    xor rdx, rdx
.loop:
    movsx r13, byte [rsi + rdx]
    add r13, r12

    mov rax, r13
    and rax, 7
    sub rax, rbx
    mov r8, rax
    test r8, r8
    jns .check_abs_f
    neg r8
.check_abs_f:
    cmp r8, 1
    jg .next

    mov rax, r13
    shr rax, 3
    sub rax, rcx
    mov r8, rax
    test r8, r8
    jns .check_abs_r
    neg r8
.check_abs_r:
    cmp r8, 1
    jg .next

    cmp r13, 0
    jl .next
    cmp r13, 63
    jg .next

    mov rax, r13
    call is_own_piece
    test rax, rax
    jnz .next

    mov r14, FLAG_NORMAL
    call add_move

.next:
    inc rdx
    cmp rdx, 8
    jl .loop

    pop rsi
    pop r14
    pop r13
    pop r12
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; generate_castling
; ============================================================
generate_castling:
    push rax
    push rbx
    push r12
    push r13
    push r14

    movzx rbx, byte [side]
    test rbx, rbx
    jnz .black

.white_k:
    test byte [castle], CASTLE_WK
    jz .white_q
    mov r12, 4
    mov r13, 6
    mov rax, 5
    call is_square_empty
    test rax, rax
    jz .white_q
    mov rax, 6
    call is_square_empty
    test rax, rax
    jz .white_q
    lea rdi, [board]
    movzx rax, byte [rdi + 7]
    cmp rax, ROOK|WHITE
    jne .white_q
    mov r14, FLAG_CASTLE
    call add_move

.white_q:
    test byte [castle], CASTLE_WQ
    jz .done
    mov r12, 4
    mov r13, 2
    mov rax, 3
    call is_square_empty
    test rax, rax
    jz .done
    mov rax, 2
    call is_square_empty
    test rax, rax
    jz .done
    mov rax, 1
    call is_square_empty
    test rax, rax
    jz .done
    lea rdi, [board]
    movzx rax, byte [rdi + 0]
    cmp rax, ROOK|WHITE
    jne .done
    mov r14, FLAG_CASTLE
    call add_move
    jmp .done

.black:
    test byte [castle], CASTLE_BK
    jz .black_q
    mov r12, 60
    mov r13, 62
    mov rax, 61
    call is_square_empty
    test rax, rax
    jz .black_q
    mov rax, 62
    call is_square_empty
    test rax, rax
    jz .black_q
    lea rdi, [board]
    movzx rax, byte [rdi + 63]
    cmp rax, ROOK|BLACK
    jne .black_q
    mov r14, FLAG_CASTLE
    call add_move

.black_q:
    test byte [castle], CASTLE_BQ
    jz .done
    mov r12, 60
    mov r13, 58
    mov rax, 59
    call is_square_empty
    test rax, rax
    jz .done
    mov rax, 58
    call is_square_empty
    test rax, rax
    jz .done
    mov rax, 57
    call is_square_empty
    test rax, rax
    jz .done
    lea rdi, [board]
    movzx rax, byte [rdi + 56]
    cmp rax, ROOK|BLACK
    jne .done
    mov r14, FLAG_CASTLE
    call add_move

.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rax
    ret