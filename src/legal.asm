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
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rsi
    push rdi
    push rcx
    push rdx

    mov r12, rax            ; cielove policko
    mov r13, rbx            ; strana, ktorej krala kontrolujeme

    mov rax, r13
    xor rax, 1
    shl rax, 3
    mov r15, rax            ; farba supera

    lea rdi, [board]

    ; --- Pesiaci ---
    test r13, r13
    jnz .black_pawns

.white_pawns:
    ; super = cierny, cierny pesiak napadne z T+7 a T+9
    mov r14, r12
    add r14, 7
    call .check_pawn_attack
    test rax, rax
    jnz .attacked

    mov r14, r12
    add r14, 9
    call .check_pawn_attack
    test rax, rax
    jnz .attacked
    jmp .knights

.black_pawns:
    ; super = biely, biely pesiak napadne z T-7 a T-9
    mov r14, r12
    sub r14, 7
    call .check_pawn_attack
    test rax, rax
    jnz .attacked

    mov r14, r12
    sub r14, 9
    call .check_pawn_attack
    test rax, rax
    jnz .attacked
    jmp .knights

.check_pawn_attack:
    ; r14 = kandidat, r12 = ciel, r15 = farba supera
    cmp r14, 0
    jl .no_attack
    cmp r14, 63
    jg .no_attack

    ; |file(kandidat) - file(ciel)| == 1
    mov rax, r14
    and rax, 7
    mov rbx, r12
    and rbx, 7
    sub rax, rbx
    jns .abs_file
    neg rax
.abs_file:
    cmp rax, 1
    jne .no_attack

    movzx rax, byte [rdi + r14]
    and rax, PIECE_MASK
    cmp rax, PAWN
    jne .no_attack

    movzx rax, byte [rdi + r14]
    and rax, COLOR_MASK
    cmp rax, r15
    jne .no_attack

    mov rax, 1
    ret
.no_attack:
    xor rax, rax
    ret

    ; --- Jazdci ---
.knights:
    lea rsi, [knight_offsets]
    xor rcx, rcx
.knight_loop:
    movsx r14, byte [rsi + rcx]
    add r14, r12

    cmp r14, 0
    jl .next_knight
    cmp r14, 63
    jg .next_knight

    ; |file(kandidat) - file(ciel)| <= 2
    mov rax, r14
    and rax, 7
    mov rbx, r12
    and rbx, 7
    sub rax, rbx
    jns .abs_kf
    neg rax
.abs_kf:
    cmp rax, 2
    jg .next_knight

    movzx rax, byte [rdi + r14]
    and rax, PIECE_MASK
    cmp rax, KNIGHT
    jne .next_knight

    movzx rax, byte [rdi + r14]
    and rax, COLOR_MASK
    cmp rax, r15
    je .attacked

.next_knight:
    inc rcx
    cmp rcx, 8
    jl .knight_loop

    ; --- Kral ---
.king:
    lea rsi, [king_dirs]
    xor rcx, rcx
.king_loop:
    movsx r14, byte [rsi + rcx]
    add r14, r12

    cmp r14, 0
    jl .next_king
    cmp r14, 63
    jg .next_king

    ; |file(kandidat) - file(ciel)| <= 1
    mov rax, r14
    and rax, 7
    mov rbx, r12
    and rbx, 7
    sub rax, rbx
    jns .abs_king_f
    neg rax
.abs_king_f:
    cmp rax, 1
    jg .next_king

    movzx rax, byte [rdi + r14]
    and rax, PIECE_MASK
    cmp rax, KING
    jne .next_king

    movzx rax, byte [rdi + r14]
    and rax, COLOR_MASK
    cmp rax, r15
    je .attacked

.next_king:
    inc rcx
    cmp rcx, 8
    jl .king_loop

    ; --- Sliding: strelci a damy po diagonalach ---
.bishop_sliding:
    lea rsi, [bishop_dirs]
    xor rcx, rcx
.bishop_dir_loop:
    movsx r14, byte [rsi + rcx]
    mov r9, r12

.bishop_ray_loop:
    mov rbx, r9
    add rbx, r14

    cmp rbx, 0
    jl .next_bishop_dir
    cmp rbx, 63
    jg .next_bishop_dir

    ; kontrola wrap-around: |file(nove) - file(stare)| <= 1
    mov rax, rbx
    and rax, 7
    mov rdx, r9
    and rdx, 7
    sub rax, rdx
    jns .abs_bdf
    neg rax
.abs_bdf:
    cmp rax, 1
    jg .next_bishop_dir

    mov r9, rbx

    movzx rax, byte [rdi + r9]
    test rax, rax
    jz .bishop_ray_loop

    and rax, COLOR_MASK
    cmp rax, r15
    jne .next_bishop_dir

    movzx rax, byte [rdi + r9]
    and rax, PIECE_MASK
    cmp rax, BISHOP
    je .attacked
    cmp rax, QUEEN
    je .attacked
    jmp .next_bishop_dir

.next_bishop_dir:
    inc rcx
    cmp rcx, 4
    jl .bishop_dir_loop

    ; --- Sliding: veze a damy po radoch/stlpcoch ---
.rook_sliding:
    lea rsi, [rook_dirs]
    xor rcx, rcx
.rook_dir_loop:
    movsx r14, byte [rsi + rcx]
    mov r9, r12

.rook_ray_loop:
    mov rbx, r9
    add rbx, r14

    cmp rbx, 0
    jl .next_rook_dir
    cmp rbx, 63
    jg .next_rook_dir

    mov rax, rbx
    and rax, 7
    mov rdx, r9
    and rdx, 7
    sub rax, rdx
    jns .abs_rdf
    neg rax
.abs_rdf:
    cmp rax, 1
    jg .next_rook_dir

    mov r9, rbx

    movzx rax, byte [rdi + r9]
    test rax, rax
    jz .rook_ray_loop

    and rax, COLOR_MASK
    cmp rax, r15
    jne .next_rook_dir

    movzx rax, byte [rdi + r9]
    and rax, PIECE_MASK
    cmp rax, ROOK
    je .attacked
    cmp rax, QUEEN
    je .attacked
    jmp .next_rook_dir

.next_rook_dir:
    inc rcx
    cmp rcx, 4
    jl .rook_dir_loop

    ; nie je napadnute
    xor rax, rax
    jmp .done

.attacked:
    mov rax, 1
.done:
    pop rdx
    pop rcx
    pop rdi
    pop rsi
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

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

    ; skontroluj, ci nie je kral v sachu
    movzx rax, byte [side]
    call is_in_check
    test rax, rax
    jnz .remove_move

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
    call is_square_attacked
    pop rcx
    test rax, rax
    jnz .remove_move

    push rcx
    movzx rbx, byte [side]
    lea rax, [r14 + r13]
    call is_square_attacked
    pop rcx
    test rax, rax
    jnz .remove_move

    push rcx
    movzx rbx, byte [side]
    lea rax, [r14 + r13*2]
    call is_square_attacked
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
