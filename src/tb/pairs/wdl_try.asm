tb_try_constant_wdl:
    push rbx
    push rcx
    push r14
    push r12
    push r15

    mov r12, [tb_map]
    test r12, r12
    jz .not_found
    mov r15, [tb_map_size]
    cmp r15, 16
    jb .not_found

    lea rsi, [r12 + r15]          ; map_end

    ; WDL hlavicka: byte[4] nesie split/files flags.
    movzx ebx, byte [r12 + 4]

    lea rdi, [r12 + 5]            ; data start po magickej hlavicke + flags

    ; Pawnless vetva (bez pesiakov): povodny decode tok, rozsireny
    ; o bezpecny non-constant idxbits==0 slice.
    cmp r13d, PAWN
    je .pawn_table
    cmp r14d, PAWN
    je .pawn_table

    cmp dword [tb_num], 4
    je .full4_decode

    call tb_wdl_is_target_3pc_pawnless
    test eax, eax
    jz .pawnless_legacy

    ; full decode pre KQ/KR/KB/KN vs K (aj opacne)
    and ebx, 1                    ; split flag

    ; metadata byte s order nibblami pre bside 0/1
    movzx r10d, byte [rdi]
    mov [tb_wdl_debug_order_byte], r10b

    ; piece-entry metadata: num + 1 bajt, potom align na parny offset
    mov ecx, 2
    test r13d, r13d
    jz .fd_no_white
    inc ecx
.fd_no_white:
    test r14d, r14d
    jz .fd_no_black
    inc ecx
.fd_no_black:
    lea rax, [rcx + 1]
    add rdi, rax
    mov rax, rdi
    sub rax, r12
    test al, 1
    jz .fd_aligned
    inc rdi
.fd_aligned:
    cmp rdi, rsi
    jae .not_found

    ; bside aproximacia pre nesymetricke tabulky
    movzx eax, byte [side]
    mov r11d, eax
    test ebx, ebx
    jnz .fd_have_bside
    xor r11d, r11d
.fd_have_bside:

    ; order nibble pre zvoleny bside (iba 0/1 pre enc_type=2,num=3)
    mov eax, r10d
    test r11d, r11d
    jz .fd_low_order
    shr eax, 4
.fd_low_order:
    and eax, 0x0f
    cmp eax, 1
    ja .not_found
    mov r10d, eax
    mov [tb_wdl_debug_order], r10d

    ; setup_pairs pointer podla bside (pre split=1)
    mov rbx, rdi
    test r11d, r11d
    jz .fd_have_setup
    mov rdi, rbx
    call tb_parse_pairs_minlen
    test eax, eax
    jz .not_found
    mov rbx, r8
.fd_have_setup:

    ; najdi WK/BK/extra square
    lea rdx, [board]
    mov r8d, -1                   ; wk
    mov r9d, -1                   ; bk
    mov eax, r13d
    test eax, eax
    jz .fd_extra_black
    mov ecx, r13d
    jmp .fd_extra_code_ready
.fd_extra_black:
    mov ecx, r14d
    or ecx, BLACK
.fd_extra_code_ready:
    mov r11d, -1                  ; extra
    xor eax, eax
.fd_scan:
    cmp eax, 64
    jae .fd_scan_done
    movzx edi, byte [rdx + rax]
    cmp edi, KING
    jne .fd_not_wk
    mov r8d, eax
    jmp .fd_next
.fd_not_wk:
    cmp edi, KING | BLACK
    jne .fd_not_bk
    mov r9d, eax
    jmp .fd_next
.fd_not_bk:
    cmp edi, ecx
    jne .fd_next
    mov r11d, eax
.fd_next:
    inc eax
    jmp .fd_scan

.fd_scan_done:
    mov [tb_wdl_debug_wk], r8d
    mov [tb_wdl_debug_bk], r9d
    mov [tb_wdl_debug_extra], r11d

    cmp r8d, 0
    jl .not_found
    cmp r9d, 0
    jl .not_found
    cmp r11d, 0
    jl .not_found

    mov edi, r8d
    mov esi, r9d
    mov edx, r11d
    mov ecx, r10d
    call tb_encode_k2_num3_idx
    test eax, eax
    jz .not_found
    mov [tb_wdl_debug_idx], rdx

    ; tb_size pre enc_type=2,num=3: 462 * 62 = 28644
    mov rcx, rdx                  ; idx
    mov rdi, rbx                  ; setup_pairs ptr
    lea rsi, [r12 + r15]          ; map_end (rsi mohol byt clobbered encode helperom)
    mov rdx, 28644
    call tb_pairs_decode_symbol_idx
    test eax, eax
    jz .not_found
    mov r10d, edx
    jmp .raw_to_class

