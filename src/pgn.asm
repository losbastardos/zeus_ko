; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; pgn.asm - export partii do PGN (SAN) v realnom case
;
; Súbor games.pgn sa otvára lazy pri prvom tahu partie
; (O_WRONLY|O_CREAT|O_APPEND), hlavičky sa zapíšu raz,
; každý tah sa do súboru okamžite appenduje (real-time).
; 'new' uzavrie aktuálnu partiu (výsledok + prazdny riadok)
; a ďalšia partia pokračuje za ňou (PGN databaza).
; ============================================================

%include "chess.inc"

DEFAULT REL

extern board, side, fullmove, engine_side
extern move_list, move_count, move_history_len
extern piece_chars
extern is_in_check, generate_all_moves, square_to_str, square_str_buf

global pgn_san_begin, pgn_write_move, pgn_new_game, pgn_quit, pgn_result

section .data

pgn_fd:         dq -1               ; -1 = zatvorene/zlyhalo
pgn_filename:   db "games.pgn", 0
pgn_nl:         db 10
pgn_res_star:   db "*"
pgn_res_10:     db "1-0"
pgn_res_01:     db "0-1"
pgn_res_draw:   db "1/2-1/2"
pgn_promo_chars: db "QRBN"

pgn_hdr_a:      db '[Event "Local game"]', 10, '[Site "?"]', 10, '[Date "'
pgn_hdr_a_len   equ $-pgn_hdr_a
pgn_hdr_b:      db '"]', 10, '[Round "-"]', 10
pgn_hdr_b_len   equ $-pgn_hdr_b
pgn_hdr_players: db '[White "Player"]', 10, '[Black "Player"]', 10
pgn_hdr_players_len equ $-pgn_hdr_players
pgn_hdr_eng_white: db '[White "Engine"]', 10, '[Black "Player"]', 10
pgn_hdr_eng_white_len equ $-pgn_hdr_eng_white
pgn_hdr_eng_black: db '[White "Player"]', 10, '[Black "Engine"]', 10
pgn_hdr_eng_black_len equ $-pgn_hdr_eng_black
pgn_hdr_eng_both: db '[White "Engine"]', 10, '[Black "Engine"]', 10
pgn_hdr_eng_both_len equ $-pgn_hdr_eng_both
pgn_hdr_c:      db '[Result "*"]', 10, 10
pgn_hdr_c_len   equ $-pgn_hdr_c

section .bss

