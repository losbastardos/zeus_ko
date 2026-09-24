; ============================================================
; tb_wdl_fallback_4pc_class - material fallback pre 4-piece WDL
; Vystup: eax = TB_WIN/TB_DRAW/TB_LOSS (STM perspektiva)
; Pozn.: pouziva sa len ako konservativny fallback, ked full decode zlyha
; alebo vrati draw v zjavne materialne nevyrovnanej 4-piece pozicii.
; ============================================================
tb_wdl_fallback_4pc_class:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    lea rsi, [board]
    xor ebx, ebx                  ; white mat
    xor ecx, ecx                  ; black mat
    xor edx, edx                  ; sq

.fb_scan:
    cmp edx, 64
    jae .fb_done_scan
    movzx edi, byte [rsi + rdx]
    test edi, edi
    jz .fb_next

    mov eax, edi
    and eax, PIECE_MASK
    cmp eax, KING
    je .fb_next

    ; jednoducha materialna stupnica: P=1, N/B=3, R=5, Q=9
    cmp eax, PAWN
    je .fb_val_p
    cmp eax, KNIGHT
    je .fb_val_n
    cmp eax, BISHOP
    je .fb_val_b
    cmp eax, ROOK
    je .fb_val_r
    cmp eax, QUEEN
    je .fb_val_q
    xor eax, eax
    jmp .fb_have_val

.fb_val_p:
    mov eax, 1
    jmp .fb_have_val
.fb_val_n:
.fb_val_b:
    mov eax, 3
    jmp .fb_have_val
.fb_val_r:
    mov eax, 5
    jmp .fb_have_val
.fb_val_q:
    mov eax, 9

.fb_have_val:
    test edi, COLOR_MASK
    jz .fb_add_white
    add ecx, eax
    jmp .fb_next

.fb_add_white:
    add ebx, eax

.fb_next:
    inc edx
    jmp .fb_scan

.fb_done_scan:
    movzx edx, byte [side]
    test edx, edx
    jz .fb_white_stm

    ; black na tahu: diff = black - white
    mov eax, ecx
    sub eax, ebx
    jmp .fb_eval

.fb_white_stm:
    ; white na tahu: diff = white - black
    mov eax, ebx
    sub eax, ecx

.fb_eval:
    test eax, eax
    jg .fb_win
    jl .fb_loss
    mov eax, TB_DRAW
    jmp .fb_ret

.fb_win:
    mov eax, TB_WIN
    jmp .fb_ret

.fb_loss:
    mov eax, TB_LOSS

.fb_ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