%include "tb/pairs/wdl_full4_decode.asm"

.pawnless_legacy:

    and ebx, 1                    ; split flag

    ; piece-entry metadata pre pawnless vetvu: num + 1 bajt, potom align na parny offset
    mov ecx, 2                    ; obe kralovske figurky
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
    sub rax, r12
    test al, 1
    jz .aligned
    inc rdi
.aligned:
    cmp rdi, rsi
    jae .not_found

    ; precomp[0]
    mov rbx, rdi
    call tb_parse_pairs_minlen
    test eax, eax
    jz .not_found
    cmp eax, 1
    je .pc0_const
    movzx eax, byte [rbx + 2]      ; idxbits
    test eax, eax
    jz .pc0_minlen
    mov rdi, r10
    mov esi, r9d
    call tb_pairs_uniform_root
    test eax, eax
    jz .not_found
    movzx r10d, dl
    jmp .pc0_ok
.pc0_const:
.pc0_minlen:
    mov r10d, edx                 ; raw0
.pc0_ok:

    test ebx, ebx
    jz .choose_done_single

    ; split: precomp[1]
    mov rdi, r8
    mov rbx, rdi
    call tb_parse_pairs_minlen
    test eax, eax
    jz .not_found
    cmp eax, 1
    je .pc1_const
    movzx eax, byte [rbx + 2]      ; idxbits
    test eax, eax
    jz .pc1_minlen
    mov rdi, r10
    mov esi, r9d
    call tb_pairs_uniform_root
    test eax, eax
    jz .not_found
    movzx r11d, dl
    jmp .pc1_ok
.pc1_const:
.pc1_minlen:
    mov r11d, edx                 ; raw1
.pc1_ok:

    cmp r10d, r11d
    je .choose_min0

    ; Konzervativny guard: ak sa split precomp vetvy rozidu a jedna vetva
    ; vracia draw (raw=2), preferuj draw. Toto znizuje falesne LOSS triedy
    ; v hraničných asymetrických 3-piece poziciach.
    cmp r10d, 2
    je .choose_min0
    cmp r11d, 2
    jne .choose_bside
    mov r10d, r11d
    jmp .choose_min0

.choose_bside:

    ; Aproximacia bside vyberu pre asymetricke materialy:
    ; pri key match vetve v syzygy probe je bside = !wtm.
    movzx eax, byte [side]
    test eax, eax
    jz .choose_min1               ; white na tahu -> bside=1 -> precomp[1]
    jmp .choose_min0              ; black na tahu -> bside=0 -> precomp[0]

.choose_min1:
    mov r10d, r11d

.choose_min0:

.choose_done_single:
    jmp .raw_to_class

.pawn_table:
    jmp .not_found
    mov byte [tb_wdl_pairs_is_const], 4
    ; 3-piece pawn scope: KPvK/KvPK. Vyberieme setup_pairs slot
    ; rovnako ako probe.c (file bucket + bside), ale realny variable-bit
    ; decode (idxbits>0) zatial neriesime v tomto kroku.
    movzx eax, byte [r12 + 4]
    mov r11d, eax                 ; flags
    and eax, 0x02
    jz .not_found                 ; bez files flagu nie je nas current scope

    ; files=4, split=bit0
    mov eax, r11d
    and eax, 1
    mov r8d, eax                  ; split flag

    ; metadata pre pawn tabulky: files * (num + s)
    ; current scope: num=3, s=1 (jedna strana ma presne jedneho pesiaka)
    add rdi, 16
    mov rax, rdi
    sub rax, r12
    test al, 1
    jz .pawn_aligned
    inc rdi
.pawn_aligned:
    cmp rdi, rsi
    jae .not_found
    mov [tb_dec_headers_start_tmp], rdi

    ; urci cmirror/mirror/bside podla key-match vetvy (probe.c)
    lea rbx, [board]
    xor r10, r10                   ; board key
    xor eax, eax
