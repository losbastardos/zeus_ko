; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; uci.asm - zakladna podpora UCI protokolu
; ============================================================

%include "chess.inc"

DEFAULT REL

section .data

global uci_id_name, uci_id_author, uci_ok, uci_ready, uci_bestmove, uci_unknown
global uci_opt_hash, uci_opt_ownbook, uci_opt_ponder, uci_opt_syzygy, uci_opt_syzygy_depth, uci_opt_overhead

%defstr BUILD_DATE_STR BUILD_DATE

uci_id_name:
    db "id name Zeus_KO ", BUILD_DATE_STR, 10, 0
uci_id_name_len equ $ - uci_id_name - 1

uci_id_author:
    db "id author AI", 10, 0
uci_id_author_len equ $ - uci_id_author - 1

uci_ok:
    db "uciok", 10, 0
uci_ok_len equ $ - uci_ok - 1

uci_opt_hash:    db "option name Hash type spin default 64 min 16 max 1024", 10, 0
uci_opt_ownbook: db "option name OwnBook type check default true", 10, 0
uci_opt_ponder:  db "option name Ponder type check default false", 10, 0
uci_opt_syzygy:  db "option name SyzygyPath type string default <empty>", 10, 0
uci_opt_syzygy_depth: db "option name SyzygyProbeDepth type spin default 1 min 0 max 64", 10, 0
uci_opt_overhead: db "option name MoveOverhead type spin default 100 min 0 max 10000", 10, 0

uci_ready:
    db "readyok", 10, 0
uci_ready_len equ $ - uci_ready - 1

uci_bestmove:
    db "bestmove ", 0
uci_bestmove_len equ $ - uci_bestmove - 1

uci_unknown:
    db "info string neznamy prikaz", 10, 0
uci_unknown_len equ $ - uci_unknown - 1

uci_tbtest_prefix: db "info string tbtest pieces=", 0
uci_tbtest_wdl:    db " wdl=", 0
uci_tbtest_dtz:    db " dtz=", 0
uci_tbtest_map:    db " map_bytes=", 0
uci_tbtest_path:   db " path=", 0
uci_tbtest_wdl_payload: db " wdl_payload_byte=", 0
uci_tbtest_dtz_payload: db " dtz_payload_byte=", 0
uci_bbtest_prefix: db "info string bbtest mismatches=", 0

uci_log_name:      db "uci_debug.log", 0
uci_log_start:     db "=== Zeus_KO ", BUILD_DATE_STR, " start ===", 10
uci_log_start_len  equ $ - uci_log_start
uci_log_fail:      db "info string uci_debug.log: otvorenie zlyhalo (chyba prava zapisu?)", 10
uci_log_fail_len   equ $ - uci_log_fail
uci_log_prefix_in: db ">> "
uci_log_bm_prefix: db "<< bestmove "
uci_log_bm_prefix_len equ $ - uci_log_bm_prefix
uci_log_bm_null:   db "<< bestmove 0000", 10
uci_log_bm_null_len equ $ - uci_log_bm_null
uci_str_0000:      db "0000"
uci_log_bad_bm:    db "!! WARNING: bestmove nie je legalny tah - fallback na prvy legalny", 10
uci_log_bad_bm_len equ $ - uci_log_bad_bm

section .data
uci_log_fd: dq -2                      ; -2 = neotvorene, -1 = zlyhalo (bez retry)

section .bss
uci_next_idx: resq 1      ; index dalsieho tokenu (generate_all_moves nicí r12)
fen_buf:      resb 128    ; buffer pre FEN reťazec
uci_timespec: resq 2
pv_char_buf:  resb 1
uci_log_move_buf: resb 8 ; "e2e4" / "e7e8q" pre log
input_pend:     resb 512  ; nevybavený vstup z pollu počas searchu (oddelený od move_buf!)
input_pend_len: resq 1
uci_quit_flag:  resb 1    ; 'quit' prišlo počas searchu -> exit hneď po bestmove
uci_pgn_ply:    resq 1    ; počet ťahov zaznamenaných do PGN v aktuálnej partii
uci_pgn_idx:    resq 1    ; index ťahu v práve spracúvanom 'position ... moves'
input_pollfd:   resd 2    ; pollfd: dd fd, dw events, dw revents
uci_iter_start: resq 1    ; mode 2: start aktuálnej ID iterácie (ms)
uci_iter_dur:   resq 1    ; mode 2: trvanie poslednej dokončenej iterácie (ms)

INPUT_PEND_SIZE equ 512

section .text

global uci_loop, write_cstr, search_poll_input, uci_now_ms

extern init_board, init_hash_history, record_hash, clear_history
extern pgn_san_begin, pgn_write_move, pgn_new_game, pgn_quit
extern generate_all_moves, find_move, apply_move, update_position_state, compute_hash
extern search_best_move, book_lookup, print_move, square_to_str, print_number
extern tt_init
extern parse_fen_string, parse_int
extern board, side, move_buf, move_buf_len, move_list, move_count, search_depth
extern position_hash, square_str_buf
extern uci_stop_flag, uci_ponder, uci_own_book, uci_hash_size, uci_move_overhead, uci_syzygy_probe_depth
extern search_limits, nodes_searched, search_last_score
extern asp_alpha, asp_beta, asp_delta, asp_use, asp_retry
extern make_move, unmake_move, tt_probe
extern pv_moves, pv_moves_len
extern msg_newline
extern tb_init, tb_path, tb_path_len, tb_probe_wdl, tb_probe_dtz, tb_piece_count, tb_map_size, tb_file_path
extern bb_validate_position
extern book_pick_move, book_mode, book_search_depth
extern tb_wdl_payload_probe_byte, tb_dtz_payload_probe_byte
extern suite_cmd_uci

; ============================================================
; write_str - vypise C-string na stdout
; Vstup: rdi = string, rdx = len
; ============================================================
write_str:
    push rax
    mov rax, SYS_WRITE
    mov rsi, rdi
    mov rdi, STDOUT
    syscall
    pop rax
    ret

; ============================================================
; write_cstr - vypise null-terminated C-string
; ============================================================
write_cstr:
    push rbx
    push rcx
    mov rbx, rdi
    xor rcx, rcx
.len_loop:
    cmp byte [rbx + rcx], 0
    je .print
    inc rcx
    jmp .len_loop
.print:
    mov rdx, rcx
    call write_str
    pop rcx
    pop rbx
    ret

; ============================================================
; uci_log_str - zapise retazec do uci_debug.log (best-effort)
; Vstup: rdi = ptr, rsi = len. Vsetky chyby ticho ignorovane.
; Lazy open v cwd pri prvom volani; fd=-1 -> nikdy viac neotvarame.
; ============================================================
uci_log_str:
    push rbx
    push r12
    push r13
    mov r12, rdi              ; ptr
    mov r13, rsi              ; len
    mov rbx, [uci_log_fd]
    cmp rbx, -2
    jne .have_fd
    mov rax, SYS_OPEN
    lea rdi, [uci_log_name]
    mov esi, O_WRONLY | O_CREAT | O_APPEND
    mov edx, 420              ; 0644
    syscall
    test rax, rax
    js .open_failed
    mov rbx, rax
    mov [uci_log_fd], rax
    jmp .write
