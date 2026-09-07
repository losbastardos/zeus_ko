; ============================================================
; eval.asm - jednoducha evaluacna funkcia
; ============================================================

%include "chess.inc"

DEFAULT REL

section .data

global evaluate

material:
    dd 0            ; EMPTY
    dd 100          ; PAWN
    dd 320          ; KNIGHT
    dd 330          ; BISHOP
    dd 500          ; ROOK
    dd 900          ; QUEEN
    dd 20000        ; KING

pst_empty:  times 64 db 0

pst_pawn:
    db   0,  0,  0,  0,  0,  0,  0,  0
    db  50, 50, 50, 50, 50, 50, 50, 50
    db  10, 10, 20, 30, 30, 20, 10, 10
    db   5,  5, 10, 25, 25, 10,  5,  5
    db   0,  0,  0, 20, 20,  0,  0,  0
    db   5, -5,-10,  0,  0,-10, -5,  5
    db   5, 10, 10,-20,-20, 10, 10,  5
    db   0,  0,  0,  0,  0,  0,  0,  0

pst_knight:
    db -50,-40,-30,-30,-30,-30,-40,-50
    db -40,-20,  0,  0,  0,  0,-20,-40
    db -30,  0, 10, 15, 15, 10,  0,-30
    db -30,  5, 15, 20, 20, 15,  5,-30
    db -30,  0, 15, 20, 20, 15,  0,-30
    db -30,  5, 10, 15, 15, 10,  5,-30
    db -40,-20,  0,  5,  5,  0,-20,-40
    db -50,-40,-30,-30,-30,-30,-40,-50

pst_bishop:
    db -20,-10,-10,-10,-10,-10,-10,-20
    db -10,  0,  0,  0,  0,  0,  0,-10
    db -10,  0,  5, 10, 10,  5,  0,-10
    db -10,  5,  5, 10, 10,  5,  5,-10
    db -10,  0, 10, 10, 10, 10,  0,-10
    db -10, 10, 10, 10, 10, 10, 10,-10
    db -10,  5,  0,  0,  0,  0,  5,-10
    db -20,-10,-10,-10,-10,-10,-10,-20

pst_rook:
    db   0,  0,  0,  0,  0,  0,  0,  0
    db   5, 10, 10, 10, 10, 10, 10,  5
    db  -5,  0,  0,  0,  0,  0,  0, -5
    db  -5,  0,  0,  0,  0,  0,  0, -5
    db  -5,  0,  0,  0,  0,  0,  0, -5
    db  -5,  0,  0,  0,  0,  0,  0, -5
    db  -5,  0,  0,  0,  0,  0,  0, -5
    db   0,  0,  0,  5,  5,  0,  0,  0

pst_queen:
    db -20,-10,-10, -5, -5,-10,-10,-20
    db -10,  0,  0,  0,  0,  0,  0,-10
    db -10,  0,  5,  5,  5,  5,  0,-10
    db  -5,  0,  5,  5,  5,  5,  0, -5
    db   0,  0,  5,  5,  5,  5,  0, -5
    db -10,  5,  5,  5,  5,  5,  0,-10
    db -10,  0,  5,  0,  0,  0,  0,-10
    db -20,-10,-10, -5, -5,-10,-10,-20

pst_king:
    db -30,-40,-40,-50,-50,-40,-40,-30
    db -30,-40,-40,-50,-50,-40,-40,-30
    db -30,-40,-40,-50,-50,-40,-40,-30
    db -30,-40,-40,-50,-50,-40,-40,-30
    db -20,-30,-30,-40,-40,-30,-30,-20
    db -10,-20,-20,-20,-20,-20,-20,-10
    db  20, 20,  0,  0,  0,  0, 20, 20
    db  20, 30, 10,  0,  0, 10, 30, 20

pst_ptrs:
    dq pst_empty
    dq pst_pawn
    dq pst_knight
    dq pst_bishop
    dq pst_rook
    dq pst_queen
    dq pst_king

; masky stlpcov (bit f, f+8, ...) pre pawn structure / open files
file_masks:
    dq 0x0101010101010101
    dq 0x0202020202020202
    dq 0x0404040404040404
    dq 0x0808080808080808
    dq 0x1010101010101010
    dq 0x2020202020202020
    dq 0x4040404040404040
    dq 0x8080808080808080

; rank r: bity policok s VYSSIM rankom (r+1..7) - blockery pesiaca
hi_rank_masks:
    dq 0xFFFFFFFFFFFFFF00
    dq 0xFFFFFFFFFFFF0000
    dq 0xFFFFFFFFFF000000
    dq 0xFFFFFFFF00000000
    dq 0xFFFFFF0000000000
    dq 0xFFFF000000000000
    dq 0xFF00000000000000
    dq 0

; rank r: bity policok s NIZSIM rankom (0..r-1)
lo_rank_masks:
    dq 0
    dq 0xFF
    dq 0xFFFF
    dq 0xFFFFFF
    dq 0xFFFFFFFF
    dq 0xFFFFFFFFFF
    dq 0xFFFFFFFFFFFF
    dq 0xFFFFFFFFFFFFFF

