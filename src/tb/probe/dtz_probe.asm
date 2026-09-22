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

    ; DTZ bootstrap vratime podla WDL vysledku rovnakej pozicie,
    ; aby sa male koncovky (najma KPvK/KvPK draw) neklasifikovali chybne.
    cmp r12d, TB_WIN
    je .dtz_win
    cmp r12d, TB_LOSS
    je .dtz_loss
    cmp r12d, TB_DRAW
    je .dtz_draw

    ; Kym nebude plny decode .rtbz, vrat konzervativnu klasifikaciu.
    test r13d, r13d
    jnz .white_has_piece
    test r14d, r14d
    jnz .black_has_piece
    jmp .dtz_draw

.white_has_piece:
    test r14d, r14d
    jnz .not_found
    cmp r13d, BISHOP
    je .dtz_draw
    cmp r13d, KNIGHT
    je .dtz_draw
    cmp r13d, PAWN
    je .dtz_pawn_vs_king
    movzx eax, byte [side]
    test eax, eax
    jz .dtz_win
    jmp .dtz_loss

.black_has_piece:
    test r13d, r13d
    jnz .not_found
    cmp r14d, BISHOP
    je .dtz_draw
    cmp r14d, KNIGHT
    je .dtz_draw
    cmp r14d, PAWN
    je .dtz_king_vs_pawn
    movzx eax, byte [side]
    test eax, eax
    jz .dtz_loss
    jmp .dtz_win

.dtz_pawn_vs_king:
    ; KPvK fallback pre DTZ klasifikaciu.
    lea rbx, [board]
    mov r8d, -1              ; white pawn sq
    mov r9d, -1              ; black king sq
    xor ecx, ecx
.dtz_kpvk_scan:
    cmp ecx, 64
    jae .dtz_kpvk_have
    movzx eax, byte [rbx + rcx]
    test eax, eax
    jz .dtz_kpvk_next
    mov edx, eax
    and edx, PIECE_MASK
    cmp edx, PAWN
    jne .dtz_kpvk_try_king
    test eax, COLOR_MASK
    jnz .dtz_kpvk_next
    mov r8d, ecx
    jmp .dtz_kpvk_next
.dtz_kpvk_try_king:
    cmp edx, KING
    jne .dtz_kpvk_next
    test eax, COLOR_MASK
    jz .dtz_kpvk_next
    mov r9d, ecx
.dtz_kpvk_next:
    inc ecx
    jmp .dtz_kpvk_scan

.dtz_kpvk_have:
    cmp r8d, 0
    jl .dtz_draw
    cmp r9d, 0
    jl .dtz_draw

    mov eax, r8d
    and eax, 7
    mov r10d, eax            ; pawn file
    mov eax, r8d
    shr eax, 3
    mov r11d, eax            ; pawn rank

    mov eax, r9d
    and eax, 7
    mov r12d, eax            ; king file
    mov eax, r9d
    shr eax, 3
    mov r13d, eax            ; king rank

    cmp r12d, r10d
    jne .dtz_kpvk_steps
    cmp r13d, r11d
    jle .dtz_kpvk_steps
    jmp .dtz_draw

.dtz_kpvk_steps:
    mov eax, 7
    sub eax, r11d
    mov r14d, eax

    mov eax, r12d
    sub eax, r10d
    jns .dtz_kpvk_abs_file
    neg eax
.dtz_kpvk_abs_file:
    mov edx, eax
    mov eax, r13d
    sub eax, 7
    jns .dtz_kpvk_abs_rank
    neg eax
.dtz_kpvk_abs_rank:
    cmp edx, eax
    jge .dtz_kpvk_have_dist
    mov edx, eax
.dtz_kpvk_have_dist:

    movzx eax, byte [side]
    test eax, eax
    jnz .dtz_kpvk_no_tempo
    dec r14d
.dtz_kpvk_no_tempo:
    cmp r14d, 0
    jl .dtz_win
    cmp edx, r14d
    jle .dtz_draw
    jmp .dtz_win

.dtz_king_vs_pawn:
    ; KvPK fallback pre DTZ klasifikaciu.
    lea rbx, [board]
    mov r8d, -1              ; black pawn sq
    mov r9d, -1              ; white king sq
    xor ecx, ecx
.dtz_kvpk_scan:
    cmp ecx, 64
    jae .dtz_kvpk_have
    movzx eax, byte [rbx + rcx]
    test eax, eax
    jz .dtz_kvpk_next
    mov edx, eax
    and edx, PIECE_MASK
    cmp edx, PAWN
    jne .dtz_kvpk_try_king
    test eax, COLOR_MASK
    jz .dtz_kvpk_next
    mov r8d, ecx
    jmp .dtz_kvpk_next
.dtz_kvpk_try_king:
    cmp edx, KING
    jne .dtz_kvpk_next
    test eax, COLOR_MASK
    jnz .dtz_kvpk_next
    mov r9d, ecx
.dtz_kvpk_next:
    inc ecx
    jmp .dtz_kvpk_scan

.dtz_kvpk_have:
    cmp r8d, 0
    jl .dtz_draw
    cmp r9d, 0
    jl .dtz_draw

    mov eax, r8d
    and eax, 7
    mov r10d, eax            ; pawn file
    mov eax, r8d
    shr eax, 3
    mov r11d, eax            ; pawn rank

    mov eax, r9d
    and eax, 7
    mov r12d, eax            ; king file
    mov eax, r9d
    shr eax, 3
    mov r13d, eax            ; king rank

    cmp r12d, r10d
    jne .dtz_kvpk_steps
    cmp r13d, r11d
    jge .dtz_kvpk_steps
    jmp .dtz_draw

.dtz_kvpk_steps:
    mov eax, r11d
    mov r14d, eax

    mov eax, r12d
    sub eax, r10d
    jns .dtz_kvpk_abs_file
    neg eax
.dtz_kvpk_abs_file:
    mov edx, eax
    mov eax, r13d
    cmp edx, eax
    jge .dtz_kvpk_have_dist
    mov edx, eax
.dtz_kvpk_have_dist:

    movzx eax, byte [side]
    test eax, eax
    jz .dtz_kvpk_no_tempo
    dec r14d
.dtz_kvpk_no_tempo:
    cmp r14d, 0
    jl .dtz_loss
    cmp edx, r14d
    jle .dtz_draw
    jmp .dtz_loss

.dtz_draw:
    xor eax, eax
    jmp .done

.dtz_win:
    mov eax, 1
    jmp .done

.dtz_loss:
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
; tb_piece_count - spocita neprazdne policka na sachovnici
; Vystup: eax = pocet figurok na sachovnici (0..64)
; ============================================================
