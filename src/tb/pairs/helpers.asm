; ============================================================
; tb_sym_leaf_uniform - zisti, ci symbol v sympat strome dekoduje
; na unikatnu terminalnu leaf hodnotu.
; Vstup: rdi = sympat ptr, esi = num_syms, edx = sym_idx
; Vystup: eax = 1 uspech / 0 fail|mixed
;         dl  = leaf value pri uspechu
; Pozn.: pouziva tb_sym_cache_state/value.
; ============================================================
tb_sym_leaf_uniform:
    push rbx
    push rcx
    push r8
    push r9
    push r10

    mov ebx, edx

    cmp ebx, esi
    jae .fail

    lea r8, [tb_sym_cache_state]
    movzx ecx, byte [r8 + rbx]
    cmp ecx, 2
    je .cached_ok
    cmp ecx, 3
    je .fail
    cmp ecx, 1
    je .fail

    mov byte [r8 + rbx], 1

    lea r9, [rbx + rbx*2]
    lea r9, [rdi + r9]

    movzx ecx, byte [r9 + 1]
    movzx eax, byte [r9 + 2]
    shl eax, 4
    mov r10d, eax
    mov eax, ecx
    shr eax, 4
    or r10d, eax                 ; s2

    cmp r10d, 0x0fff
    jne .non_terminal

    movzx edx, byte [r9]
    lea rcx, [tb_sym_cache_value]
    mov [rcx + rbx], dl
    mov byte [r8 + rbx], 2
    mov eax, 1
    jmp .done

.non_terminal:
    mov eax, ecx
    and eax, 0x0f
    shl eax, 8
    movzx ecx, byte [r9]
    or eax, ecx                  ; s1
    mov r11d, eax

    mov edx, r11d
    call tb_sym_leaf_uniform
    test eax, eax
    jz .mark_fail
    mov ecx, edx                 ; val1

    mov edx, r10d
    call tb_sym_leaf_uniform
    test eax, eax
    jz .mark_fail
    cmp dl, cl
    jne .mark_fail

    ; success: cache value for current symbol
    lea r9, [tb_sym_cache_value]
    mov [r9 + rbx], cl
    mov byte [r8 + rbx], 2
    movzx edx, cl
    mov eax, 1
    jmp .done

.cached_ok:
    lea r9, [tb_sym_cache_value]
    movzx edx, byte [r9 + rbx]
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
    pop rcx
    pop rbx
    ret

; ============================================================
; tb_pairs_uniform_root - skusi odvodit globalne konstantnu leaf hodnotu
; pre setup_pairs strom (aj pri idxbits>0), ak vsetky root symboly
; dekoduju na rovnaku hodnotu.
; Vstup: rdi = sympat ptr, esi = num_syms
; Vystup: eax = 1 uspech / 0 fail
;         dl  = leaf value pri uspechu
; ============================================================
tb_pairs_uniform_root:
    push rbx
    push rcx
    push r8
    push r12

    test rdi, rdi
    jz .fail
    test esi, esi
    jle .fail
    cmp esi, 4096
    ja .fail

    ; reset cache state len pre aktivny rozsah num_syms
    lea r8, [tb_sym_cache_state]
    xor ecx, ecx
.clr:
    cmp ecx, esi
    jae .scan
    mov byte [r8 + rcx], 0
    inc ecx
    jmp .clr

.scan:
    xor ebx, ebx
    mov r12d, -1
.scan_loop:
    cmp ebx, esi
    jae .ok
    mov edx, ebx
    call tb_sym_leaf_uniform
    test eax, eax
    jz .fail
    cmp r12d, -1
    jne .cmp_prev
    movzx r12d, dl
    jmp .next
.cmp_prev:
    cmp dl, r12b
    jne .fail
.next:
    inc ebx
    jmp .scan_loop

.ok:
    mov dl, r12b
    mov eax, 1
    jmp .done

.fail:
    xor eax, eax

.done:
    pop r12
    pop r8
    pop rcx
    pop rbx
    ret

; ============================================================
; tb_wdl_is_target_3pc_pawnless - cielovy scope pre full decode
; Vstup: r13d = white non-king typ, r14d = black non-king typ
; Vystup: eax = 1 (KQ/KR/KB/KN vs K alebo opacne), inak 0
; ============================================================
tb_wdl_is_target_3pc_pawnless:
    xor eax, eax
    test r13d, r13d
    jz .white_empty
    test r14d, r14d
    jnz .ret
    mov edx, r13d
    jmp .check
.white_empty:
    test r14d, r14d
    jz .ret
    mov edx, r14d
.check:
    cmp edx, QUEEN
    je .yes
    cmp edx, ROOK
    je .yes
    cmp edx, BISHOP
    je .yes
    cmp edx, KNIGHT
    jne .ret
.yes:
    mov eax, 1
.ret:
    ret

; ============================================================
; tb_dec_symlen_get - symlen(sym) pre decompress_pairs
; Vstup: rdi = sympat ptr, esi = num_syms, edx = sym
; Vystup: eax = 1 success / 0 fail, ecx = symlen
; ============================================================
