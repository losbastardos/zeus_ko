tb_dec_symlen_get:
    push rbx
    push r8
    push r9
    push r10

    mov ebx, edx
    cmp ebx, esi
    jae .fail

    lea r8, [tb_sym_cache_state]
    movzx eax, byte [r8 + rbx]
    cmp eax, 2
    je .cached_ok
    cmp eax, 1
    je .fail
    cmp eax, 3
    je .fail

    mov byte [r8 + rbx], 1

    lea r9, [rbx + rbx*2]
    lea r9, [rdi + r9]

    movzx eax, byte [r9 + 1]
    movzx ecx, byte [r9 + 2]
    shl ecx, 4
    mov r10d, eax
    shr r10d, 4
    or ecx, r10d
    cmp ecx, 0x0fff
    jne .non_terminal

    lea r10, [tb_dec_symlen]
    mov byte [r10 + rbx], 0
    mov byte [r8 + rbx], 2
    xor ecx, ecx
    mov eax, 1
    jmp .done

.non_terminal:
    movzx eax, byte [r9 + 1]
    and eax, 0x0f
    shl eax, 8
    movzx edx, byte [r9]
    or eax, edx
    mov edx, eax
    call tb_dec_symlen_get
    test eax, eax
    jz .mark_fail
    mov r10d, ecx

    movzx eax, byte [r9 + 1]
    movzx ecx, byte [r9 + 2]
    shl ecx, 4
    mov edx, eax
    shr edx, 4
    or ecx, edx
    mov edx, ecx
    call tb_dec_symlen_get
    test eax, eax
    jz .mark_fail

    add ecx, r10d
    inc ecx
    lea r10, [tb_dec_symlen]
    mov [r10 + rbx], cl
    mov byte [r8 + rbx], 2
    mov eax, 1
    jmp .done

.cached_ok:
    lea r10, [tb_dec_symlen]
    movzx ecx, byte [r10 + rbx]
    mov eax, 1
    jmp .done

.mark_fail:
    mov byte [r8 + rbx], 3
.fail:
    xor eax, eax

.done:
    pop r10
    pop r9
    pop r8
    pop rbx
    ret

; ============================================================
; tb_encode_k2_num3_idx - idx pre enc_type=2,num=3,order 0/1
; Vstup: edi = wk sq, esi = bk sq, edx = extra sq, ecx = order
; Vystup: eax = 1 success / 0 fail, rdx = idx
; ============================================================
tb_encode_k2_num3_idx:
    push rbx
    push r8
    push r9

    mov r8d, edi
    mov r9d, esi
    mov ebx, edx

    test r8d, 4
    jz .f2
    xor r8d, 7
    xor r9d, 7
    xor ebx, 7
.f2:
    test r8d, 32
    jz .diag
    xor r8d, 56
    xor r9d, 56
    xor ebx, 56

.diag:
    lea rdx, [tb_offdiag]
    movsx eax, byte [rdx + r8]
    test eax, eax
    jnz .check0
    movsx eax, byte [rdx + r9]
    test eax, eax
    jz .diag_ok
.check0:
    cmp eax, 0
    jle .diag_ok
    lea rdx, [tb_flipdiag]
    movzx eax, byte [rdx + r8]
    mov r8d, eax
    movzx eax, byte [rdx + r9]
    mov r9d, eax
    movzx eax, byte [rdx + rbx]
    mov ebx, eax

.diag_ok:
    lea rdx, [tb_triangle]
    movzx eax, byte [rdx + r8]
    imul eax, eax, 64
    add eax, r9d
    lea rdx, [tb_KK_idx]
    movsx eax, word [rdx + rax*2]
    test eax, eax
    js .fail
    mov r10d, eax

    xor edx, edx
    cmp ebx, r8d
    setg dl
    xor esi, esi
    cmp ebx, r9d
    setg sil
    add edx, esi
    mov eax, ebx
    sub eax, edx
    cmp eax, 0
    jl .fail
    cmp eax, 61
    jg .fail

    cmp ecx, 0
    je .order0
    cmp ecx, 1
    jne .fail
    imul r10d, r10d, 62
    add eax, r10d
    mov edx, eax
    mov eax, 1
    jmp .done

