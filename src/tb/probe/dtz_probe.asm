tb_probe_dtz:
    push rbx
    push rcx
    push r12
    push r13
    push r14

    mov byte [tb_dtz_payload_probe_byte], 0
    mov qword [tb_dtz_payload_probe_off], 0
    mov byte [tb_dtz_header_flags], 0
    mov qword [tb_dtz_pairs_header_off], 0
    mov dword [tb_dtz_pairs_num_blocks], 0
    mov dword [tb_dtz_pairs_num_syms], 0
    mov byte [tb_dtz_pairs_blocksize], 0
    mov byte [tb_dtz_pairs_idxbits], 0
    mov byte [tb_dtz_pairs_is_const], 0
    mov byte [tb_file_path], 0

    ; DTZ bootstrap zatial len pre male 2-3 figurkove koncovky.
    call tb_piece_count
    cmp eax, 3
    jg .not_found

    lea rbx, [board]
    xor r13d, r13d          ; white non-king piece type
    xor r14d, r14d          ; black non-king piece type
    xor ecx, ecx
.scan:
    cmp ecx, 64
    jae .scan_done
    movzx eax, byte [rbx + rcx]
    test eax, eax
    jz .next
    mov edx, eax
    and edx, PIECE_MASK
    cmp edx, KING
    je .next
    test eax, COLOR_MASK
    jz .white_piece
    test r14d, r14d
    jnz .not_found
    mov r14d, edx
    jmp .next
.white_piece:
    test r13d, r13d
    jnz .not_found
    mov r13d, edx
.next:
    inc ecx
    jmp .scan

.scan_done:
    ; Pred DTZ mapovanim si zober WDL klasifikaciu rovnakej pozicie.
    ; Vdaka tomu sa DTZ bootstrap vie riadit realnym WDL bez rozbitia
    ; DTZ map_bytes/path diagnostiky.
    call tb_probe_wdl
    mov r12d, eax

    ; Postav cestu podla materialu, potom prepni suffix na .rtbz.
    call tb_build_wdl_path
    test eax, eax
    jz .not_found

    lea rbx, [tb_file_path]

    xor rcx, rcx
.len_loop:
    cmp rcx, TB_PATH_MAX - 1
    jae .not_found
    cmp byte [rbx + rcx], 0
    je .have_len
    inc rcx
    jmp .len_loop

.have_len:
    cmp rcx, 1
    jb .not_found
    cmp byte [rbx + rcx - 1], 'w'
    je .to_rtbz
    cmp byte [rbx + rcx - 1], 'z'
    je .load
    jmp .not_found

.to_rtbz:
    mov byte [rbx + rcx - 1], 'z'

.load:
    lea rdi, [tb_file_path]
    call tb_ensure_loaded_path
    test eax, eax
    jnz .not_found

    ; Syzygy regular DTZ magic guard + payload probe byte
    mov rdi, [tb_map]
    mov rsi, [tb_map_size]
    mov edx, TB_DTZ_MAGIC
    call tb_validate_map_and_probe
    test eax, eax
    jz .not_found
    mov [tb_dtz_payload_probe_off], r8
    mov [tb_dtz_payload_probe_byte], dl

    ; metadata setup_pairs parsera pre dalsi decode krok
    mov rdi, [tb_map]
    mov rsi, [tb_map_size]
    call tb_find_pairs_probe
    test eax, eax
    jz .dtz_meta_done
    mov [tb_dtz_pairs_header_off], r8
    mov [tb_dtz_pairs_num_blocks], r10d
    mov [tb_dtz_pairs_num_syms], r11d
    mov [tb_dtz_pairs_blocksize], bl
    mov [tb_dtz_pairs_idxbits], cl
    cmp eax, 1
    jne .dtz_not_const
    mov byte [tb_dtz_pairs_is_const], 1
    jmp .dtz_meta_done
.dtz_not_const:
    mov byte [tb_dtz_pairs_is_const], 0
.dtz_meta_done:

    mov rax, [tb_map]
    mov dl, byte [rax + 4]
    mov [tb_dtz_header_flags], dl

    ; Pokus o realny .rtbz decode pre 3-piece pawnless tabulky.
    ; Ak decode zlyha, fallback je konzervativna klasifikacia podla WDL
    ; (bez threshold heuristik pre KPvK/KvPK).
    call tb_try_decode_dtz_3pc
    cmp eax, TB_NOT_FOUND
    jne .done

    cmp r12d, TB_WIN
    je .dtz_win_fallback
    cmp r12d, TB_LOSS
    je .dtz_loss_fallback
    cmp r12d, TB_DRAW
    je .dtz_draw_fallback
    jmp .not_found