; bonusy/penale (centipwny)
BISHOP_PAIR    equ 30
DOUBLED_PEN    equ 12
ISOLATED_PEN   equ 15
PASSED_BASE    equ 10
PASSED_STEP    equ 20
ROOK_OPEN      equ 25
ROOK_SEMI      equ 10
ROOK_SEVENTH   equ 15
TEMPO_BONUS    equ 10

section .text

extern board
extern side

; ============================================================
; evaluate - vrati skore z pohladu bieleho
; Vystup: eax = skore
; ============================================================
evaluate:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rsi
    push rdi

    ; lokaly:
    ; [rbp-8]  = maska bielych pesiacov
    ; [rbp-16] = maska ciernych pesiacov
    ; [rbp-24..-17] = pocty bielych pesiacov per file
    ; [rbp-32..-25] = pocty ciernych pesiacov per file
    ; [rbp-36] = pocet bielych strelcov (dword)
    ; [rbp-40] = pocet ciernych strelcov (dword)
    xor eax, eax
    mov [rbp - 8], rax
    mov [rbp - 16], rax
    mov [rbp - 24], rax
    mov [rbp - 32], rax
    mov [rbp - 40], rax

    xor r15d, r15d          ; celkove skore
    xor r12, r12            ; index policka

.next_square:
    lea rsi, [board]
    movzx r13d, byte [rsi + r12]
    test r13d, r13d
    jz .skip

    mov r14d, r13d
    and r14d, PIECE_MASK    ; typ figury
    and r13d, COLOR_MASK    ; farba (0 alebo BLACK=8)

    ; material
    lea rdi, [material]
    mov eax, dword [rdi + r14*4]

    ; PST
    lea rdi, [pst_ptrs]
    mov rdi, [rdi + r14*8]
    mov rbx, r12
    test r13d, r13d
    jz .pst_index
    xor rbx, 56             ; mirror pre cierne
.pst_index:
    movsx ebx, byte [rdi + rbx]
    add eax, ebx            ; eax = hodnota figury z pohladu bieleho

    test r13d, r13d
    jz .add_white
    sub r15d, eax
    jmp .collect
.add_white:
    add r15d, eax

.collect:
    ; zber dat pre pawn structure / bishop pair
    cmp r14d, PAWN
    jne .col_bishop
    mov ebx, r12d
    and ebx, 7              ; file
    mov rdi, 1
    mov ecx, r12d
    shl rdi, cl             ; bit policka
    test r13d, r13d
    jnz .col_black_pawn
    or [rbp - 8], rdi
    inc byte [rbp - 24 + rbx]
    jmp .skip
.col_black_pawn:
    or [rbp - 16], rdi
    inc byte [rbp - 32 + rbx]
    jmp .skip
.col_bishop:
    cmp r14d, BISHOP
    jne .skip
    test r13d, r13d
    jnz .col_black_bishop
    inc dword [rbp - 36]
    jmp .skip
.col_black_bishop:
    inc dword [rbp - 40]

.skip:
    inc r12
    cmp r12, 64
    jl .next_square

    ; --- bishop pair ---
    cmp dword [rbp - 36], 2
    jl .no_bp_w
    add r15d, BISHOP_PAIR
.no_bp_w:
    cmp dword [rbp - 40], 2
    jl .no_bp_b
    sub r15d, BISHOP_PAIR
.no_bp_b:

    ; --- pawn structure per file: doubled + isolated ---
    xor r12, r12            ; file
.file_loop:
    movzx eax, byte [rbp - 24 + r12]    ; wcount
    movzx ebx, byte [rbp - 32 + r12]    ; bcount

    ; doubled: kazdy dalsi pesiak na file -DOUBLED_PEN
    cmp eax, 1
    jle .no_dbl_w
    lea ecx, [eax - 1]
    imul ecx, ecx, DOUBLED_PEN
    sub r15d, ecx
.no_dbl_w:
    cmp ebx, 1
    jle .no_dbl_b
    lea ecx, [ebx - 1]
    imul ecx, ecx, DOUBLED_PEN
    add r15d, ecx
.no_dbl_b:

    ; isolated biely: ziadny biely pesiak na susednych files
    test eax, eax
    jz .iso_w_done
    test r12, r12
    jz .iso_w_left_ok
    cmp byte [rbp - 24 + r12 - 1], 0
    jne .iso_w_done
.iso_w_left_ok:
    cmp r12, 7
    je .iso_w_pen
    cmp byte [rbp - 24 + r12 + 1], 0
    jne .iso_w_done
.iso_w_pen:
    imul ecx, eax, ISOLATED_PEN
    sub r15d, ecx
.iso_w_done:

    ; isolated cierny
    test ebx, ebx
    jz .iso_b_done
    test r12, r12
    jz .iso_b_left_ok
    cmp byte [rbp - 32 + r12 - 1], 0
    jne .iso_b_done
.iso_b_left_ok:
    cmp r12, 7
    je .iso_b_pen
    cmp byte [rbp - 32 + r12 + 1], 0
    jne .iso_b_done