.pawn_key_board_scan:
    cmp eax, 64
    jae .pawn_key_board_done
    movzx edx, byte [rbx + rax]
    test edx, edx
    jz .pawn_key_board_next
    lea rsi, [tb_piece_key]
    add r10, [rsi + rdx*8]
.pawn_key_board_next:
    inc eax
    jmp .pawn_key_board_scan

.pawn_key_board_done:
    lea rsi, [tb_piece_key]
    xor r11, r11                   ; ptr key (file[0].pieces[0])
    movzx eax, byte [r12 + 6]
    and eax, 0x0f
    add r11, [rsi + rax*8]
    movzx eax, byte [r12 + 7]
    and eax, 0x0f
    add r11, [rsi + rax*8]
    movzx eax, byte [r12 + 8]
    and eax, 0x0f
    add r11, [rsi + rax*8]

    mov byte [tb_dec_cmirror_tmp], 0
    mov byte [tb_dec_mirror_tmp], 0
    movzx edx, byte [side]         ; key-match vetva: bside=!wtm (wtm = !side)
    cmp r10, r11
    je .pawn_side_ready
    mov byte [tb_dec_cmirror_tmp], 8
    mov byte [tb_dec_mirror_tmp], 56
    movzx edx, byte [side]         ; key-mismatch vetva: bside=wtm = !side
    xor edx, 1
.pawn_side_ready:
    mov [tb_dec_bside_tmp], dl
    mov r11d, edx                  ; bside 0/1

    ; najdi square pesiaka podla pieces[0] a cmirror, potom aplikuj mirror
    movzx eax, byte [r12 + 6]      ; file[0].pieces[0][0], low nibble
    and eax, 0x0f
    movzx edx, byte [tb_dec_cmirror_tmp]
    xor eax, edx
    mov r9d, -1
    xor edx, edx
.pawn_sq_scan:
    cmp edx, 64
    jae .pawn_sq_done
    movzx ecx, byte [rbx + rdx]
    cmp ecx, eax
    jne .pawn_sq_next
    mov ecx, edx
    movzx esi, byte [tb_dec_mirror_tmp]
    xor ecx, esi
    mov r9d, ecx
    jmp .pawn_sq_done
.pawn_sq_next:
    inc edx
    jmp .pawn_sq_scan

.pawn_sq_done:
    cmp r9d, 0
    jl .not_found
    mov eax, r9d
    and eax, 7
    cmp eax, 3
    jle .file_ok
    mov edx, 7
    sub edx, eax
    mov eax, edx
.file_ok:
    mov r10d, eax                 ; file bucket 0..3
    mov r14d, eax                 ; uloz file bucket
    mov [tb_dec_file_tmp], al     ; file bucket pre neskorsie pieces[] mapovanie

    ; target precomp index v poradi setup_pairs streamu
    ; order: file0[pre0,pre1], file1[pre0,pre1], ... (ak split)
    mov eax, r10d
    shl eax, 1
    test r8d, r8d
    jnz .idx_add_bside
    shr eax, 1
    xor r11d, r11d                ; pri non-split sa pouzije precomp[0]
.idx_add_bside:
    add eax, r11d
    mov [tb_dec_target_tmp], eax  ; target index

    ; order nibble pre dany file bucket + bside (0..2)
    lea rax, [r12 + 5]
    lea rax, [rax + r14*4]
    movzx edx, byte [rax]
    test r11d, r11d
    jz .pawn_order_low
    shr edx, 4
.pawn_order_low:
    and edx, 0x0f
    cmp edx, 2
    ja .not_found
    mov r14d, edx                 ; order 0..2

    ; pocet precomp slotov
    mov eax, 4
    test r8d, r8d
    jz .have_slots
    shl eax, 1
.have_slots:
    mov r11d, eax                 ; slot_count
    mov [tb_dec_slot_count_tmp], r11d

    xor ecx, ecx                  ; current index
.pawn_parse_loop:
    cmp ecx, r11d
    jae .not_found

    lea rsi, [r12 + r15]          ; map_end pre tb_parse_pairs_minlen
    mov rbx, rdi
    push rcx
    call tb_parse_pairs_minlen
    mov edx, eax
    pop rcx
    test edx, edx
    jnz .pawn_parse_ok
    mov byte [tb_wdl_pairs_is_const], 7
    jmp .not_found