.dtz_draw_fallback:
    xor eax, eax
    jmp .done

.dtz_win_fallback:
    mov eax, 1
    jmp .done

.dtz_loss_fallback:
    mov eax, 2
    jmp .done

.not_found:
    mov eax, TB_NOT_FOUND

.done:
    pop r14
    pop r13
    pop r12
    pop rcx
    pop rbx
    ret

; ============================================================
; tb_try_decode_dtz_3pc - realny decode pre 3-piece pawnless DTZ
; Vstup: r12d = WDL class (TB_LOSS/TB_DRAW/TB_WIN), r13d/r14d material
; Vystup: eax = dtz class (0 draw,1 win,2 loss) alebo TB_NOT_FOUND
; ============================================================
tb_try_decode_dtz_3pc:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r13
    push r14
    push r15

    ; scope: iba KQ/KR/KB/KN vs K (a opacne), bez pesiakov
    cmp r13d, PAWN
    je .nf
    cmp r14d, PAWN
    je .nf
    call tb_wdl_is_target_3pc_pawnless
    test eax, eax
    jz .nf

    mov r15, [tb_map]
    test r15, r15
    jz .nf
    mov rax, [tb_map_size]
    cmp rax, 16
    jb .nf
    lea r14, [r15 + rax]          ; map_end

    ; flags byte map[4]
    movzx eax, byte [r15 + 4]
    mov ebx, eax

    ; bside aproximacia ako vo WDL fallbacke: white na tahu -> bside=1
    movzx ecx, byte [side]
    mov r9d, ecx

    ; metadata byte s order nibblami
    lea rdi, [r15 + 5]
    movzx r8d, byte [rdi]

    ; skip piece metadata: num + 1 bajt
    mov ecx, 2
    test r13d, r13d
    jz .no_white_extra
    inc ecx
.no_white_extra:
    test r14d, r14d
    jz .no_black_extra
    inc ecx
.no_black_extra:
    lea rax, [rcx + 1]
    add rdi, rax
    mov rax, rdi
    sub rax, r15
    test al, 1
    jz .setup_aligned
    inc rdi
.setup_aligned:
    cmp rdi, r14
    jae .nf

    mov r13, rdi                  ; headers_start (prvy setup_pairs)

    ; split = bit0, pri bside=1 treba prejst na druhy setup stream
    mov rbx, rdi
    test ebx, 1
    jz .have_setup
    test r9d, r9d
    jz .have_setup
    mov rdi, rbx
    call tb_parse_pairs_minlen
    test eax, eax
    jz .nf
    mov rbx, r8
.have_setup:

    ; order nibble pre zvoleny bside
    mov eax, r8d
    test r9d, r9d
    jz .order_low
    shr eax, 4
.order_low:
    and eax, 0x0f
    cmp eax, 1
    ja .nf
    mov r8d, eax

    ; najdi WK/BK/extra square
    lea rdx, [board]
    mov r9d, -1                   ; wk
    mov r10d, -1                  ; bk
    test r13d, r13d
    jz .extra_black
    mov ecx, r13d
    jmp .extra_ready
.extra_black:
    mov ecx, r14d
    or ecx, BLACK
.extra_ready:
    mov r11d, -1                  ; extra
    xor eax, eax
.scan_board:
    cmp eax, 64
    jae .scan_done
    movzx edi, byte [rdx + rax]
    cmp edi, KING
    jne .chk_bk
    mov r9d, eax
    jmp .scan_next
.chk_bk:
    cmp edi, KING | BLACK
    jne .chk_extra
    mov r10d, eax
    jmp .scan_next
.chk_extra:
    cmp edi, ecx
    jne .scan_next
    mov r11d, eax
.scan_next:
    inc eax
    jmp .scan_board

.scan_done:
    cmp r9d, 0
    jl .nf
    cmp r10d, 0
    jl .nf
    cmp r11d, 0
    jl .nf

    ; idx pre setup_pairs decode
    mov edi, r9d
    mov esi, r10d
    mov edx, r11d
    mov ecx, r8d
    call tb_encode_k2_num3_idx
    test eax, eax
    jz .nf

    ; raw symbol decode
    mov rcx, rdx
    mov rdi, rbx
    mov rsi, r14
    mov rdx, 28644
    call tb_pairs_decode_symbol_idx
    test eax, eax
    jz .nf
    mov r8d, edx                   ; raw DTZ symbol

    ; map start = end vsetkych setup_pairs streamov (1 alebo 2 sloty)
    mov rdi, r13
    mov ecx, 1
    test ebx, 1
    jz .pmap_iter
    mov ecx, 2