.open_failed:
    mov qword [uci_log_fd], -1
    ; jednorazovo viditelne oznamime do stdout (GUI Engine output)
    mov eax, SYS_WRITE
    mov edi, 1
    lea rsi, [uci_log_fail]
    mov edx, uci_log_fail_len
    syscall
    jmp .done
.have_fd:
    cmp rbx, -1
    je .done
.write:
    mov rax, SYS_WRITE
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    syscall
.done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; uci_token - najde dalsi token v move_buf
; Vstup:  rdi = start index
; Vystup: rax = start index tokenu, rbx = dlzka tokenu,
;         rcx = index prveho znaku za tokenom (alebo -1 ak koniec)
; ============================================================
uci_token:
    push r12
    push r13
    mov r12, rdi
    mov r13, [move_buf_len]

    ; preskoc whitespace
.skip_ws:
    cmp r12, r13
    jge .end
    movzx rax, byte [move_buf + r12]
    cmp rax, ' '
    je .ws_next
    cmp rax, 9
    je .ws_next
    cmp rax, 10
    je .ws_next
    cmp rax, 13
    je .ws_next
    jmp .find_end
.ws_next:
    inc r12
    jmp .skip_ws

.find_end:
    mov r8, r12
.find_loop:
    cmp r8, r13
    jge .end_found
    movzx rax, byte [move_buf + r8]
    cmp rax, ' '
    je .end_found
    cmp rax, 9
    je .end_found
    cmp rax, 10
    je .end_found
    cmp rax, 13
    je .end_found
    inc r8
    jmp .find_loop

.end_found:
    mov rax, r12
    mov rbx, r8
    sub rbx, r12
    mov rcx, r8
    pop r13
    pop r12
    ret

.end:
    mov rax, -1
    pop r13
    pop r12
    ret

; ============================================================
; uci_str_eq - porovna token s C-stringom
; Vstup: rdi = token start, rsi = token len, rdx = C-string
; Vystup: rax = 1 ak rovnake, inak 0
; ============================================================
uci_str_eq:
    push rbx
    push rcx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor rcx, rcx
.loop:
    cmp rcx, r13
    jge .check_term
    movzx rax, byte [move_buf + r12 + rcx]
    movzx rbx, byte [r14 + rcx]
    cmp rax, rbx
    jne .no
    inc rcx
    jmp .loop
.check_term:
    movzx rax, byte [r14 + rcx]
    test rax, rax
    jz .yes
.no:
    xor rax, rax
    jmp .done
.yes:
    mov rax, 1
.done:
    pop r14
    pop r13
    pop r12
    pop rcx
    pop rbx
    ret

; ============================================================
; uci_parse_move - prevedie 4-znakovy token na 16-bitovy tah
; Vstup: rdi = token start, rsi = token len
; Vystup: rax = tah, 0 ak chyba
; ============================================================
uci_parse_move:
    push rbx
    cmp rsi, 4
    je .len_ok
    cmp rsi, 5
    jne .error
.len_ok:

    movzx rax, byte [move_buf + rdi]
    sub rax, 'a'
    cmp rax, 7
    ja .error
    mov rbx, rax

    movzx rax, byte [move_buf + rdi + 1]
    sub rax, '1'
    cmp rax, 7
    ja .error
    shl rax, 3
    add rbx, rax

    movzx rax, byte [move_buf + rdi + 2]
    sub rax, 'a'
    cmp rax, 7
    ja .error
    mov rcx, rax

    movzx rax, byte [move_buf + rdi + 3]
    sub rax, '1'
    cmp rax, 7
    ja .error
    shl rax, 3
    add rcx, rax

    shl rcx, 6
    or rbx, rcx

    ; promocia (5. znak: q/r/b/n)
    cmp rsi, 5
    jne .raw
    movzx rax, byte [move_buf + rdi + 4]
    cmp rax, 'q'
    je .promo_q
    cmp rax, 'r'
    je .promo_r
    cmp rax, 'b'
    je .promo_b
    cmp rax, 'n'
    je .promo_n
    jmp .error
.promo_q:
    or rbx, 1 << 12
    jmp .raw
.promo_r:
    or rbx, 2 << 12
    jmp .raw
.promo_b:
    or rbx, 3 << 12
    jmp .raw
.promo_n:
    or rbx, 4 << 12
.raw:
    mov rax, rbx
    jmp .done

.error:
    xor rax, rax
.done:
    pop rbx
    ret

; ============================================================
; uci_apply_moves - aplikuje postupnost tahov za 'moves'
; Vstup: rdi = index prveho tokenu po 'moves'
; ============================================================
uci_apply_moves:
    push rbx
    push r12
    push r13
    push r14
    mov rax, rdi
    mov [uci_next_idx], rax

    ; --- PGN: spočítaj ťahy v tomto príkaze (GUI posiela celú históriu) ---
    ; takeback / kratšia história -> uzavri PGN sekciu a zaznamenaj znovu
    mov r12, rdi              ; cursor
    xor r13, r13              ; počet tokenov (uci_token zachová r12-r15)
.pgn_count_loop:
    mov rdi, r12
    call uci_token
    cmp rax, -1
    je .pgn_count_done
    test rbx, rbx
    jz .pgn_count_done
    inc r13
    mov r12, rcx
    jmp .pgn_count_loop
.pgn_count_done:
    cmp r13, [uci_pgn_ply]
    jae .pgn_no_reset
    call pgn_new_game
    mov qword [uci_pgn_ply], 0
.pgn_no_reset:
    mov qword [uci_pgn_idx], 0

.move_loop:
    mov rdi, [uci_next_idx]
    call uci_token
    cmp rax, -1
    je .done
    test rbx, rbx
    jz .done

    mov r13, rax          ; start tokenu
    mov r14, rbx          ; dlzka tokenu
    mov [uci_next_idx], rcx

    ; generuj tahy pre aktualnu poziciu az teraz
    call generate_all_moves

    mov rdi, r13
    mov rsi, r14
    call uci_parse_move
    test rax, rax
    jz .done

    mov rbx, rax
    test rax, 0xF000
    jz .find_normal

    ; promocia - hladaj presnu zhodu vratane flags
    xor rcx, rcx
    movzx rdx, word [move_count]
    lea rsi, [move_list]
.find_promo:
    cmp rcx, rdx
    jge .done
    movzx rax, word [rsi + rcx*2]
    cmp rax, rbx
    je .apply
    inc rcx
    jmp .find_promo

.find_normal:
    mov rax, rbx
    call find_move
    test rax, rax
    jz .done

.apply:
    ; PGN: zaznamenaj len nové ťahy (rax = nájdený ťah z move_list, s flags)
    mov rcx, [uci_pgn_idx]
    cmp rcx, [uci_pgn_ply]
    jb .pgn_no_san
    push rax
    call pgn_san_begin      ; SAN jadro (move_list ešte obsahuje legálne ťahy)
    pop rax
.pgn_no_san:
    call apply_move
    call update_position_state
    call compute_hash
    call record_hash
    mov rax, [uci_pgn_idx]
    cmp rax, [uci_pgn_ply]
    jb .pgn_skip
    call pgn_write_move     ; append do games.pgn (real-time)
    inc qword [uci_pgn_ply]
.pgn_skip:
    inc qword [uci_pgn_idx]
    jmp .move_loop

