tb_piece_char:
    cmp edx, QUEEN
    je .q
    cmp edx, ROOK
    je .r
    cmp edx, BISHOP
    je .b
    cmp edx, KNIGHT
    je .n
    cmp edx, PAWN
    je .p
    xor eax, eax
    ret
.q:
    mov al, 'Q'
    ret
.r:
    mov al, 'R'
    ret
.b:
    mov al, 'B'
    ret
.n:
    mov al, 'N'
    ret
.p:
    mov al, 'P'
    ret

; ============================================================
; tb_build_wdl_path - pripravi cestu k *.rtbw podla materialu
; Vstup: r13d = white non-king piece (0/typ), r14d = black non-king piece
; Vystup: rdi = cesta, eax = 1 success / 0 fail
; Pozn.: ak tb_path uz konci na .rtbw/.rtbz, pouzije sa priamo
; ============================================================