.pmap_iter:
    call tb_parse_pairs_minlen
    test eax, eax
    jz .nf
    mov rdi, r8
    dec ecx
    jnz .pmap_iter
    mov r9, rdi
.have_pmap:

    ; mapovanie symbol->DTZ podla flags setup_pairs
    movzx eax, byte [rbx]
    mov r10d, eax
    test r10d, 2
    jz .mapped_ready

    ; WDL_TO_MAP redukcia pre nase triedy: loss->slot1, draw/win->slot0
    xor ecx, ecx
    cmp r12d, TB_LOSS
    jne .slot_ready
    mov ecx, 1
.slot_ready:

    test r10d, 16
    jnz .map_u16

    mov rdi, r9
    xor edx, edx
.map8_iter:
    cmp edx, ecx
    je .map8_target
    cmp rdi, r14
    jae .nf
    movzx eax, byte [rdi]
    lea rdi, [rdi + rax + 1]
    inc edx
    jmp .map8_iter
.map8_target:
    cmp rdi, r14
    jae .nf
    movzx eax, byte [rdi]
    lea rdi, [rdi + 1]
    cmp r8d, eax
    jae .nf
    movzx r8d, byte [rdi + r8]
    jmp .mapped_ready

.map_u16:
    mov rdi, r9
    xor edx, edx
.map16_iter:
    cmp edx, ecx
    je .map16_target
    lea rax, [rdi + 2]
    cmp rax, r14
    ja .nf
    movzx eax, word [rdi]
    lea rdi, [rdi + 2 + rax*2]
    inc edx
    jmp .map16_iter
.map16_target:
    lea rax, [rdi + 2]
    cmp rax, r14
    ja .nf
    movzx eax, word [rdi]
    cmp r8d, eax
    jae .nf
    lea rdi, [rdi + 2 + r8*2]
    lea rax, [rdi + 2]
    cmp rax, r14
    ja .nf
    movzx r8d, word [rdi]

.mapped_ready:
    ; PA_FLAGS redukcia (pre nase triedy: win=4, loss=8, draw=0)
    xor ecx, ecx
    cmp r12d, TB_WIN
    jne .pa_not_win
    mov ecx, 4
    jmp .pa_mask_ready
.pa_not_win:
    cmp r12d, TB_LOSS
    jne .pa_mask_ready
    mov ecx, 8
.pa_mask_ready:
    test r10d, ecx
    jnz .pa_done
    shl r8d, 1
.pa_done:

    ; signed DTZ priblizenie: win = +(1+res), loss = -(1+res), draw = 0
    cmp r12d, TB_DRAW
    je .signed_ready
    mov eax, r8d
    add eax, 1
    cmp r12d, TB_WIN
    je .have_signed
    neg eax
    jmp .have_signed
.signed_ready:
    xor eax, eax
.have_signed:

    call tb_dtz_to_wdl_class
    cmp eax, TB_WIN
    je .ret_win
    cmp eax, TB_LOSS
    je .ret_loss
    xor eax, eax
    jmp .done

.ret_win:
    mov eax, 1
    jmp .done

.ret_loss:
    mov eax, 2
    jmp .done

.nf:
    mov eax, TB_NOT_FOUND

.done:
    pop r15
    pop r14
    pop r13
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; tb_dtz_to_wdl_class - signed DTZ + halfmove -> WDL trieda
; Vstup: eax = signed DTZ (STM perspektiva)
; Vystup: eax = TB_WIN/TB_DRAW/TB_LOSS
; ============================================================
tb_dtz_to_wdl_class:
    test eax, eax
    jz .draw

    movzx ecx, byte [halfmove]
    test eax, eax
    jns .pos

    neg eax
    add ecx, eax
    cmp ecx, 100
    jg .draw
    mov eax, TB_LOSS
    ret

.pos:
    add ecx, eax
    cmp ecx, 100
    jg .draw
    mov eax, TB_WIN
    ret

.draw:
    mov eax, TB_DRAW
    ret

; ============================================================
; tb_piece_count - spocita neprazdne policka na sachovnici
; Vystup: eax = pocet figurok na sachovnici (0..64)
; ============================================================