.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; uci_parse_fen - prečíta 6 FEN tokenov, zloží reťazec a zavolá parser
; Vstup: rdi = index prvého tokenu za 'fen'
; Vystup: rax = index tokenu za FEN políčkami (alebo -1 ak chyba)
; ============================================================
uci_parse_fen:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi              ; aktuálny index tokenu
    lea r14, [fen_buf]        ; cieľový buffer
    mov r13, 6                ; počet FEN políčok

.field_loop:
    mov rdi, r12
    call uci_token
    cmp rax, -1
    je .error
    test rbx, rbx
    jz .error

    mov r15, rcx              ; uloz index dalsieho tokenu
    mov r12, rax              ; zaciatok tokenu
    mov rcx, rbx              ; dlzka tokenu

.copy_loop:
    cmp rcx, 0
    jle .copy_done
    movzx rax, byte [move_buf + r12]
    mov [r14], al
    inc r14
    inc r12
    dec rcx
    jmp .copy_loop

.copy_done:
    dec r13
    jz .all_fields
    mov byte [r14], ' '
    inc r14
    mov r12, r15
    jmp .field_loop

.all_fields:
    mov byte [r14], 0         ; null terminate

    lea rdi, [fen_buf]
    call parse_fen_string
    test rax, rax
    jnz .error

    mov rax, r15              ; vráti index za posledným FEN tokenom
    jmp .done

.error:
    mov rax, -1
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; uci_position - spracuje 'position' prikaz
; ============================================================
uci_position:
    push rbx
    push r12

    ; dalsi token po 'position'
    mov rdi, 8
    call uci_token
    cmp rax, -1
    je .done

    mov rdi, rax
    mov rsi, rbx
    mov r12, rax              ; uloz zaciatok tokenu (str_eq prepise rax)
    lea rdx, [rel .str_startpos]
    call uci_str_eq
    test rax, rax
    jnz .startpos

    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_fen]
    call uci_str_eq
    test rax, rax
    jnz .fen

    ; inak ignorujeme
    jmp .done

.startpos:
    mov [uci_next_idx], rcx

    call init_board
    call init_hash_history
    call record_hash
    jmp .find_moves

.fen:
    mov rdi, rcx
    call uci_parse_fen
    cmp rax, -1
    je .done
    mov [uci_next_idx], rax

.find_moves:
    ; hladaj 'moves'
.start_loop:
    mov rdi, [uci_next_idx]
    call uci_token
    cmp rax, -1
    je .done
    test rbx, rbx
    jz .done

    mov rdi, rax
    mov rsi, rbx
    lea rdx, [rel .str_moves]
    call uci_str_eq
    test rax, rax
    jz .next_token

    mov rdi, rcx
    call uci_apply_moves
    jmp .done

.next_token:
    mov [uci_next_idx], rcx
    jmp .start_loop

.done:
    pop r12
    pop rbx
    ret

.str_startpos: db "startpos", 0
.str_fen:      db "fen", 0
.str_moves:    db "moves", 0

; ============================================================
; uci_setoption - spracuje 'setoption name <id> value <x>'
; Vstup: rdi = index tokenu za 'setoption'
; ============================================================
uci_setoption:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi

    ; ocakavame 'name'
    mov rdi, r12
    call uci_token
    cmp rax, -1
    je .done
    test rbx, rbx
    jz .done
    mov r12, rcx

    ; id optionu
    mov rdi, r12
    call uci_token
    cmp rax, -1
    je .done
    test rbx, rbx
    jz .done
    mov r13, rax          ; start id
    mov r14, rbx          ; dlzka id
    mov r12, rcx

    ; ocakavame 'value'
    mov rdi, r12
    call uci_token
    cmp rax, -1
    je .done
    test rbx, rbx
    jz .done
    mov r12, rcx

    ; hodnota
    mov rdi, r12
    call uci_token
    cmp rax, -1
    je .value_missing
    test rbx, rbx
    jz .value_missing
    mov r15, rax          ; start hodnoty
    jmp .value_ready

.value_missing:
    mov r15, [move_buf_len] ; prazdna hodnota (napr. SyzygyPath reset)
    xor ebx, ebx

.value_ready:
    ; rbx = dlzka hodnoty (0 pri prazdnej hodnote)

    ; porovnaj id
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rel .str_hash]
    call uci_str_eq
    test rax, rax
    jnz .opt_hash

    mov rdi, r13
    mov rsi, r14
    lea rdx, [rel .str_ownbook]
    call uci_str_eq
    test rax, rax
    jnz .opt_ownbook

    mov rdi, r13
    mov rsi, r14
    lea rdx, [rel .str_ponder]
    call uci_str_eq
    test rax, rax
    jnz .opt_ponder

    mov rdi, r13
    mov rsi, r14
    lea rdx, [rel .str_syzygypath]
    call uci_str_eq
    test rax, rax
    jnz .opt_syzygypath

    mov rdi, r13
    mov rsi, r14
    lea rdx, [rel .str_syzygyprobedepth]
    call uci_str_eq
    test rax, rax
    jnz .opt_syzygyprobedepth

    mov rdi, r13
    mov rsi, r14
    lea rdx, [rel .str_moveoverhead]
    call uci_str_eq
    test rax, rax
    jnz .opt_moveoverhead

    jmp .done

.opt_hash:
    mov rdi, r15
    mov rsi, rbx
    call uci_parse_int
    test eax, eax
    jg .hash_min_ok
    mov eax, 16
.hash_min_ok:
    cmp eax, 1024
    jle .hash_max_ok
    mov eax, 1024
.hash_max_ok:
    mov [uci_hash_size], eax
    mov edi, eax
    call tt_init
    jmp .done

.opt_ownbook:
    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel .str_true]
    call uci_str_eq
    test rax, rax
    jz .opt_ownbook_false
    mov byte [uci_own_book], 1
    jmp .done
.opt_ownbook_false:
    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel .str_false]
    call uci_str_eq
    test rax, rax
    jz .done
    mov byte [uci_own_book], 0
    jmp .done

.opt_ponder:
    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel .str_true]
    call uci_str_eq
    test rax, rax
    jz .opt_ponder_false
    mov byte [uci_ponder], 1
    jmp .done
.opt_ponder_false:
    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel .str_false]
    call uci_str_eq
    test rax, rax
    jz .done
    mov byte [uci_ponder], 0
    jmp .done

.opt_syzygypath:
    ; SyzygyPath: ber celu hodnotu az do konca riadku (mozu byt medzery v ceste)
    ; r15 = start prveho tokenu hodnoty; [move_buf_len] = koniec vstupneho riadku
    mov rcx, [move_buf_len]
    cmp r15, rcx
    jae .tb_clear
    sub rcx, r15
    jmp .tb_trim_tail

.tb_clear:
    lea rdi, [tb_path]
    mov byte [rdi], 0
    mov qword [tb_path_len], 0
    call tb_init
    jmp .done

.tb_trim_tail:
    test rcx, rcx
    jz .tb_copy_ready
    movzx eax, byte [move_buf + r15 + rcx - 1]
    cmp al, ' '
    je .tb_trim_dec
    cmp al, 9
    je .tb_trim_dec
    cmp al, 10
    je .tb_trim_dec
    cmp al, 13
    je .tb_trim_dec
    jmp .tb_copy_ready
.tb_trim_dec:
    dec rcx
    jmp .tb_trim_tail

