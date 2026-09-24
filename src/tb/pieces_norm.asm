; ============================================================
; pieces_norm.asm - pieces/norm/factor parser pre pawnless TB
; ============================================================

section .text

; ============================================================
; tb_setup_pieces_piece
; Vstup: rdi = map base, rsi = map_size
; Vystup: eax = 1 success / 0 fail
; Pozn.: ocakava ze [tb_num] je nastavene (pocet figur na sachovnici)
; ============================================================
tb_setup_pieces_piece:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11

    mov r8, rdi
    mov r9, rsi

    cmp r9, 16
    jb .fail

    mov eax, [tb_num]
    cmp eax, 2
    jb .fail
    cmp eax, 8
    ja .fail

    ; flags nibble -> enc_type
    movzx eax, byte [r8 + 4]
    shr eax, 4
    test eax, eax
    jz .enc_done
    dec eax
.enc_done:
    mov [tb_enc_type], eax

    ; order byte (nibble pre bside 0/1)
    movzx r10d, byte [r8 + 5]

    ; data sanity: pieces bytes od +6 musi pokryt [tb_num]
    mov eax, [tb_num]
    mov ecx, eax
    add ecx, 6
    cmp rcx, r9
    ja .fail

    ; clear norm/factor/pieces
    lea rdi, [tb_pieces]
    xor eax, eax
    mov ecx, 16
    rep stosb

    lea rdi, [tb_norm]
    xor eax, eax
    mov ecx, 16
    rep stosd

    lea rdi, [tb_factor]
    xor eax, eax
    mov ecx, 16
    rep stosq

    ; pieces[0][i] = low nibble, pieces[1][i] = high nibble
    lea r11, [r8 + 6]
    xor edx, edx
.copy_loop:
    cmp edx, [tb_num]
    jae .copied
    movzx eax, byte [r11 + rdx]
    mov ecx, eax
    and ecx, 0x0f
    mov [tb_pieces + rdx], cl
    shr eax, 4
    mov [tb_pieces + 8 + rdx], al
    inc edx
    jmp .copy_loop
.copied:

    ; enc_type odvod z materialu pieces[0] (Syzygy set_norm_piece semantics)
    call tb_derive_enc_type_from_pieces0
    mov [tb_enc_type], eax

    ; bside 0
    lea rdi, [tb_pieces]
    lea rsi, [tb_norm]
    call tb_set_norm_piece
    lea rdi, [tb_factor]
    lea rsi, [tb_norm]
    movzx edx, r10b
    and edx, 0x0f
    call tb_calc_factors_piece
    mov [tb_tb_size], rax

    ; bside 1
    lea rdi, [tb_pieces + 8]
    lea rsi, [tb_norm + 8*4]
    call tb_set_norm_piece
    lea rdi, [tb_factor + 8*8]
    lea rsi, [tb_norm + 8*4]
    movzx edx, r10b
    shr edx, 4
    call tb_calc_factors_piece
    mov [tb_tb_size + 8], rax

    mov eax, 1
    jmp .done

.fail:
    xor eax, eax

.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; tb_derive_enc_type_from_pieces0
; Vstup: [tb_pieces], [tb_num]
; Vystup: eax = enc_type
; Logika:
; - j = pocet piece-kodov s presne 1 vyskytom
; - ak j >= 3 -> enc_type=0
; - ak j == 2 -> enc_type=2
; - inak enc_type = 1 + min_count_gt1
; ============================================================
tb_derive_enc_type_from_pieces0:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11

    xor r10d, r10d                ; j (singletons)
    mov r11d, 255                 ; min_count_gt1 sentinel
    xor ebx, ebx                  ; i

.denc_i_loop:
    cmp ebx, [tb_num]
    jae .denc_finish_scan

    ; skip ak uz rovnaky kod bol skor
    movzx eax, byte [tb_pieces + rbx]
    xor ecx, ecx
.denc_seen_loop:
    cmp ecx, ebx
    jae .denc_count
    movzx edx, byte [tb_pieces + rcx]
    cmp edx, eax
    je .denc_i_next
    inc ecx
    jmp .denc_seen_loop

.denc_count:
    xor r8d, r8d
    xor ecx, ecx
.denc_count_loop:
    cmp ecx, [tb_num]
    jae .denc_classify
    movzx edx, byte [tb_pieces + rcx]
    cmp edx, eax
    jne .denc_count_next
    inc r8d
.denc_count_next:
    inc ecx
    jmp .denc_count_loop

.denc_classify:
    cmp r8d, 1
    jne .denc_multi
    inc r10d
    jmp .denc_i_next

.denc_multi:
    cmp r8d, r11d
    jae .denc_i_next
    mov r11d, r8d