.order0:
    imul eax, eax, 462
    add eax, r10d
    mov edx, eax
    mov eax, 1
    jmp .done

.fail:
    xor eax, eax
    xor edx, edx

.done:
    pop r9
    pop r8
    pop rbx
    ret

; ============================================================
; tb_encode_pawn1_num3_idx - idx pre 1 pawn + 2 kings
; Vstup: edi = pawn sq, esi = kingA sq, edx = kingB sq, ecx = order (0..2)
; Vystup: eax = 1 success / 0 fail, rdx = idx
; Pozn.: kingA/kingB poradie musi zodpovedat pieces[] poradiu tabulky.
; ============================================================
tb_encode_pawn1_num3_idx:
    push rbx
    push r8
    push r9

    mov r8d, edi
    mov r9d, esi
    mov ebx, edx

    ; mirror na a-d file
    test r8d, 4
    jz .pawn_mirror_done
    xor r8d, 7
    xor r9d, 7
    xor ebx, 7
.pawn_mirror_done:

    lea rdx, [tb_flap]
    movzx eax, byte [rdx + r8]
    cmp eax, 23
    ja .fail

    ; idxPawn = flap % 6
    mov edx, eax
.mod6:
    cmp edx, 6
    jb .have_idxpawn
    sub edx, 6
    jmp .mod6
.have_idxpawn:
    mov r10d, edx                  ; idxPawn 0..5

    ; s1 = kingA - (kingA > pawn)
    xor edx, edx
    cmp r9d, r8d
    setg dl
    mov eax, r9d
    sub eax, edx
    cmp eax, 0
    jl .fail
    cmp eax, 62
    ja .fail
    mov r11d, eax                  ; s1

    ; s2 = kingB - (kingB > pawn) - (kingB > kingA)
    xor edx, edx
    cmp ebx, r8d
    setg dl
    xor esi, esi
    cmp ebx, r9d
    setg sil
    add edx, esi
    mov eax, ebx
    sub eax, edx
    cmp eax, 0
    jl .fail
    cmp eax, 61
    ja .fail
    mov r8d, eax                   ; s2

    cmp ecx, 0
    je .order0
    cmp ecx, 1
    je .order1
    cmp ecx, 2
    je .order2
    jmp .fail

.order0:
    ; idx = idxPawn + s1*6 + s2*378
    mov eax, r11d
    imul eax, eax, 6
    mov edx, r8d
    imul edx, edx, 378
    add eax, edx
    add eax, r10d
    mov edx, eax
    mov eax, 1
    jmp .done

.order1:
    ; idx = idxPawn*63 + s1 + s2*378
    mov eax, r10d
    imul eax, eax, 63
    add eax, r11d
    mov edx, r8d
    imul edx, edx, 378
    add eax, edx
    mov edx, eax
    mov eax, 1
    jmp .done

.order2:
    ; idx = idxPawn*3906 + s1 + s2*63
    mov eax, r10d
    imul eax, eax, 3906
    add eax, r11d
    mov edx, r8d
    imul edx, edx, 63
    add eax, edx
    mov edx, eax
    mov eax, 1
    jmp .done

.fail:
    xor eax, eax
    xor edx, edx

.done:
    pop r9
    pop r8
    pop rbx
    ret

; ============================================================
; tb_pairs_decode_symbol_idx - decode raw symbol zo setup_pairs a idx
; Vstup: rdi = setup_pairs ptr, rsi = map_end, rdx = tb_size, rcx = idx
; Vystup: eax = 1 success / 0 fail, edx = raw symbol
; ============================================================