.iso_b_pen:
    imul ecx, ebx, ISOLATED_PEN
    add r15d, ecx
.iso_b_done:

    inc r12
    cmp r12, 8
    jl .file_loop

    ; --- passed pawns: biele ---
    mov rax, [rbp - 8]
.pp_w_loop:
    test rax, rax
    jz .pp_w_done
    bsf rdx, rax
    btr rax, rdx
    ; file mask so susednymi
    mov rbx, rdx
    and rbx, 7
    lea rsi, [file_masks]
    mov rdi, [rsi + rbx*8]
    test rbx, rbx
    jz .pp_w_noleft
    or rdi, [rsi + rbx*8 - 8]
.pp_w_noleft:
    cmp rbx, 7
    je .pp_w_noright
    or rdi, [rsi + rbx*8 + 8]
.pp_w_noright:
    ; blockery = cierne pesiacie vysie ranky na 3 files
    mov rcx, rdx
    shr rcx, 3
    lea rsi, [hi_rank_masks]
    mov rsi, [rsi + rcx*8]
    and rdi, rsi
    and rdi, [rbp - 16]
    jnz .pp_w_loop
    ; passed: bonus = PASSED_BASE + PASSED_STEP * rank
    imul ecx, ecx, PASSED_STEP
    add ecx, PASSED_BASE
    add r15d, ecx
    jmp .pp_w_loop
.pp_w_done:

    ; --- passed pawns: cierne ---
    mov rax, [rbp - 16]
.pp_b_loop:
    test rax, rax
    jz .pp_b_done
    bsf rdx, rax
    btr rax, rdx
    mov rbx, rdx
    and rbx, 7
    lea rsi, [file_masks]
    mov rdi, [rsi + rbx*8]
    test rbx, rbx
    jz .pp_b_noleft
    or rdi, [rsi + rbx*8 - 8]
.pp_b_noleft:
    cmp rbx, 7
    je .pp_b_noright
    or rdi, [rsi + rbx*8 + 8]
.pp_b_noright:
    ; blockery = biele pesiacie na nizsich rankoch
    mov rcx, rdx
    shr rcx, 3
    lea rsi, [lo_rank_masks]
    mov rsi, [rsi + rcx*8]
    and rdi, rsi
    and rdi, [rbp - 8]
    jnz .pp_b_loop
    ; passed: bonus = PASSED_BASE + PASSED_STEP * (7 - rank); rcx = rank
    ; pozor: nepouzivat eax/rax - v rax je maska ciernych pesiacov!
    mov edx, 7
    sub edx, ecx
    imul edx, edx, PASSED_STEP
    add edx, PASSED_BASE
    sub r15d, edx
    jmp .pp_b_loop
.pp_b_done:

    ; --- veze: open/semi-open file, 7. rank ---
    xor r12, r12
.rook_loop:
    lea rsi, [board]
    movzx eax, byte [rsi + r12]
    mov ebx, eax
    and ebx, PIECE_MASK
    cmp ebx, ROOK
    jne .rook_next
    mov r13d, eax
    and r13d, COLOR_MASK
    mov rbx, r12
    and rbx, 7
    lea rsi, [file_masks]
    mov rdi, [rsi + rbx*8]
    ; open file? ziadny pesiak (ani biely ani cierny)
    mov rax, [rbp - 8]
    or rax, [rbp - 16]
    test rax, rdi
    jnz .rook_semi
    test r13d, r13d
    jnz .rook_open_b
    add r15d, ROOK_OPEN
    jmp .rook_rank
.rook_open_b:
    sub r15d, ROOK_OPEN
    jmp .rook_rank
.rook_semi:
    ; semi-open: ziadny vlastny pesiak na file
    test r13d, r13d
    jnz .rook_semi_b
    mov rax, [rbp - 8]
    jmp .rook_semi_test
.rook_semi_b:
    mov rax, [rbp - 16]
.rook_semi_test:
    test rax, rdi
    jnz .rook_rank
    test r13d, r13d
    jnz .rook_semi_b2
    add r15d, ROOK_SEMI
    jmp .rook_rank
.rook_semi_b2:
    sub r15d, ROOK_SEMI
.rook_rank:
    ; 7. rank: biely rank 6, cierny rank 1
    mov rax, r12
    shr eax, 3
    test r13d, r13d
    jnz .rook_rank_b
    cmp eax, 6
    jne .rook_next
    add r15d, ROOK_SEVENTH
    jmp .rook_next
.rook_rank_b:
    cmp eax, 1
    jne .rook_next
    sub r15d, ROOK_SEVENTH
.rook_next:
    inc r12
    cmp r12, 64
    jl .rook_loop

    ; --- tempo bonus pre stranu na tahu ---
    lea rsi, [side]
    movzx eax, byte [rsi]
    test eax, eax
    jnz .tempo_b
    add r15d, TEMPO_BONUS
    jmp .tempo_done
.tempo_b:
    sub r15d, TEMPO_BONUS
.tempo_done:

    mov eax, r15d

    pop rdi
    pop rsi
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov rsp, rbp
    pop rbp
    ret