pgn_result:         resb 1          ; 0 = *, 1 = 1-0, 2 = 0-1, 3 = 1/2-1/2
pgn_game_open:      resb 1          ; partia ma otvorenu hlavicku v subore
pgn_mover_side:     resb 1          ; strana, ktora prave tahala (0 = biely)
pgn_move_no:        resw 1          ; cislo tahu partie
pgn_san_buf:        resb 16         ; SAN jadro (bez +/#)
pgn_san_len:        resq 1
pgn_line:           resb 8192       ; buffer movetextu (celá partia na 1 riadku)
pgn_line_len:       resq 1
pgn_date_buf:       resb 11         ; "YYYY.MM.DD", 0
pgn_dec_tmp:        resb 8

section .text

; ------------------------------------------------------------
; pgn_san_begin - zostavi SAN jadro tahu (bez +/#)
; Vstup: ax = tah (legalny; move_list obsahuje legálne tahy
;        aktuálnej pozície - volať PRED apply_move)
; Zachová všetky registre.
; ------------------------------------------------------------
pgn_san_begin:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    movzx r12d, ax              ; r12 = tah
    movzx eax, byte [side]
    mov [pgn_mover_side], al    ; strana, ktorá tahala
    mov ax, [fullmove]
    mov [pgn_move_no], ax       ; číslo ťahu (fullmove ešte neinkrementované)

    lea rdi, [pgn_san_buf]      ; rdi = cursor do SAN bufferu

    ; rosada?
    mov eax, r12d
    shr eax, 12
    and eax, 0xF
    cmp eax, FLAG_CASTLE
    jne .not_castle
    mov eax, r12d
    shr eax, 6
    and eax, 0x3F
    cmp eax, 2                  ; c1
    je .castle_ooo
    cmp eax, 58                 ; c8
    je .castle_ooo
    mov byte [rdi], 'O'
    mov byte [rdi+1], '-'
    mov byte [rdi+2], 'O'
    add rdi, 3
    jmp .finish
.castle_ooo:
    mov byte [rdi], 'O'
    mov byte [rdi+1], '-'
    mov byte [rdi+2], 'O'
    mov byte [rdi+3], '-'
    mov byte [rdi+4], 'O'
    add rdi, 5
    jmp .finish

.not_castle:
    mov r8d, r12d
    and r8d, 0x3F               ; r8 = from
    mov r9d, r12d
    shr r9d, 6
    and r9d, 0x3F               ; r9 = to
    lea rbx, [board]
    movzx r10d, byte [rbx + r8] ; r10 = figúrka (s farbou)
    mov r11d, r10d
    and r11d, PIECE_MASK        ; r11 = typ

    cmp r11d, PAWN
    je .pawn

    ; --- figúra: písmeno ---
    lea rbx, [piece_chars]
    mov eax, r11d
    mov al, [rbx + rax]
    mov [rdi], al
    inc rdi

    ; --- disambiguácia: scan legálnych ťahov ---
    ; r13b: bit0 = našiel inú figúru rovn. typu na rovn. cieľ,
    ;       bit1 = iná figúra v rovnakom súbore, bit2 = rovnaký rank
    xor r13d, r13d
    movzx r15d, word [move_count]
    lea rbx, [move_list]
    xor r14d, r14d
.dis_loop:
    cmp r14d, r15d
    jae .dis_done
    movzx eax, word [rbx + r14*2]
    mov ecx, eax
    and ecx, 0xFFF
    mov edx, r12d
    and edx, 0xFFF
    cmp ecx, edx
    je .dis_next                ; ten istý ťah (from/to)
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3F
    cmp ecx, r9d
    jne .dis_next               ; iný cieľ
    and eax, 0x3F               ; from2
    lea rsi, [board]
    movzx edx, byte [rsi + rax]
    mov ecx, edx
    and ecx, PIECE_MASK
    cmp ecx, r11d
    jne .dis_next               ; iný typ figúry
    and edx, COLOR_MASK
    mov ecx, r10d
    and ecx, COLOR_MASK
    cmp edx, ecx
    jne .dis_next               ; iná farba
    or r13d, 1                  ; ambiguózny ťah existuje
    mov ecx, eax
    and ecx, 7
    mov edx, r8d
    and edx, 7
    cmp ecx, edx
    jne .dis_sf_ok
    or r13d, 2                  ; iná figúra v rovnakom súbore
.dis_sf_ok:
    mov ecx, eax
    shr ecx, 3
    mov edx, r8d
    shr edx, 3
    cmp ecx, edx
    jne .dis_next
    or r13d, 4                  ; iná figúra v rovnakom rade
.dis_next:
    inc r14d
    jmp .dis_loop
.dis_done:
    test r13d, 1
    jz .no_dis
    test r13d, 2
    jnz .dis_try_rank
    mov eax, r8d                ; postačuje súbor
    and eax, 7
    add eax, 'a'
    mov [rdi], al
    inc rdi
    jmp .dis_out
.dis_try_rank:
    test r13d, 4
    jnz .dis_both
    mov eax, r8d                ; postačuje rank
    shr eax, 3
    add eax, '1'
    mov [rdi], al
    inc rdi
    jmp .dis_out
.dis_both:
    mov eax, r8d                ; súbor aj rank
    and eax, 7
    add eax, 'a'
    mov [rdi], al
    inc rdi
    mov eax, r8d
    shr eax, 3
    add eax, '1'
    mov [rdi], al
    inc rdi
.dis_out:
.no_dis:
    ; --- branie? ---
    lea rsi, [board]
    movzx eax, byte [rsi + r9]
    test eax, eax
    jnz .piece_cap
    mov eax, r12d
    shr eax, 12
    and eax, 0xF
    cmp eax, FLAG_ENPASSANT
    jne .piece_sq
.piece_cap:
    mov byte [rdi], 'x'
    inc rdi
.piece_sq:
    mov eax, r9d
    call square_to_str
    mov ax, [square_str_buf]
    mov [rdi], ax
    add rdi, 2
    jmp .finish

.pawn:
    ; branie: <súbor>x
    lea rsi, [board]
    movzx eax, byte [rsi + r9]
    test eax, eax
    jnz .pawn_cap
    mov eax, r12d
    shr eax, 12
    and eax, 0xF
    cmp eax, FLAG_ENPASSANT
    jne .pawn_sq
.pawn_cap:
    mov eax, r8d
    and eax, 7
    add eax, 'a'
    mov [rdi], al
    mov byte [rdi+1], 'x'
    add rdi, 2
.pawn_sq:
    mov eax, r9d
    call square_to_str
    mov ax, [square_str_buf]
    mov [rdi], ax
    add rdi, 2
    ; promócia?
    mov eax, r12d
    shr eax, 12
    and eax, 0xF
    cmp eax, FLAG_PROMO_Q
    jb .finish
    cmp eax, FLAG_PROMO_N
    ja .finish
    mov byte [rdi], '='
    inc rdi
    lea rsi, [pgn_promo_chars]
    sub eax, FLAG_PROMO_Q
    mov al, [rsi + rax]
    mov [rdi], al
    inc rdi

.finish:
    lea rax, [pgn_san_buf]
    sub rdi, rax
    mov [pgn_san_len], rdi

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
; pgn_write_move - append ťahu do games.pgn (volanie PO record_hash)
; Deteguje +/# zo stavu po ťahu (side už prehodená), zapíše číslo
; ťahu + SAN do movetext bufferu (flush až pri uzavretí partie = 1 riadok).
; ------------------------------------------------------------
pgn_write_move:
    ; lazy open súboru
    cmp qword [pgn_fd], -1
    jne .file_ok
    call pgn_open_file          ; otvorí games.pgn (bez hlavičiek)
    cmp qword [pgn_fd], -1
    je .out                     ; otvorenie zlyhalo -> PGN vypnuté
.file_ok:
    ; hlavičky pri prvom ťahu každej partie
    cmp byte [pgn_game_open], 0
    jne .hdr_ok
    call pgn_write_headers
    mov byte [pgn_game_open], 1
    mov byte [pgn_result], 0
.hdr_ok:
    ; šach/mat: side = strana na ťahu (súper tahajúceho)
    movzx eax, byte [side]
    call is_in_check
    test rax, rax
    jz .no_suffix
    call generate_all_moves
    movzx eax, word [move_count]
    test eax, eax
    jz .is_mate
    mov al, '+'
    jmp .add_suffix
.is_mate:
    mov al, '#'
.add_suffix:
    mov rcx, [pgn_san_len]
    lea rdx, [pgn_san_buf]
    mov [rdx + rcx], al
    inc qword [pgn_san_len]
.no_suffix:
    ; prefix: číslo ťahu pred bielym (riadok je vždy prázdny - flush po každom ťahu)
    cmp byte [pgn_mover_side], 0
    jne .append_san
    movzx eax, word [pgn_move_no]
    call pgn_line_num
    mov al, '.'
    call pgn_line_putc
    mov al, ' '
    call pgn_line_putc
.append_san:
    lea rsi, [pgn_san_buf]
    mov rdx, [pgn_san_len]
    call pgn_line_write
    mov al, ' '
    call pgn_line_putc      ; oddeľovač; flush až pri uzavretí partie
.out:
    ret

; ------------------------------------------------------------
; pgn_new_game - uzavrie aktuálnu partiu (pre príkaz 'new')
; ------------------------------------------------------------
pgn_new_game:
    call pgn_close_game
    ret

; ------------------------------------------------------------
; pgn_quit - uzavrie partiu a zavrie súbor (pre exit/.done)
; ------------------------------------------------------------
pgn_quit:
    call pgn_close_game
    mov rax, [pgn_fd]
    cmp rax, -1
    je .out
    mov rdi, rax
    mov rax, SYS_CLOSE
    syscall
    mov qword [pgn_fd], -1
.out:
    ret

; ------------------------------------------------------------
; pgn_close_game - zapíše výsledok a ukonči sekciu partie
; ------------------------------------------------------------
pgn_close_game:
    cmp byte [pgn_game_open], 0
    je .out
    cmp qword [pgn_fd], -1
    je .out
    ; movetext v bufferi vždy končí medzerou (každý ťah ju pridá)
    movzx eax, byte [pgn_result]
    cmp eax, 1
    je .r10
    cmp eax, 2
    je .r01
    cmp eax, 3
    je .rdr
    lea rsi, [pgn_res_star]
    mov rdx, 1
    jmp .wr
.r10:
    lea rsi, [pgn_res_10]
    mov rdx, 3
    jmp .wr
.r01:
    lea rsi, [pgn_res_01]
    mov rdx, 3
    jmp .wr
.rdr:
    lea rsi, [pgn_res_draw]
    mov rdx, 7
.wr:
    call pgn_line_write
    call pgn_flush_line
    ; prázdny riadok za partiou
    mov rax, SYS_WRITE
    mov rdi, [pgn_fd]
    lea rsi, [pgn_nl]
    mov rdx, 1
    syscall
    mov byte [pgn_game_open], 0
.out:
    ret

; ------------------------------------------------------------
; pgn_open_file - otvorí games.pgn (append), bez hlavičiek
; ------------------------------------------------------------
pgn_open_file:
    mov rax, SYS_OPEN
    lea rdi, [pgn_filename]
    mov rsi, O_WRONLY | O_CREAT | O_APPEND
    mov rdx, 644o
    syscall
    test rax, rax
    js .fail
    mov [pgn_fd], rax
    ret
.fail:
    mov qword [pgn_fd], -1
    ret

; ------------------------------------------------------------
; pgn_write_headers - zapíše hlavičkový blok partie
; ------------------------------------------------------------
pgn_write_headers:
    lea rsi, [pgn_hdr_a]
    mov rdx, pgn_hdr_a_len
    call pgn_raw_write
    call pgn_get_date
    lea rsi, [pgn_date_buf]
    mov rdx, 10
    call pgn_raw_write
    lea rsi, [pgn_hdr_b]
    mov rdx, pgn_hdr_b_len
    call pgn_raw_write

    ; White/Black podľa engine_side
    ; (0 = engine biely, 1 = engine čierny, 2 = obaja engine, inak dvaja hráči)
    movzx eax, byte [engine_side]
    cmp eax, 0
    je .eng_white
    cmp eax, 1
    je .eng_black
    cmp eax, 2
    je .eng_both
    lea rsi, [pgn_hdr_players]
    mov rdx, pgn_hdr_players_len
    call pgn_raw_write
    jmp .fin
.eng_white:
    lea rsi, [pgn_hdr_eng_white]
    mov rdx, pgn_hdr_eng_white_len
    call pgn_raw_write
    jmp .fin
.eng_black:
    lea rsi, [pgn_hdr_eng_black]
    mov rdx, pgn_hdr_eng_black_len
    call pgn_raw_write
    jmp .fin
.eng_both:
    lea rsi, [pgn_hdr_eng_both]
    mov rdx, pgn_hdr_eng_both_len
    call pgn_raw_write
.fin:
    lea rsi, [pgn_hdr_c]
    mov rdx, pgn_hdr_c_len
    call pgn_raw_write
    ret

; ------------------------------------------------------------
; pgn_raw_write - zapíše rsi/rdx do súboru
; ------------------------------------------------------------
pgn_raw_write:
    mov rax, SYS_WRITE
    mov rdi, [pgn_fd]
    syscall
    ret

; ------------------------------------------------------------
; pgn_get_date - pgn_date_buf = "YYYY.MM.DD" (z clock_gettime)
; ------------------------------------------------------------
pgn_get_date:
    push rbx
    push r12
    push r13
    sub rsp, 48                 ; [0]=sec, [16]=era, [24]=doe, [32]=yoe, [40]=doy
    mov rax, SYS_CLOCK_GETTIME
    xor edi, edi                ; CLOCK_REALTIME
    mov rsi, rsp
    syscall
    ; dni od epochy
    mov rax, [rsp]
    xor edx, edx
    mov rcx, 86400
    div rcx
    add rax, 719468             ; z (Howard Hinnant: civil_from_days)
    xor edx, edx
    mov rcx, 146097
    div rcx                     ; rax = era, rdx = doe
    mov [rsp+16], rax
    mov [rsp+24], rdx
    ; yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov rax, [rsp+24]
    xor edx, edx
    mov rcx, 1460
    div rcx
    mov rbx, rax                ; doe/1460
    mov rax, [rsp+24]
    xor edx, edx
    mov rcx, 36524
    div rcx
    mov r12, rax                ; doe/36524
    mov rax, [rsp+24]
    xor edx, edx
    mov rcx, 146096
    div rcx                     ; doe/146096
    mov rcx, [rsp+24]
    sub rcx, rbx
    add rcx, r12
    sub rcx, rax
    mov rax, rcx
    xor edx, edx
    mov rcx, 365
    div rcx                     ; rax = yoe
    mov [rsp+32], rax
    ; doy = doe - (365*yoe + yoe/4 - yoe/100)
    imul rax, rax, 365
    mov rbx, rax
    mov rax, [rsp+32]
    xor edx, edx
    mov rcx, 4
    div rcx
    add rbx, rax
    mov rax, [rsp+32]
    xor edx, edx
    mov rcx, 100
    div rcx
    sub rbx, rax
    mov rax, [rsp+24]
    sub rax, rbx                ; doy
    mov [rsp+40], rax
    ; mp = (5*doy + 2) / 153
    lea rcx, [rax + rax*4]
    add rcx, 2
    mov rax, rcx
    xor edx, edx
    mov rcx, 153
    div rcx                     ; rax = mp
    mov r13, rax
    ; d = doy - (153*mp + 2)/5 + 1
    imul rax, rax, 153
    add rax, 2
    xor edx, edx
    mov rcx, 5
    div rcx
    mov rcx, [rsp+40]
    sub rcx, rax
    inc rcx                     ; d
    mov r12, rcx
    ; m = mp + (mp < 10 ? 3 : -9)
    mov rax, r13
    cmp rax, 10
    jl .plus3
    sub rax, 9
    jmp .havem
.plus3:
    add rax, 3
.havem:
    mov rbx, rax                ; m
    ; y = yoe + era*400 (+1 ak m <= 2)
    mov rax, [rsp+32]
    mov rcx, [rsp+16]
    imul rcx, rcx, 400
    add rax, rcx
    cmp rbx, 2
    jg .havey
    inc rax
.havey:
    mov r13, rax                ; y
    ; formát
    lea rdi, [pgn_date_buf]
    mov eax, r13d
    mov ecx, 4
    call pgn_dec_pad
    mov byte [rdi], '.'
    inc rdi
    mov eax, ebx
    mov ecx, 2
    call pgn_dec_pad
    mov byte [rdi], '.'
    inc rdi
    mov eax, r12d
    mov ecx, 2
    call pgn_dec_pad
    mov byte [rdi], 0
    add rsp, 48
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; pgn_dec_pad - rax = hodnota, rcx = počet číslic, rdi = cieľ
; Zapíše desiatkovo (s vodicimi nulami), posunie rdi o počet číslic.
; ------------------------------------------------------------
pgn_dec_pad:
    mov r8, rax                 ; hodnota
    mov r11d, ecx               ; počet číslic (pre delenie)
    mov r10d, ecx               ; počet číslic (pre kopírovanie)
    lea r9, [pgn_dec_tmp+7]     ; číslicy zapisujeme odzadu
.dl:
    mov rax, r8
    xor edx, edx
    mov rcx, 10
    div rcx
    mov r8, rax
    add dl, '0'
    mov [r9], dl
    dec r9
    dec r11d
    jnz .dl
    inc r9                      ; prvá číslica
.cp:
    mov al, [r9]
    mov [rdi], al
    inc r9
    inc rdi
    dec r10d
    jnz .cp
    ret

; ------------------------------------------------------------
; pgn_line_num - eax = číslo -> append do pgn_line
; ------------------------------------------------------------
pgn_line_num:
    lea rdi, [pgn_line]
    add rdi, [pgn_line_len]
    mov ecx, 1
    cmp eax, 10
    jl .w
    mov ecx, 2
    cmp eax, 100
    jl .w
    mov ecx, 3
.w:
    call pgn_dec_pad
    lea rax, [pgn_line]
    sub rdi, rax
    mov [pgn_line_len], rdi
    ret

; ------------------------------------------------------------
; pgn_line_write - rsi = ptr, rdx = len -> append do pgn_line
; ------------------------------------------------------------
pgn_line_write:
    lea rdi, [pgn_line]
    add rdi, [pgn_line_len]
    mov rcx, rdx
    rep movsb
    add [pgn_line_len], rdx
    ret

; ------------------------------------------------------------
; pgn_line_putc - al = znak -> append do pgn_line
; ------------------------------------------------------------
pgn_line_putc:
    mov rcx, [pgn_line_len]
    lea rdx, [pgn_line]
    mov [rdx + rcx], al
    inc qword [pgn_line_len]
    ret

; ------------------------------------------------------------
; pgn_flush_line - zapíše riadok + nový riadok do súboru
; ------------------------------------------------------------
pgn_flush_line:
    mov rdx, [pgn_line_len]
    test rdx, rdx
    jz .out
    mov rax, SYS_WRITE
    mov rdi, [pgn_fd]
    lea rsi, [pgn_line]
    syscall
    mov rax, SYS_WRITE
    mov rdi, [pgn_fd]
    lea rsi, [pgn_nl]
    mov rdx, 1
    syscall
    mov qword [pgn_line_len], 0
.out:
    ret