.tb_copy_ready:
    ; specialna hodnota "<empty>" vypne TB cestu
    cmp rcx, 7
    jne .tb_len_cap
    movzx eax, byte [move_buf + r15 + 0]
    cmp al, '<'
    jne .tb_len_cap
    movzx eax, byte [move_buf + r15 + 1]
    cmp al, 'e'
    jne .tb_len_cap
    movzx eax, byte [move_buf + r15 + 2]
    cmp al, 'm'
    jne .tb_len_cap
    movzx eax, byte [move_buf + r15 + 3]
    cmp al, 'p'
    jne .tb_len_cap
    movzx eax, byte [move_buf + r15 + 4]
    cmp al, 't'
    jne .tb_len_cap
    movzx eax, byte [move_buf + r15 + 5]
    cmp al, 'y'
    jne .tb_len_cap
    movzx eax, byte [move_buf + r15 + 6]
    cmp al, '>'
    jne .tb_len_cap
    jmp .tb_clear

.tb_len_cap:
    cmp rcx, 255
    jbe .tb_len_ok
    mov rcx, 255            ; bezpecna truncat na max 255 znakov
.tb_len_ok:
    lea rsi, [move_buf + r15] ; zdroj: hodnota v move_buf
    lea rdi, [tb_path]         ; ciel: interny buffer tb.asm
    xor r8, r8
.tb_copy:
    cmp r8, rcx
    jae .tb_term
    movzx eax, byte [rsi + r8]
    mov [rdi + r8], al
    inc r8
    jmp .tb_copy
.tb_term:
    mov byte [rdi + r8], 0
    mov [tb_path_len], r8
    call tb_init            ; rdi ukazuje na ulozenu cestu
    jmp .done

.opt_syzygyprobedepth:
    mov rdi, r15
    mov rsi, rbx
    call uci_parse_int
    test eax, eax
    jge .syzygy_depth_min_ok
    xor eax, eax
.syzygy_depth_min_ok:
    cmp eax, 64
    jle .syzygy_depth_store
    mov eax, 64
.syzygy_depth_store:
    mov [uci_syzygy_probe_depth], eax
    jmp .done

.opt_moveoverhead:
    mov rdi, r15
    mov rsi, rbx
    call uci_parse_int
    test eax, eax
    jl .overhead_min
    cmp eax, 10000
    jle .overhead_store
    mov eax, 10000
.overhead_min:
    xor eax, eax
.overhead_store:
    mov [uci_move_overhead], eax
    jmp .done

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.str_hash:     db "Hash", 0
.str_ownbook:  db "OwnBook", 0
.str_ponder:   db "Ponder", 0
.str_syzygypath: db "SyzygyPath", 0
.str_syzygyprobedepth: db "SyzygyProbeDepth", 0
.str_moveoverhead: db "MoveOverhead", 0
.str_true:     db "true", 0
.str_false:    db "false", 0

uci_str_depth:      db "depth", 0
uci_str_movetime:   db "movetime", 0
uci_str_wtime:      db "wtime", 0
uci_str_btime:      db "btime", 0
uci_str_winc:       db "winc", 0
uci_str_binc:       db "binc", 0
uci_str_movestogo:  db "movestogo", 0
uci_str_infinite:   db "infinite", 0
uci_str_ponder_kw:  db "ponder", 0

uci_info_depth: db "info depth ", 0
uci_info_score: db " score cp ", 0
uci_info_nodes: db " nodes ", 0
uci_info_time:  db " time ", 0
uci_info_pv:    db " pv ", 0
uci_minus:      db "-", 0
pv_promo_chars: db "qrbn"
pv_space:       db " "

; ============================================================
; uci_now_ms - monotonic cas v ms
; Vystup: rax = ms
; ============================================================
uci_now_ms:
    push rbx
    push rcx
    push rdx

    mov rax, SYS_CLOCK_GETTIME
    mov rdi, CLOCK_MONOTONIC
    lea rsi, [uci_timespec]
    syscall
    test rax, rax
    js .err

    mov rax, [uci_timespec]      ; sec
    imul rax, 1000
    mov rbx, rax                 ; sec_ms
    mov rax, [uci_timespec + 8]  ; nsec
    mov rcx, 1000000
    xor rdx, rdx
    div rcx
    add rax, rbx
    jmp .done

.err:
    xor rax, rax

.done:
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; uci_alloc_time - casovy budget pre mode 2 (time/movestogo + inc, min 50ms)
; Pouziva cas strany na tahu z search_limits; vysledok do +56/+64.
; Volaju uci_go (mode 2) aj search_poll_input (ponderhit).
; ============================================================
uci_alloc_time:
    movzx ecx, byte [side]
    test ecx, ecx
    jz .alloc_white
    mov rax, [search_limits + 24]       ; btime
    mov rcx, [search_limits + 40]       ; binc
    jmp .alloc_common
.alloc_white:
    mov rax, [search_limits + 16]       ; wtime
    mov rcx, [search_limits + 32]       ; winc
.alloc_common:
    movzx edx, byte [search_limits + 2] ; movestogo
    test edx, edx
    jnz .have_mtg
    mov edx, 30
.have_mtg:
    mov r8d, edx
    xor rdx, rdx
    div r8
    add rax, rcx
    test rax, rax
    jnz .alloc_store
    mov rax, 50
.alloc_store:
    ; odcitaj move overhead od soft/hard limitu
    mov r9d, [uci_move_overhead]
    sub rax, r9
    jg .soft_ok
    mov rax, 10
.soft_ok:
    mov [search_limits + 56], rax        ; soft = base - overhead
    mov rcx, rax
    shr rcx, 1
    add rcx, rax
    mov [search_limits + 64], rcx        ; hard = base + base/2
    ret

; ============================================================
; search_poll_input - neblokujuce spracovanie UCI vstupu pocas searchu
; Volane z check_time (search.asm) len kazdych 1024 nodov.
; Obsluzi: stop, ponderhit (len v mode 4), isready, quit.
; Registre: nici caller-saved + rbx/r12/r13 (tie su ulozene).
; ============================================================
search_poll_input:
    push rbx
    push r12
    push r13

    ; a) poll(fd 0, timeout 0): je na stdin pripraveny bajt?
    mov dword [input_pollfd], 0         ; fd = STDIN
    mov word [input_pollfd + 4], POLLIN
    mov word [input_pollfd + 6], 0
    mov rax, SYS_POLL
    lea rdi, [input_pollfd]
    mov esi, 1                          ; nfds
    xor edx, edx                        ; timeout 0
    syscall
    test rax, rax
    jle .done
    test word [input_pollfd + 6], POLLIN
    jz .done

    ; b) nacitaj volne bajty do input_pend
    mov rdx, INPUT_PEND_SIZE
    sub rdx, [input_pend_len]
    jz .done                            ; buffer plny
    mov rax, SYS_READ
    xor edi, edi
    lea rsi, [input_pend]
    add rsi, [input_pend_len]
    syscall
    test rax, rax
    jle .done
    add [input_pend_len], rax

    ; c)-e) spracuj vsetky cele riadky v bufferi
.line_loop:
    mov r12, [input_pend_len]
    lea rbx, [input_pend]
    xor ecx, ecx
.find_nl:
    cmp rcx, r12
    jae .done                           ; ziadny cely riadok - koncime
    cmp byte [rbx + rcx], 10
    je .have_line
    inc rcx
    jmp .find_nl
