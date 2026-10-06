make_move:
    inc qword [prof_makes]
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r15, rax            ; uloz cely tah

    ; vypocitaj adresu undo zaznamu
    lea r14, [undo_stack]
    mov r13, [undo_sp]
    cmp r13, 64*16
    jb .undo_space_ok
    ; fail-fast: ochrana proti prepisu pamate za undo_stack
    mov rax, SYS_EXIT
    mov rdi, 70
    syscall
.undo_space_ok:
    lea r12, [r14 + r13]

    ; uloz from, to, flags
    movzx rax, r15w
    and rax, 0x3F
    mov [r12 + 0], al       ; from
    movzx rax, r15w
    shr rax, 6
    and rax, 0x3F
    mov [r12 + 1], al       ; to
    movzx rax, r15w
    shr rax, 12
    mov [r12 + 2], al       ; flags

    ; uloz staru poziciu
    mov al, [side]
    mov [r12 + 5], al
    mov al, [castle]
    mov [r12 + 6], al
    mov al, [enpassant]
    mov [r12 + 7], al
    mov al, [halfmove]
    mov [r12 + 8], al
    mov ax, [fullmove]
    mov [r12 + 9], ax

    mov rax, r15
    call apply_move

    mov al, [moved_piece]
    mov [r12 + 3], al
    mov al, [captured_piece]
    mov [r12 + 4], al

    ; E10/F2: NNUE acc delta (+ undo +11..15); MUSI byt pred akymkolvek
    ; zasahom do position_hash (kontroluje acc_hash == position_hash)
    mov rax, r15
    mov rdi, r12
    call nnue2_move_delta
    mov [nnue_delta_applied], al

    ; E10/F2: hash delta — XOR out stare stavove kluce (side/castle/EP sa
    ; zmeni az v update_position_state)
    call hash_delta_state
    mov rax, r15
    call hash_delta_pieces

    mov rax, r15
    call update_position_state

    ; E10/F2: hash delta — XOR in nove stavove kluce; plny compute_hash
    ; netreba. acc_hash synchronizujeme LEN ak sa NNUE delta aplikovala
    ; (inak acc zostava nepplatny a eval spravi refresh).
    call hash_delta_state
    cmp byte [nnue_delta_applied], 0
    je .acc_sync_done            ; delta sa NEaplikovala -> acc nepplatny
    mov rax, [position_hash]
    mov [nnue_acc_hash], rax
.acc_sync_done:

    ; move_stack[ply] = tah (countermove heuristic; null ply nuluje negamax)
    mov rcx, [search_ply]
    cmp rcx, 64
    jae .skip_move_stack
    lea rdx, [move_stack]
    mov [rdx + rcx*2], r15w
.skip_move_stack:

    add r13, 16
    mov [undo_sp], r13

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; unmake_move - obnovi poziciu z undo_stack
; ============================================================
unmake_move:
    inc qword [prof_unmakes]
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rax                ; zachovaj vysledok pre volajuceho (telo ho prepise)

    ; posun sa na posledny undo zaznam
    mov r13, [undo_sp]
    cmp r13, 16
    jae .undo_has_entry
    ; fail-fast: underflow undo zasobnika
    mov rax, SYS_EXIT
    mov rdi, 71
    syscall