.pawn_parse_ok:

    cmp ecx, [tb_dec_target_tmp]
    jne .pawn_next

    ; priprav realne indextable/sizetable/data pointery pre target slot
    mov rdi, [tb_dec_headers_start_tmp]
    lea rsi, [r12 + r15]
    mov edx, [tb_dec_slot_count_tmp]
    mov ecx, [tb_dec_target_tmp]
    mov r8, 23436
    call tb_pairs_prepare_pawn_override
    test eax, eax
    jz .not_found

    mov byte [tb_wdl_pairs_is_const], 5

    ; Poradie kralov musi ist podla pieces[] nibblov pre dany file+bside.
    ; data chunk na file ma 4 bajty: [order][p0][p1][p2].
    movzx edx, byte [tb_dec_file_tmp]
    lea rax, [r12 + 5]
    lea rax, [rax + rdx*4]
    lea rax, [rax + 2]            ; p1
    movzx edx, byte [rax]
    movzx ecx, byte [rax + 1]     ; p2
    movzx eax, byte [tb_dec_bside_tmp]
    test eax, eax
    jz .pawn_piece_nibbles_ready
    shr edx, 4
    shr ecx, 4
.pawn_piece_nibbles_ready:
    and edx, 0x0f
    and ecx, 0x0f

    ; p1/p2 -> realne board codes cez cmirror; sq -> pos cez mirror
    movzx eax, byte [tb_dec_cmirror_tmp]
    xor edx, eax
    xor ecx, eax
    mov r11d, edx                 ; expected code pieces[1]
    mov esi, ecx                  ; expected code pieces[2]

    lea rax, [board]
    mov r8d, -1                   ; pos1
    mov r10d, -1                  ; pos2
    xor edx, edx
.pawn_find_kings:
    cmp edx, 64
    jae .pawn_kings_done
    movzx ecx, byte [rax + rdx]
    cmp ecx, r11d
    jne .pawn_chk_k2
    mov ecx, edx
    movzx edi, byte [tb_dec_mirror_tmp]
    xor ecx, edi
    mov r8d, ecx
    jmp .pawn_kings_next
.pawn_chk_k2:
    cmp ecx, esi
    jne .pawn_kings_next
    mov ecx, edx
    movzx edi, byte [tb_dec_mirror_tmp]
    xor ecx, edi
    mov r10d, ecx
.pawn_kings_next:
    inc edx
    jmp .pawn_find_kings

.pawn_kings_done:
    cmp r8d, 0
    jl .not_found
    cmp r10d, 0
    jl .not_found
    mov esi, r8d
    mov edx, r10d

    mov edi, r9d                  ; pawn sq
    mov ecx, r14d                 ; order nibble 0..2
    call tb_encode_pawn1_num3_idx
    test eax, eax
    jz .not_found

    mov [tb_wdl_pairs_num_syms], edx
    mov eax, [tb_dec_target_tmp]
    mov [tb_wdl_pairs_num_blocks], eax

    mov rcx, rdx
    mov rdi, rbx
    lea rsi, [r12 + r15]          ; map_end (rsi mohol byt clobbered encode helperom)
    mov rdx, 23436
    call tb_pairs_decode_symbol_idx
    test eax, eax
    jnz .pawn_decode_ok
    mov [tb_wdl_pairs_blocksize], dl
    mov byte [tb_wdl_pairs_is_const], 9
    jmp .not_found
.pawn_decode_ok:
    mov byte [tb_wdl_pairs_is_const], 6
    mov r10d, edx
    jmp .raw_to_class

.pawn_next:
    mov rdi, r8
    inc ecx
    jmp .pawn_parse_loop

.raw_to_class:
    ; raw syzygy symbol -> WDL trieda: raw-2  {-2..2}
    cmp r10d, 4
    ja .not_found
    mov eax, r10d
    sub eax, 2
    cmp eax, 0
    jg .win
    jl .loss
    mov eax, TB_DRAW
    jmp .done

.win:
    mov eax, TB_WIN
    jmp .done

.loss:
    mov eax, TB_LOSS
    jmp .done

.not_found:
.nf_regular:
    cmp byte [tb_wdl_pairs_is_const], 4
    jne .nf_keep
    mov byte [tb_wdl_pairs_is_const], 8
.nf_keep:
    mov eax, TB_NOT_FOUND

.done:
    pop r15
    pop r12
    pop r14
    pop rcx
    pop rbx
    ret