.have_line:
    mov r13, rcx                        ; index newlineu = raw dlzka riadku

    ; odstran trailing '\r' (CRLF protokol)
    test r13, r13
    jz .dispatch
    cmp byte [rbx + r13 - 1], 13
    jne .dispatch
    dec r13
.dispatch:
    ; case-sensitive porovnanie prikazov
    ; Neznamy prikaz NESMIE byt zahodeny - nechame ho v input_pend
    ; pre uci_loop (inak by pipelined 'position'/'go' pocas searchu
    ; zmizli a GUI by cakalo na bestmove naveky).
    cmp r13, 4
    jne .try_isready
    mov eax, dword [rbx]
    cmp eax, 'stop'
    je .cmd_stop
    cmp eax, 'quit'
    je .cmd_quit
    jmp .keep_line
.try_isready:
    cmp r13, 7
    jne .try_ponderhit
    cmp dword [rbx], 'isre'
    jne .keep_line
    cmp dword [rbx + 3], 'eady'
    jne .keep_line
    jmp .cmd_isready
.try_ponderhit:
    cmp r13, 9
    jne .keep_line
    cmp dword [rbx], 'pond'
    jne .keep_line
    cmp dword [rbx + 4], 'erhi'
    jne .keep_line
    cmp byte [rbx + 8], 't'
    jne .keep_line

    ; --- ponderhit: len v ponder mode prepne na casovany budget ---
    cmp byte [search_limits + 0], 4
    jne .next_line
    mov byte [search_limits + 0], 2
    mov byte [uci_ponder], 0
    call uci_alloc_time
    call uci_now_ms
    mov [search_limits + 48], rax       ; budget odpocitavany od momentu ponderhitu
    jmp .next_line

.cmd_isready:
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [uci_ready]                ; "readyok\n"
    mov edx, 8
    syscall
    jmp .next_line

.cmd_stop:
    mov byte [uci_stop_flag], 1
    jmp .next_line

.cmd_quit:
    mov byte [uci_quit_flag], 1
    ; v infinite/ponder mode musi quit zastavit aj search (inak by visel naveky)
    cmp byte [search_limits + 0], 3
    je .quit_stop
    cmp byte [search_limits + 0], 4
    je .quit_stop
    jmp .next_line
.quit_stop:
    mov byte [uci_stop_flag], 1
    jmp .next_line

.next_line:
    ; vyhod riadok z input_pend (r13+1 bajtov z lava)
    mov rax, r12
    sub rax, r13
    dec rax                             ; nova dlzka = len - nl - 1
    xor ecx, ecx
    lea rsi, [rbx + r13 + 1]            ; zdroj za newlineom
.shift:
    cmp rcx, rax
    jae .shift_done
    mov dl, [rsi + rcx]
    mov [rbx + rcx], dl
    inc rcx
    jmp .shift
.shift_done:
    mov [input_pend_len], rax
    ; po 'stop' zvysne prikazy nechame na uci_loop (bestmove pride skor)
    cmp byte [uci_stop_flag], 0
    jne .done
    jmp .line_loop

.keep_line:
    ; neznamy riadok zostava v input_pend - uci_loop si ho precita po searchu
    jmp .done

.done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; uci_sanitize_best - poistka: bestmove musi byt legalny tah
; Vstup:  rax = kandidat (16-bit tah, 0 = mat/pat)
; Vystup: rax = kandidat ak sa najde v legalnom move_liste,
;         inak prvy legalny tah (alebo 0 ak ziaden neexistuje)
; Pozn.: generate_all_moves nici r12-r15, preto ich ukladame.
; ============================================================
uci_sanitize_best:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14, rax
    test rax, rax
    jz .ret                       ; 0 = mat/pat, nechaj 0000
    call generate_all_moves       ; board je na root pozicii (search skoncil)
    movzx r15, word [move_count]
    lea rsi, [move_list]
    xor rcx, rcx
.scan:
    cmp rcx, r15
    jge .not_found
    movzx eax, word [rsi + rcx*2]
    cmp ax, r14w
    je .found
    inc rcx
    jmp .scan
.found:
    mov rax, r14
    jmp .ret
.not_found:
    ; varovanie do uci_debug.log + fallback na prvy legalny tah
    lea rdi, [uci_log_bad_bm]
    mov esi, uci_log_bad_bm_len
    call uci_log_str
    test r15, r15
    jz .zero
    movzx rax, word [move_list]
    jmp .ret
.zero:
    xor rax, rax
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; uci_print_signed_number - vypise signed cislo z rax
; ============================================================
global uci_print_signed_number
uci_print_signed_number:
    test rax, rax
    jns .pos
    push rax
    lea rdi, [uci_minus]
    mov rdx, 1
    call write_str
    pop rax
    neg rax
.pos:
    call print_number
    ret

; ============================================================
; extract_pv - vytlaci celu PV z TT (oddelenie medzerami)
; Vstup: rdi = prvy tah (root best move)
; Pozor: volat az po skonceni searchu (pouziva make/unmake na
; realnej pozicii, undo_stack musi byt prazdny)
; ============================================================
extract_pv:
    push rbx
    push r12

    xor rbx, rbx            ; index do pv_moves
.loop:
    cmp rbx, [pv_moves_len]
    jge .done
    lea rax, [pv_moves]
    movzx r12, word [rax + rbx*2]

    ; vytlac "from"
    mov rax, r12
    and rax, 0x3F
    call square_to_str
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, square_str_buf
    mov rdx, 2
    syscall

    ; vytlac "to"
    mov rax, r12
    shr rax, 6
    and rax, 0x3F
    call square_to_str
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, square_str_buf
    mov rdx, 2
    syscall

    ; promocny znak (flags 1-4 = q r b n)
    mov rax, r12
    shr rax, 12
    cmp rax, FLAG_PROMO_Q
    jb .no_promo
    cmp rax, FLAG_PROMO_N
    ja .no_promo
    lea rcx, [pv_promo_chars]
    movzx eax, byte [rcx + rax - 1]
    mov [pv_char_buf], al
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [pv_char_buf]
    mov rdx, 1
    syscall
.no_promo:

    ; medzera
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [pv_space]
    mov rdx, 1
    syscall

    inc rbx
    jmp .loop
.done:
    pop r12
    pop rbx
    ret

; ============================================================
; uci_emit_info - vypise jeden info riadok
; Vstup: rdi = depth, rsi = time_ms, rdx = best_move
; ============================================================
uci_emit_info:
    push rbx
    push r12
    push r13

    mov r12, rdi
    mov r13, rsi
    mov rbx, rdx

    lea rdi, [uci_info_depth]
    call write_cstr
    mov rax, r12
    call print_number

    lea rdi, [uci_info_score]
    call write_cstr
    movsxd rax, dword [search_last_score]
    call uci_print_signed_number

    lea rdi, [uci_info_nodes]
    call write_cstr
    mov rax, [nodes_searched]
    call print_number

    lea rdi, [uci_info_time]
    call write_cstr
    mov rax, r13
    call print_number

    test rbx, rbx
    jz .nl

    lea rdi, [uci_info_pv]
    call write_cstr

    mov rdi, rbx
    call extract_pv

.nl:
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, msg_newline
    mov rdx, 1
    syscall

    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; uci_go - spracuje UCI 'go' (depth/time controls)
; ============================================================
uci_go:
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; reset limitov (cisty stav - ziadny sticky mode/times z predchadzajuceho go)
    mov byte [search_limits + 0], 0      ; mode: fixed depth
    movzx rax, byte [search_depth]
    mov byte [search_limits + 1], al     ; default depth
    mov byte [search_limits + 2], 0      ; movestogo 0 = fallback 30 v alloc
    xor rax, rax
    mov qword [search_limits + 8], rax
    mov qword [search_limits + 16], rax
    mov qword [search_limits + 24], rax
    mov qword [search_limits + 32], rax
    mov qword [search_limits + 40], rax
    mov qword [search_limits + 48], rax
    mov qword [search_limits + 56], rax
    mov qword [search_limits + 64], rax
    mov byte [uci_stop_flag], 0
    mov byte [uci_quit_flag], 0

    ; parsuj argumenty za 'go'
    mov rdi, 2
.go_loop:
    call uci_token
    cmp rax, -1
    je .after_parse
    test rbx, rbx
    jz .after_parse

    mov r15, rax               ; start aktualneho tokenu
    mov r14, rcx               ; index za aktualnym tokenom

    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel uci_str_depth]
    call uci_str_eq
    test rax, rax
    jnz .parse_depth

    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel uci_str_movetime]
    call uci_str_eq
    test rax, rax
    jnz .parse_movetime

    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel uci_str_wtime]
    call uci_str_eq
    test rax, rax
    jnz .parse_wtime

    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel uci_str_btime]
    call uci_str_eq
    test rax, rax
    jnz .parse_btime

    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel uci_str_winc]
    call uci_str_eq
    test rax, rax
    jnz .parse_winc

    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel uci_str_binc]
    call uci_str_eq
    test rax, rax
    jnz .parse_binc

    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel uci_str_movestogo]
    call uci_str_eq
    test rax, rax
    jnz .parse_movestogo

    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel uci_str_infinite]
    call uci_str_eq
    test rax, rax
    jnz .set_infinite

    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rel uci_str_ponder_kw]
    call uci_str_eq
    test rax, rax
    jnz .set_ponder

    mov rdi, r14
    jmp .go_loop

.parse_depth:
    mov rdi, r14
    call uci_token
    cmp rax, -1
    je .after_parse
    mov rdi, rax
    mov rsi, rbx
    call uci_parse_int
    test rax, rax
    jz .after_parse
    cmp rax, 64
    jle .depth_store
    mov rax, 64
.depth_store:
    mov byte [search_limits + 1], al
    mov rdi, rcx
    jmp .go_loop

.parse_movetime:
    mov rdi, r14
    call uci_token
    cmp rax, -1
    je .after_parse
    mov rdi, rax
    mov rsi, rbx
    call uci_parse_int
    test rax, rax
    jz .after_parse
    mov byte [search_limits + 0], 1
    mov qword [search_limits + 8], rax
    mov qword [search_limits + 56], rax
    mov qword [search_limits + 64], rax
    mov rdi, rcx
    jmp .go_loop

.parse_wtime:
    mov rdi, r14
    call uci_token
    cmp rax, -1
    je .after_parse
    mov rdi, rax
    mov rsi, rbx
    call uci_parse_int
    mov byte [search_limits + 0], 2
    mov qword [search_limits + 16], rax
    mov rdi, rcx
    jmp .go_loop

.parse_btime:
    mov rdi, r14
    call uci_token
    cmp rax, -1
    je .after_parse
    mov rdi, rax
    mov rsi, rbx
    call uci_parse_int
    mov byte [search_limits + 0], 2
    mov qword [search_limits + 24], rax
    mov rdi, rcx
    jmp .go_loop

.parse_winc:
    mov rdi, r14
    call uci_token
    cmp rax, -1
    je .after_parse
    mov rdi, rax
    mov rsi, rbx
    call uci_parse_int
    mov qword [search_limits + 32], rax
    mov rdi, rcx
    jmp .go_loop

.parse_binc:
    mov rdi, r14
    call uci_token
    cmp rax, -1
    je .after_parse
    mov rdi, rax
    mov rsi, rbx
    call uci_parse_int
    mov qword [search_limits + 40], rax
    mov rdi, rcx
    jmp .go_loop

.parse_movestogo:
    mov rdi, r14
    call uci_token
    cmp rax, -1
    je .after_parse
    mov rdi, rax
    mov rsi, rbx
    call uci_parse_int
    test rax, rax
    jz .after_parse
    cmp rax, 255
    jle .mtg_store
    mov rax, 255
.mtg_store:
    mov byte [search_limits + 2], al
    mov rdi, rcx
    jmp .go_loop

.set_infinite:
    mov byte [search_limits + 0], 3
    mov byte [search_limits + 1], 64
    mov qword [search_limits + 56], 0
    mov qword [search_limits + 64], 0
    mov rdi, r14
    jmp .go_loop

.set_ponder:
    mov byte [search_limits + 0], 4
    mov byte [uci_ponder], 1
    mov rdi, r14
    jmp .go_loop

.after_parse:
    movzx r12, byte [search_limits + 1]

    ; timed mody bez explicitneho depth skusia hlbsie hladanie
    movzx eax, byte [search_limits + 0]
    test eax, eax
    jz .after_depth_adjust
    movzx eax, byte [search_depth]
    cmp r12, rax
    jne .after_depth_adjust
    mov r12, 64
    mov byte [search_limits + 1], 64

.after_depth_adjust:
    ; zjednoduseny allocation pre time controls
    movzx eax, byte [search_limits + 0]
    cmp eax, 2
    jne .time_start
    call uci_alloc_time

.time_start:
    call uci_now_ms
    mov [search_limits + 48], rax

.search:
    cmp byte [uci_own_book], 0
    je .no_book
    cmp byte [book_mode], 0
    jne .think_book
    call book_lookup
    test rax, rax
    jnz .do_move
    jmp .no_book
.think_book:
    call book_pick_move
    test rax, rax
    jnz .do_move
.no_book:
    xor r13d, r13d            ; best_move
    xor r14d, r14d            ; best_depth
    mov r15, 1                ; current depth
    mov qword [uci_iter_dur], 0

.id_loop:
    cmp byte [uci_stop_flag], 0
    jne .id_done

    cmp r15, r12
    jg .id_done

    ; --- mode 2: soft/hard casove brany pred startom iteracie ---
    ; soft: ak uz minul soft limit, dalsiu iteraciu nezacname
    ; hard: nezacname iteraciu, ktora by s rezervou 2x posledna
    ;       iteracia (typicky rastie 2-2.5x na hlbku) precfuje hard limit
    cmp byte [search_limits + 0], 2
    jne .timegates_ok
    call uci_now_ms
    sub rax, [search_limits + 48]        ; elapsed
    cmp rax, [search_limits + 56]        ; > soft -> koncime
    jg .id_done
    mov rcx, [uci_iter_dur]
    add rcx, rcx
    add rcx, rax
    cmp rcx, [search_limits + 64]        ; elapsed + 2*dur > hard -> koncime
    jg .id_done
.timegates_ok:
    call uci_now_ms
    mov [uci_iter_start], rax

    ; --- ASPIRATION WINDOW: pre depth >= 5 okolo predch. skore ---
    mov dword [asp_use], 0
    mov dword [asp_retry], 0
    cmp r15, 5
    jl .asp_ready
    mov eax, [search_last_score]
    cmp eax, MATE_SCORE - 1000   ; pri mat/hornych skorach plne okno
    jge .asp_ready
    cmp eax, -MATE_SCORE + 1000
    jle .asp_ready
    mov dword [asp_delta], 50
    sub eax, 50
    mov [asp_alpha], eax
    mov eax, [search_last_score]
    add eax, 50
    mov [asp_beta], eax
    mov dword [asp_use], 1
.asp_ready:
    mov rdi, r15
    call search_best_move

    cmp byte [uci_stop_flag], 0
    jne .id_done

    test rax, rax
    jz .id_done

    ; --- aspiration retry pri fail-low / fail-high ---
    cmp dword [asp_use], 0
    je .asp_ok
    mov ecx, [search_last_score]
    cmp ecx, [asp_alpha]
    jle .asp_widen_low
    cmp ecx, [asp_beta]
    jge .asp_widen_high
    jmp .asp_ok
.asp_widen_low:
    ; pozor: rax = bestmove z search_best_move, musi prezit do .asp_ok!
    mov edx, [asp_delta]
    shl edx, 2                  ; delta *= 4
    mov [asp_delta], edx
    mov ecx, [asp_alpha]
    sub ecx, edx
    cmp ecx, -INF
    jge .wl_store
    mov ecx, -INF
.wl_store:
    mov [asp_alpha], ecx
    jmp .asp_again
.asp_widen_high:
    mov edx, [asp_delta]
    shl edx, 2
    mov [asp_delta], edx
    mov ecx, [asp_beta]
    add ecx, edx
    cmp ecx, INF
    jle .wh_store
    mov ecx, INF
.wh_store:
    mov [asp_beta], ecx
.asp_again:
    inc dword [asp_retry]
    cmp dword [asp_retry], 4
    jl .asp_ready
    ; po 4 retry berieme posledny vysledok (fail-soft)
.asp_ok:
    mov r13, rax
    mov r14, r15

    ; trvanie iteracie (vratane aspiration retry) pre hard gate
    call uci_now_ms
    sub rax, [uci_iter_start]
    mov [uci_iter_dur], rax

    call uci_now_ms
    sub rax, [search_limits + 48]
    mov rdi, r15
    mov rsi, rax
    mov rdx, r13
    call uci_emit_info

    inc r15
    jmp .id_loop

.id_done:
    test r13, r13
    jnz .id_have_best
    mov rdi, 1
    call search_best_move
    mov r13, rax
    mov r14, 1
    call uci_now_ms
    sub rax, [search_limits + 48]
    mov rdi, r14
    mov rsi, rax
    mov rdx, r13
    call uci_emit_info

.id_have_best:
    mov rax, r13
    call uci_sanitize_best    ; poistka proti nelegalnemu bestmove

.do_move:
    mov r12, rax

    ; --- log "<< bestmove <tah>" (0000 ak nulty tah) ---
    test r12, r12
    jz .log_bm_null
    mov rax, r12
    and rax, 0x3F
    call square_to_str
    mov ax, [square_str_buf]
    mov [uci_log_move_buf], ax
    mov rax, r12
    shr rax, 6
    and rax, 0x3F
    call square_to_str
    mov ax, [square_str_buf]
    mov [uci_log_move_buf + 2], ax
    mov r13d, 4                 ; r13 uz je mrtvy (best move je v r12)
    mov rax, r12
    shr rax, 12
    cmp rax, FLAG_PROMO_Q
    jb .log_bm_go
    cmp rax, FLAG_PROMO_N
    ja .log_bm_go
    lea rdx, [pv_promo_chars]
    movzx edx, byte [rdx + rax - 1]
    mov [uci_log_move_buf + 4], dl
    mov r13d, 5
.log_bm_go:
    lea rdi, [uci_log_bm_prefix]
    mov esi, uci_log_bm_prefix_len
    call uci_log_str
    lea rdi, [uci_log_move_buf]
    mov esi, r13d
    call uci_log_str
    lea rdi, [msg_newline]
    mov esi, 1
    call uci_log_str
    jmp .log_bm_done
.log_bm_null:
    lea rdi, [uci_log_bm_null]
    mov esi, uci_log_bm_null_len
    call uci_log_str
.log_bm_done:

    lea rdi, [uci_bestmove]
    mov rdx, uci_bestmove_len
    call write_str

    ; nulty tah (mat/pat): UCI konvencia "bestmove 0000"
    test r12, r12
    jnz .bm_have_move
    lea rdi, [uci_str_0000]
    mov rdx, 4
    call write_str
    jmp .bm_no_promo
.bm_have_move:

    mov rax, r12
    and rax, 0x3F
    call square_to_str
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, square_str_buf
    mov rdx, 2
    syscall

    mov rax, r12
    shr rax, 6
    and rax, 0x3F
    call square_to_str
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, square_str_buf
    mov rdx, 2
    syscall

    ; promocny znak (flags 1-4 = q r b n)
    mov rax, r12
    shr rax, 12
    cmp rax, FLAG_PROMO_Q
    jb .bm_no_promo
    cmp rax, FLAG_PROMO_N
    ja .bm_no_promo
    lea rcx, [pv_promo_chars]
    movzx eax, byte [rcx + rax - 1]
    mov [pv_char_buf], al
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [pv_char_buf]
    mov rdx, 1
    syscall
.bm_no_promo:

    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, msg_newline
    mov rdx, 1
    syscall

    mov byte [uci_ponder], 0

    ; ak prislo 'quit' pocas searchu, proces konci hned po bestmove
    cmp byte [uci_quit_flag], 0
    je .no_quit_exit
    mov rax, SYS_EXIT
    xor edi, edi
    syscall
.no_quit_exit:

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; uci_parse_int - prevedie token na cislo
; Vstup: rdi = token start, rsi = token len
; Vystup: rax = cislo, 0 ak chyba
; ============================================================
uci_parse_int:
    push rbx
    push rcx
    xor rax, rax
    xor rcx, rcx
.loop:
    cmp rcx, rsi
    jge .done
    movzx rbx, byte [move_buf + rdi + rcx]
    sub rbx, '0'
    cmp rbx, 9
    ja .error
    imul rax, 10
    add rax, rbx
    inc rcx
    jmp .loop
.error:
    xor rax, rax
.done:
    pop rcx
    pop rbx
    ret

; ============================================================
; input_read_byte - precita jeden bajt stdin (najprv z input_pend)
; Vystup: al = bajt, rax = -1 ak EOF
; Nici len caller-saved registre (rax, rcx, rdx, rsi, r11)
; ============================================================
input_read_byte:
    mov rax, [input_pend_len]
    test rax, rax
    jz .from_stdin

    ; vyber prvy bajt z input_pend a zvysok posun do lava
    lea rsi, [input_pend]
    movzx r11d, byte [rsi]
    mov rcx, 1
.shift:
    cmp rcx, rax
    jae .shift_done
    mov dl, [rsi + rcx]
    mov [rsi + rcx - 1], dl
    inc rcx
    jmp .shift
.shift_done:
    dec rax
    mov [input_pend_len], rax
    movzx eax, r11b
    ret

.from_stdin:
    mov rax, SYS_READ
    xor edi, edi
    lea rsi, [input_pend]        ; buffer je prazdny, citame rovno do neho
    mov edx, 1
    syscall
    cmp rax, 1
    jne .eof
    movzx eax, byte [input_pend]
    ret

.eof:
    mov rax, -1
    ret

; ============================================================
; uci_read_line - nacita jeden riadok do move_buf
; Vystup: rax = dlzka riadku (bez newline), -1 ak EOF
; ============================================================
uci_read_line:
    push rbx
    push r12
    xor r12, r12

.read_loop:
    call input_read_byte
    cmp rax, -1
    je .eof
    mov [move_buf + r12], al
    cmp al, 10
    je .done
    inc r12
    cmp r12, 4095
    jl .read_loop

.consume:
    call input_read_byte
    cmp rax, -1
    je .done
    cmp al, 10
    je .done
    jmp .consume

.eof:
    mov rax, -1
    pop r12
    pop rbx
    ret

.done:
    mov [move_buf_len], r12
    mov byte [move_buf + r12], 0
    mov rax, r12
    pop r12
    pop rbx
    ret

; ============================================================
; uci_loop - hlavna UCI slucka
; ============================================================
uci_loop:
    push rbx
    push r12
    ; startovaci marker do logu - diagnostika: bezi nova binarka + kde loguje
    lea rdi, [uci_log_start]
    mov esi, uci_log_start_len
    call uci_log_str

.loop:
    call uci_read_line
    cmp rax, -1
    je .done

    ; log prijateho riadku: ">> <riadok>"
    lea rdi, [uci_log_prefix_in]
    mov esi, 3
    call uci_log_str
    lea rdi, [move_buf]
    mov rsi, [move_buf_len]
    call uci_log_str
    lea rdi, [msg_newline]
    mov esi, 1
    call uci_log_str

    ; prazdny riadok
    mov r12, [move_buf_len]
    test r12, r12
    jz .loop

    ; prvy token
    mov rdi, 0
    call uci_token
    cmp rax, -1
    je .loop
    mov r12, rax          ; start tokenu (rbx = dlzka, uci_str_eq ho zachova)

    ; 'quit'
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_quit]
    call uci_str_eq
    test rax, rax
    jnz .done

    ; 'isready'
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_isready]
    call uci_str_eq
    test rax, rax
    jnz .isready

    ; 'uci'
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_uci]
    call uci_str_eq
    test rax, rax
    jnz .uci

    ; 'position'
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_position]
    call uci_str_eq
    test rax, rax
    jnz .position

    ; 'go'
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_go]
    call uci_str_eq
    test rax, rax
    jnz .go

    ; 'setoption'
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_setoption]
    call uci_str_eq
    test rax, rax
    jnz .setoption

    ; 'ucinewgame'
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_ucinewgame]
    call uci_str_eq
    test rax, rax
    jnz .ucinewgame

    ; 'stop'
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_stop]
    call uci_str_eq
    test rax, rax
    jnz .stop

    ; 'ponderhit'
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_ponderhit]
    call uci_str_eq
    test rax, rax
    jnz .ponderhit

    ; 'analyze' (non-standard helper)
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_analyze]
    call uci_str_eq
    test rax, rax
    jnz .analyze

    ; 'suite' (non-standard helper)
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_suite]
    call uci_str_eq
    test rax, rax
    jnz .suite

    ; 'tbtest' (non-standard helper)
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_tbtest]
    call uci_str_eq
    test rax, rax
    jnz .tbtest

    ; 'bbtest' (non-standard helper, bitboard scaffold validation)
    mov rdi, r12
    mov rsi, rbx
    lea rdx, [rel .str_bbtest]
    call uci_str_eq
    test rax, rax
    jnz .bbtest

    ; neznamy prikaz - vypiseme len ak nie je prazdny
    lea rdi, [uci_unknown]
    call write_cstr
    jmp .loop

.isready:
    lea rdi, [uci_ready]
    mov rdx, uci_ready_len
    call write_str
    jmp .loop

.uci:
    lea rdi, [uci_id_name]
    call write_cstr
    lea rdi, [uci_id_author]
    call write_cstr
    lea rdi, [uci_opt_hash]
    call write_cstr
    lea rdi, [uci_opt_ownbook]
    call write_cstr
    lea rdi, [uci_opt_ponder]
    call write_cstr
    lea rdi, [uci_opt_syzygy]
    call write_cstr
    lea rdi, [uci_opt_syzygy_depth]
    call write_cstr
    lea rdi, [uci_opt_overhead]
    call write_cstr
    lea rdi, [uci_ok]
    call write_cstr
    jmp .loop

.position:
    call uci_position
    jmp .loop

.go:
    call uci_go
    jmp .loop

.setoption:
    mov rdi, 9
    call uci_token
    cmp rax, -1
    je .loop
    mov rdi, rax
    call uci_setoption
    jmp .loop

.ucinewgame:
    call init_board
    call init_hash_history
    call record_hash
    call pgn_new_game         ; uzavrie PGN sekciu predchádzajúcej partie
    mov qword [uci_pgn_ply], 0
    jmp .loop

.stop:
    mov byte [uci_stop_flag], 1
    jmp .loop

.ponderhit:
    mov byte [uci_ponder], 0
    jmp .loop

.analyze:
    call suite_cmd_uci
    jmp .loop

.suite:
    call suite_cmd_uci
    jmp .loop

.tbtest:
    call tb_piece_count
    mov r12, rax
    call tb_probe_wdl
    mov rbx, rax
    call tb_probe_dtz
    mov r13, rax

    lea rdi, [uci_tbtest_prefix]
    call write_cstr
    mov rax, r12
    call print_number
    lea rdi, [uci_tbtest_wdl]
    call write_cstr
    mov rax, rbx
    call print_number
    lea rdi, [uci_tbtest_dtz]
    call write_cstr
    mov rax, r13
    call print_number
    lea rdi, [uci_tbtest_map]
    call write_cstr
    mov rax, [tb_map_size]
    call print_number
    lea rdi, [uci_tbtest_path]
    call write_cstr
    lea rdi, [tb_file_path]
    call write_cstr
    lea rdi, [uci_tbtest_wdl_payload]
    call write_cstr
    movzx rax, byte [tb_wdl_payload_probe_byte]
    call print_number
    lea rdi, [uci_tbtest_dtz_payload]
    call write_cstr
    movzx rax, byte [tb_dtz_payload_probe_byte]
    call print_number
    lea rdi, [msg_newline]
    mov rdx, 1
    call write_str
    jmp .loop

.bbtest:
    call bb_validate_position
    mov r12, rax
    lea rdi, [uci_bbtest_prefix]
    call write_cstr
    mov rax, r12
    call print_number
    lea rdi, [msg_newline]
    mov rdx, 1
    call write_str
    jmp .loop

.done:
    call pgn_quit             ; uzavrie partiu a zavrie games.pgn
    pop r12
    pop rbx
    ret

.str_quit:    db "quit", 0
.str_isready: db "isready", 0
.str_uci:     db "uci", 0
.str_position:db "position", 0
.str_go:      db "go", 0
.str_setoption: db "setoption", 0
.str_ucinewgame: db "ucinewgame", 0
.str_stop:    db "stop", 0
.str_ponderhit: db "ponderhit", 0
.str_analyze: db "analyze", 0
.str_suite:   db "suite", 0
.str_tbtest:  db "tbtest", 0
.str_bbtest:  db "bbtest", 0