.undo_has_entry:
    sub r13, 16
    mov [undo_sp], r13
    lea r14, [undo_stack]
    lea r12, [r14 + r13]

    ; najprv nacitaj flags a stav (este mame platny base v r12)
    movzx r8, byte [r12 + 2]    ; flags
    movzx r9, byte [r12 + 5]    ; side
    movzx r10, byte [r12 + 6]   ; castle
    movzx r11, byte [r12 + 7]   ; enpassant
    movzx rbx, byte [r12 + 8]   ; halfmove
    movzx rax, word [r12 + 9]   ; fullmove

    ; nacitaj tahove informacie
    movzx r15, byte [r12 + 3]   ; moved_piece
    movzx r14, byte [r12 + 4]   ; captured_piece

    mov [moved_piece], r15b
    mov [captured_piece], r14b

    ; zrekonstruuj tah (from/to/flags) do r14 — len rcx/r13, rax (fullmove)
    ; sa nesmie prepisat (captured_piece je globalne aj v undo +4)
    movzx r13, byte [r12 + 0]   ; from
    movzx ecx, byte [r12 + 1]   ; to (base v r12 este pouzitelny)
    shl ecx, 6
    mov r14d, r13d
    or r14d, ecx
    mov ecx, r8d
    shl ecx, 12
    or r14d, ecx                ; tah

    ; E10/F2: inverzny NNUE acc delta — MUSI byt pred hash zmenami
    ; (position_hash je este post-move == acc_hash); rdi = undo base.
    ; delta funkcie clobruju r8-r11 -> push okolo (r8=flags, r9-r11=stav).
    mov rdi, r12
    push r8
    push r9
    push r10
    push r11
    push rax                     ; zarovnanie (11 pushov -> 16B)
    mov eax, r14d
    call nnue2_move_delta_inv
    mov [nnue_delta_applied], al
    mov eax, r14d
    call hash_delta_pieces      ; XOR figurkovych klucov (samoinverzne)
    pop rax
    pop r11
    pop r10
    pop r9
    pop r8

    movzx r14, byte [r12 + 4]   ; captured_piece (znova)
    movzx r12d, byte [r12 + 1]  ; to (prepise base)

    ; E10/F2: hash delta — XOR out post-move stavove kluce
    ; POZOR: hash_delta_state clobruje rax (ep vetva necha v eax 255 alebo
    ; ep stlpec) — ax drzi ulozeny fullmove pre restore nizsie, chranit!
    push r8
    push rax
    call hash_delta_state
    pop rax
    pop r8

    ; uloz stav spat do pamate
    mov [side], r9b
    mov [castle], r10b
    mov [enpassant], r11b
    mov [halfmove], bl
    mov [fullmove], ax

    ; inverzna delta eval cache (ax = zrekonstruovany tah z undo zaznamu;
    ; revert sa musi urobit tu, lebo .undo_ep/.undo_castle menia r12)
    mov eax, r13d               ; from
    mov edx, r12d               ; to
    shl edx, 6
    or eax, edx
    mov edx, r8d                ; flags
    shl edx, 12
    or eax, edx

    ; obnov sachovnicu
    lea rsi, [board]
    mov [rsi + r13], r15b       ; board[from] = moved_piece

    cmp r8, FLAG_ENPASSANT
    je .undo_ep
    cmp r8, FLAG_CASTLE
    je .undo_castle

    ; normalny tah / promocia
    mov [rsi + r12], r14b
    jmp .done

.undo_ep:
    mov byte [rsi + r12], EMPTY
    movzx rax, byte [side]
    test rax, rax
    jz .white_ep
    add r12, 8                  ; cierny bral pesiaca na to + 8
    jmp .do_ep
.white_ep:
    sub r12, 8                  ; biely bral pesiaca na to - 8
.do_ep:
    mov [rsi + r12], r14b
    jmp .done

.undo_castle:
    mov byte [rsi + r12], EMPTY
    cmp r12, 6
    je .castle_wk
    cmp r12, 2
    je .castle_wq
    cmp r12, 62
    je .castle_bk
    cmp r12, 58
    je .castle_bq
    jmp .done

.castle_wk:
    mov byte [rsi + 7], ROOK|WHITE
    mov byte [rsi + 5], EMPTY
    jmp .done
.castle_wq:
    mov byte [rsi + 0], ROOK|WHITE
    mov byte [rsi + 3], EMPTY
    jmp .done
.castle_bk:
    mov byte [rsi + 63], ROOK|BLACK
    mov byte [rsi + 61], EMPTY
    jmp .done
.castle_bq:
    mov byte [rsi + 56], ROOK|BLACK
    mov byte [rsi + 59], EMPTY

.done:
    ; E10/F3 invariant: bb stav konzistentny s obnovenym board[64] cez
    ; inkrementalnu xor delta (samoinverzna, side uz je mover).
    ; from/to/flags/moved/captured citame z undo zaznamu (registre
    ; r12-r15 boli na tejto ceste prepisane).
    lea rcx, [undo_stack]
    add rcx, [undo_sp]          ; undo_sp uz ukazuje na platny zaznam
    movzx eax, byte [rcx + 0]   ; from
    movzx edx, byte [rcx + 1]   ; to
    shl edx, 6
    or eax, edx
    movzx edx, byte [rcx + 2]   ; flags
    shl edx, 12
    or eax, edx                 ; 16-bitovy tah
    movzx esi, byte [rcx + 3]   ; moved_piece
    movzx edi, byte [rcx + 4]   ; captured_piece
    call pos_bb_move_delta
    ; E10/F2: hash delta — XOR in obnovene (stare) stavove kluce; plny
    ; compute_hash netreba. acc_hash synchronizujeme len ak sa inverzna
    ; NNUE delta aplikovala (inak acc zostava nepplatny -> refresh v eval).
    push rax
    call hash_delta_state
    cmp byte [nnue_delta_applied], 0
    je .acc_sync_done            ; delta sa NEaplikovala -> acc nepplatny
    mov rax, [position_hash]
    mov [nnue_acc_hash], rax
.acc_sync_done:
    pop rax                     ; sparovanie s push rax pred state delta
    pop rax                     ; entry: povodna hodnota pre volajuceho

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; quiescence - alpha-beta na tactical tahoch (capture/promo/ep)
; Vstup:  rdi = q-hlbka, rsi = alpha, rdx = beta
; Vystup: eax = skore
; ============================================================