.denc_i_next:
    inc ebx
    jmp .denc_i_loop

.denc_finish_scan:
    cmp r10d, 3
    jae .denc_enc0
    cmp r10d, 2
    je .denc_enc2

    cmp r11d, 255
    jne .denc_have_min
    mov eax, 3                    ; fallback na enc_type=3 ak by nebolo multi
    jmp .denc_done

.denc_have_min:
    mov eax, r11d
    inc eax
    jmp .denc_done

.denc_enc0:
    xor eax, eax
    jmp .denc_done

.denc_enc2:
    mov eax, 2

.denc_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; tb_set_norm_piece
; Vstup: rdi = pieces[8] source, rsi = norm[8] destination
; ============================================================
tb_set_norm_piece:
    push rbx
    push rcx
    push rdx
    push r8
    push r9

    mov eax, [tb_enc_type]
    cmp eax, 0
    je .enc0
    cmp eax, 2
    je .enc2
    ; enc_type >= 3 mimo aktualny scope: conservative fallback
    mov ebx, eax
    dec ebx
    jmp .base_ready
.enc0:
    mov ebx, 3
    jmp .base_ready
.enc2:
    mov ebx, 2
.base_ready:
    mov [rsi], ebx

    mov ecx, ebx
    mov edx, [tb_num]
.outer:
    cmp ecx, edx
    jae .done
    mov r8d, ecx
.inner:
    cmp r8d, edx
    jae .inner_done
    movzx eax, byte [rdi + r8]
    movzx r9d, byte [rdi + rcx]
    cmp eax, r9d
    jne .inner_done
    inc dword [rsi + rcx*4]
    inc r8d
    jmp .inner
.inner_done:
    add ecx, [rsi + rcx*4]
    jmp .outer

.done:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; tb_calc_factors_piece
; Vstup: rdi = factor[8], rsi = norm[8], edx = order nibble
; Vystup: rax = tb_size
; ============================================================
tb_calc_factors_piece:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11

    mov eax, [tb_enc_type]
    cmp eax, 0
    je .enc_ok
    cmp eax, 2
    je .enc_ok
    cmp eax, 3
    je .enc_ok
    xor eax, eax
    jmp .done

.enc_ok:
    ; General Syzygy-like calc_factors_piece pre enc_type 0/2/3.
    ; n = 64 - norm[0], f = 1
    mov r8, rdi                   ; factor ptr
    mov r9, rsi                   ; norm ptr
    mov r10d, edx                 ; order

    mov eax, 64
    sub eax, [r9]
    mov r11d, eax                 ; n

    mov rax, 1                    ; f
    mov ebx, [r9]                 ; i = norm[0]
    xor ecx, ecx                  ; k = 0

.enc3_loop:
    mov edx, [tb_num]
    cmp ebx, edx
    jl .enc3_body
    cmp ecx, r10d
    jne .enc3_finish

.enc3_body:
    cmp ecx, r10d
    jne .enc3_group

    ; factor[0] = f; f *= pivfac[enc_type]
    mov [r8], rax
    mov edx, [tb_enc_type]
    cmp edx, 0
    je .pivot_0
    cmp edx, 2
    je .pivot_2
    imul rax, 278
    jmp .pivot_done
.pivot_0:
    imul rax, 31332
    jmp .pivot_done
.pivot_2:
    imul rax, 462
.pivot_done:
    inc ecx
    jmp .enc3_loop

.enc3_group:
    ; factor[i] = f
    mov [r8 + rbx*8], rax

    ; f *= subfactor(norm[i], n)
    mov edi, [r9 + rbx*4]
    mov esi, r11d
    push rax
    push rcx
    push rbx
    push r8
    push r9
    push r10
    push r11
    call tb_subfactor
    mov rdx, rax
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbx
    pop rcx
    pop rax
    imul rax, rdx

    ; n -= norm[i]; i += norm[i]
    mov edx, [r9 + rbx*4]
    sub r11d, edx
    add ebx, edx

    inc ecx
    jmp .enc3_loop

.enc3_finish:
    ; f je final tb_size

.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; tb_subfactor(k, n) = C(n, k)
; Vstup: edi = k, esi = n
; Vystup: rax = result
; ============================================================
tb_subfactor:
    push rbx
    push rcx
    push rdx
    push r8

    mov ecx, edi
    mov ebx, esi
    mov rax, rbx
    mov r8, 1
    cmp ecx, 1
    jle .div
    mov edx, 1
.loop:
    cmp edx, ecx
    jae .div
    dec rbx
    imul rax, rbx
    inc edx
    imul r8, rdx
    jmp .loop
.div:
    xor edx, edx
    div r8

    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret
