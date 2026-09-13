; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; panel.asm - bocny panel s historiou, zajatymi figurkami a knihou
; ============================================================

%include "chess.inc"

DEFAULT REL

section .data

PANEL_LEFT  equ 22
PANEL_PAD   equ (PANEL_LEFT - 18)
PANEL_INNER equ 22

panel_border:      db "  +----------------------+", 0
panel_dash_text:   db "-", 0

global msg_status_white, msg_status_white_len
global msg_status_black, msg_status_black_len
global msg_mode_engine_white, msg_mode_engine_white_len
global msg_mode_engine_black, msg_mode_engine_black_len
global msg_mode_both, msg_mode_both_len
global msg_mode_none, msg_mode_none_len
global msg_mode_human, msg_mode_human_len
global panel_empty

panel_empty:     db 0

msg_status_white: db 27,"[96mWHITE to move",27,"[0m", 0
msg_status_white_len equ $ - msg_status_white - 1
msg_status_black: db 27,"[96mBLACK to move",27,"[0m", 0
msg_status_black_len equ $ - msg_status_black - 1

msg_mode_engine_white: db " ",27,"[90m| 1-Player | You play: Black",27,"[0m", 0
msg_mode_engine_white_len equ $ - msg_mode_engine_white - 1
msg_mode_engine_black: db " ",27,"[90m| 1-Player | You play: White",27,"[0m", 0
msg_mode_engine_black_len equ $ - msg_mode_engine_black - 1
msg_mode_both: db " ",27,"[90m| Mode: Engine vs Engine",27,"[0m", 0
msg_mode_both_len equ $ - msg_mode_both - 1
msg_mode_none: db " ",27,"[90m| Mode: 2-Players (Local)",27,"[0m", 0
msg_mode_none_len equ $ - msg_mode_none - 1
msg_mode_human: db " ",27,"[90m| Mode: Human",27,"[0m", 0
msg_mode_human_len equ $ - msg_mode_human - 1

msg_status_white_sk: db 27,"[96mBIELY na tahu",27,"[0m", 0
msg_status_white_sk_len equ $ - msg_status_white_sk - 1
msg_status_black_sk: db 27,"[96mCIERNY na tahu",27,"[0m", 0
msg_status_black_sk_len equ $ - msg_status_black_sk - 1

msg_mode_engine_white_sk: db " ",27,"[90m| 1-Hrac | Hras: Cierne",27,"[0m", 0
msg_mode_engine_white_sk_len equ $ - msg_mode_engine_white_sk - 1
msg_mode_engine_black_sk: db " ",27,"[90m| 1-Hrac | Hras: Biele",27,"[0m", 0
msg_mode_engine_black_sk_len equ $ - msg_mode_engine_black_sk - 1
msg_mode_both_sk: db " ",27,"[90m| Mod: Engine vs Engine",27,"[0m", 0
msg_mode_both_sk_len equ $ - msg_mode_both_sk - 1
msg_mode_none_sk: db " ",27,"[90m| Mod: 2-Hraci (Local)",27,"[0m", 0
msg_mode_none_sk_len equ $ - msg_mode_none_sk - 1

section .text

global clear_history, record_move, book_lookup_all, print_panel_line, print_status

extern move_history, move_history_len
extern captured_by_white, captured_by_white_len
extern captured_by_black, captured_by_black_len
extern book_moves, book_moves_len
extern pv_moves, pv_moves_len
extern lang_txt_panel_book, lang_txt_panel_pv
extern book_ptrs, book_sizes, book_count
extern position_hash
extern captured_piece, side, engine_side, board_flip
extern lang_is_en
extern lang_txt_menu_title, lang_txt_status_white, lang_txt_status_black
extern lang_txt_mode_engine_white, lang_txt_mode_engine_black, lang_txt_mode_both, lang_txt_mode_none
extern lang_txt_panel_white_took, lang_txt_panel_black_took, lang_txt_panel_help_move, lang_txt_panel_help_flip, lang_txt_panel_help_help, lang_txt_panel_help_summary
extern piece_chars
extern print_newline, square_to_str, write_cstr, square_str_buf

; ============================================================
; print_pad - vypise PANEL_PAD medzier
; ============================================================
print_pad:
    push rax
    push r13
    mov r13, PANEL_PAD
    test r13, r13
    jz .done
.pad_loop:
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, .space
    mov rdx, 1
    syscall
    dec r13
    jnz .pad_loop
.done:
    pop r13
    pop rax
    ret
.space: db ' '

; ============================================================
; panel_buf_clear - pripravi line buffer vyplneny medzerami
; ============================================================
panel_buf_clear:
    push rax
    push rcx
    push rdi
    lea rdi, [panel_line_buf]
    mov rcx, PANEL_INNER
    mov al, ' '
    rep stosb
    mov byte [rdi], 0
    mov qword [panel_line_pos], 0
    pop rdi
    pop rcx
    pop rax
    ret

; ============================================================
; panel_buf_append_char - prida znak do line buffra
; Vstup: al = znak
; ============================================================
panel_buf_append_char:
    push rbx
    mov rbx, [panel_line_pos]
    cmp rbx, PANEL_INNER
    jae .done
    mov [panel_line_buf + rbx], al
    inc rbx
    mov [panel_line_pos], rbx
.done:
    pop rbx
    ret

; ============================================================
; panel_buf_append_cstr - prida C-string do line buffra
; Vstup: rsi = ukazatel na retazec
; ============================================================
panel_buf_append_cstr:
    push rax
    push rbx
    xor rbx, rbx
.loop:
    mov al, [rsi + rbx]
    test al, al
    jz .done
    call panel_buf_append_char
    inc rbx
    jmp .loop
.done:
    pop rbx
    pop rax
    ret

; ============================================================
; panel_buf_append_number - prida cislo v rax do line buffra
; ============================================================
panel_buf_append_number:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi

    mov rdi, panel_num_buf + 15
    mov byte [rdi], 0
    mov rbx, 10
    mov rcx, rax
.div_loop:
    xor rdx, rdx
    mov rax, rcx
    div rbx
    mov rcx, rax
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rcx, rcx
    jnz .div_loop

    mov rsi, rdi
    call panel_buf_append_cstr

    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; print_move_coords - vypise tah vo formate e2e4 (bez newline)
; Vstup: ax = 16-bitovy tah
; ============================================================
print_move_coords:
    push rax
    push rbx
    mov bx, ax

    movzx rax, bx
    and rax, 0x3F
    call square_to_str
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, square_str_buf
    mov rdx, 2
    syscall

    movzx rax, bx
    shr rax, 6
    and rax, 0x3F
    call square_to_str
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, square_str_buf
    mov rdx, 2
    syscall

    pop rbx
    pop rax
    ret

; ============================================================
; panel_buf_append_move_coords - prida tah vo formate e2e4 do line buffra
; Vstup: ax = 16-bitovy tah
; ============================================================
panel_buf_append_move_coords:
    push rax
    push rbx
    push rsi
    mov bx, ax

    movzx rax, bx
    and rax, 0x3F
    call square_to_str
    lea rsi, [square_str_buf]
    call panel_buf_append_cstr

    movzx rax, bx
    shr rax, 6
    and rax, 0x3F
    call square_to_str
    lea rsi, [square_str_buf]
    call panel_buf_append_cstr

.done:
    pop rsi
    pop rbx
    pop rax
    ret

; ============================================================
; build_captured_line - vysklada riadok so zajatymi figurkami
; Vstup: rdi = label, rsi = pole figuriek, rdx = pocet
; ============================================================
build_captured_line:
    push rax
    push rbx
    push r13
    push r14
    push rsi
    push rdi

    call panel_buf_clear
    mov r14, rsi
    mov rsi, rdi
    call panel_buf_append_cstr
    mov al, ' '
    call panel_buf_append_char

    mov r13, rdx
    test r13, r13
    jnz .loop
    mov rsi, panel_dash_text
    call panel_buf_append_cstr
    jmp .done

.loop:
    xor rbx, rbx
.next:
    cmp rbx, r13
    jge .done
    movzx rax, byte [r14 + rbx]
    mov rcx, rax
    and rcx, COLOR_MASK
    and rax, PIECE_MASK
    add rax, rcx
    mov al, [piece_chars + rax]
    call panel_buf_append_char
    inc rbx
    cmp rbx, r13
    jge .done
    mov al, ' '
    call panel_buf_append_char
    jmp .next

.done:
    pop rdi
    pop rsi
    pop r14
    pop r13
    pop rbx
    pop rax
    ret

; ============================================================
; build_move_history_line - vysklada jeden scrollovany riadok historie
; Vstup: rdi = 0..3
; ============================================================
build_move_history_line:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    call panel_buf_clear
    mov rbx, rdi
    mov rcx, [move_history_len]
    mov rax, rcx
    add rax, 1
    shr rax, 1
    mov rdx, rax              ; fullmove count
    cmp rdx, 0
    jne .have_moves
    test rbx, rbx
    jne .done
    mov rsi, panel_dash_text
    call panel_buf_append_cstr
    jmp .done

.have_moves:
    xor rax, rax
    cmp rdx, 4
    jle .start_ok
    mov rax, rdx
    sub rax, 4
.start_ok:
    add rax, rbx
    cmp rax, rdx
    jae .done

    mov r8, rax               ; fullmove index 0-based
    mov rdi, r8
    inc rdi
    mov rax, rdi
    call panel_buf_append_number
    mov al, '.'
    call panel_buf_append_char
    mov al, ' '
    call panel_buf_append_char

    lea rsi, [move_history]
    lea r9, [r8*4]
    movzx rax, word [rsi + r9]
    call panel_buf_append_move_coords

    ; cierny tah existuje len ak je pocet polotahov > 2*idx+1
    lea rax, [r8*2]
    inc rax
    cmp rax, rcx
    jae .done
    mov al, ' '
    call panel_buf_append_char
    movzx rax, word [rsi + r9 + 2]
    call panel_buf_append_move_coords

.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; print_panel_buffer_line - vypise boxovany riadok z panel_line_buf
; ============================================================
print_panel_buffer_line:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    call print_pad
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, .left
    mov rdx, 3
    syscall
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [panel_line_buf]
    mov rdx, PANEL_INNER
    syscall
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, .right
    mov rdx, 1
    syscall

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.left:  db ' ',' ','|'
.right: db '|'

; ============================================================
; print_panel_blank - vypise prazdny boxovany riadok
; ============================================================
print_panel_blank:
    call panel_buf_clear
    jmp print_panel_buffer_line

; ============================================================
; panel_status_char - vypise jeden znak zo AL
; ============================================================
panel_status_char:
    push rax
    push rdx
    mov [panel_tmp_char], al
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, panel_tmp_char
    mov rdx, 1
    syscall
    pop rdx
    pop rax
    ret

; ============================================================
; build_center_title_line - vystredi nazov panelu
; ============================================================
build_center_title_line:
    push rax
    push rbx
    push rcx
    push rsi

    call panel_buf_clear
    lea rsi, [lang_txt_menu_title]
    xor rcx, rcx
.len_loop:
    cmp byte [rsi + rcx], 0
    je .have_len
    inc rcx
    jmp .len_loop
.have_len:
    mov rax, PANEL_INNER
    sub rax, rcx
    shr rax, 1
    mov [panel_line_pos], rax
    call panel_buf_append_cstr

    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; print_panel_line - vypise jeden display riadok panelu vedla dosky
; Vstup: rdi = cislo riadku 0..9
; ============================================================
print_panel_line:
    push rdi

    cmp rdi, 0
    je .border
    cmp rdi, 1
    je .title
    cmp rdi, 2
    je .white
    cmp rdi, 3
    je .black
    cmp rdi, 4
    je .border
    cmp rdi, 5
    je .move0
    cmp rdi, 6
    je .move1
    cmp rdi, 7
    je .move2
    cmp rdi, 8
    je .move3
    cmp rdi, 9
    je .help1
    cmp rdi, 10
    je .book
    cmp rdi, 11
    je .pvline
    jmp .blank

.border:
    call print_pad
    lea rdi, [panel_border]
    call write_cstr
    jmp .done

.title:
    call build_center_title_line
    call print_panel_buffer_line
    jmp .done

.white:
    lea rdi, [lang_txt_panel_white_took]
    lea rsi, [captured_by_white]
    mov rdx, [captured_by_white_len]
    call build_captured_line
    call print_panel_buffer_line
    jmp .done

.black:
    lea rdi, [lang_txt_panel_black_took]
    lea rsi, [captured_by_black]
    mov rdx, [captured_by_black_len]
    call build_captured_line
    call print_panel_buffer_line
    jmp .done

.move0:
    xor rdi, rdi
    call build_move_history_line
    call print_panel_buffer_line
    jmp .done
.move1:
    mov rdi, 1
    call build_move_history_line
    call print_panel_buffer_line
    jmp .done
.move2:
    mov rdi, 2
    call build_move_history_line
    call print_panel_buffer_line
    jmp .done
.move3:
    mov rdi, 3
    call build_move_history_line
    call print_panel_buffer_line
    jmp .done

.book:
    call build_book_line
    call print_panel_buffer_line
    jmp .done
.pvline:
    call build_pv_line
    call print_panel_buffer_line
    jmp .done

.help1:
    call panel_buf_clear
    lea rsi, [lang_txt_panel_help_summary]
    call panel_buf_append_cstr
    call print_panel_buffer_line
    jmp .done

.blank:
    call print_panel_blank

.done:
    pop rdi
    ret

; ============================================================
; build_book_line - vysklada riadok s kniznymi tahmi
; ============================================================
build_book_line:
    push rax
    push rbx
    push rcx
    push rsi

    call panel_buf_clear
    lea rsi, [lang_txt_panel_book]
    call panel_buf_append_cstr
    mov al, ' '
    call panel_buf_append_char

    mov rcx, [book_moves_len]
    test rcx, rcx
    jnz .loop
    mov rsi, panel_dash_text
    call panel_buf_append_cstr
    jmp .done
.loop:
    xor rbx, rbx
.next:
    cmp rbx, rcx
    jge .done
    lea rax, [book_moves]
    movzx rax, word [rax + rbx*2]
    call panel_buf_append_move_coords
    inc rbx
    cmp rbx, rcx
    jge .done
    mov al, ' '
    call panel_buf_append_char
    jmp .next
.done:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; build_pv_line - vysklada riadok s PV z posledneho searchu
; ============================================================
build_pv_line:
    push rax
    push rbx
    push rcx
    push rsi

    call panel_buf_clear
    lea rsi, [lang_txt_panel_pv]
    call panel_buf_append_cstr
    mov al, ' '
    call panel_buf_append_char

    mov rcx, [pv_moves_len]
    test rcx, rcx
    jnz .loop
    mov rsi, panel_dash_text
    call panel_buf_append_cstr
    jmp .done
.loop:
    xor rbx, rbx
.next:
    cmp rbx, rcx
    jge .done
    lea rax, [pv_moves]
    movzx rax, word [rax + rbx*2]
    call panel_buf_append_move_coords
    inc rbx
    cmp rbx, rcx
    jge .done
    mov al, ' '
    call panel_buf_append_char
    jmp .next
.done:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; clear_history - vynuluje historiu a zajate figurky
; ============================================================
clear_history:
    push rax
    mov qword [move_history_len], 0
    mov qword [captured_by_white_len], 0
    mov qword [captured_by_black_len], 0
    mov qword [book_moves_len], 0
    mov qword [pv_moves_len], 0
    pop rax
    ret

; ============================================================
; record_move - zapise tah a pripadnu zajatu figurku
; Vstup: ax = 16-bitovy tah
; ============================================================
record_move:
    push rax
    push rbx
    push rcx
    push rdx

    mov rbx, [move_history_len]
    cmp rbx, 512
    jge .done
    lea rcx, [move_history]
    mov [rcx + rbx*2], ax
    inc rbx
    mov [move_history_len], rbx

    movzx rdx, byte [captured_piece]
    test rdx, rdx
    jz .done

    ; po pridani: neparny pocet = biely prave tahol
    test rbx, 1
    jnz .white_capture

    mov rcx, [captured_by_black_len]
    cmp rcx, 32
    jge .done
    lea rax, [captured_by_black]
    mov [rax + rcx], dl
    inc rcx
    mov [captured_by_black_len], rcx
    jmp .done

.white_capture:
    mov rcx, [captured_by_white_len]
    cmp rcx, 32
    jge .done
    lea rax, [captured_by_white]
    mov [rax + rcx], dl
    inc rcx
    mov [captured_by_white_len], rcx

.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; book_lookup_all - najde vsetky knizne tahy pre aktualnu poziciu
; Naplni book_moves[] a book_moves_len.
; ============================================================
book_lookup_all:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    mov qword [book_moves_len], 0

    mov r14, [book_count]
    test r14, r14
    jz .done

    mov r13, [position_hash]
    xor r12, r12

.book_loop:
    cmp r12, r14
    jge .done

    lea rsi, [book_ptrs]
    mov rdi, [rsi + r12*8]
    lea rsi, [book_sizes]
    mov rcx, [rsi + r12*8]
    xor rbx, rbx

.entry_loop:
    cmp rbx, rcx
    jge .next_book

    cmp r13, qword [rdi + rbx]
    jne .next_entry

    movzx rax, word [rdi + rbx + 8]
    mov rdx, [book_moves_len]
    cmp rdx, 64
    jge .done
    lea rsi, [book_moves]
    mov [rsi + rdx*2], ax
    inc rdx
    mov [book_moves_len], rdx

.next_entry:
    add rbx, 10
    jmp .entry_loop

.next_book:
    inc r12
    jmp .book_loop

.done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; print_status - vypise riadok so stranou na tahu a rezimom
; ============================================================
print_status:
    push rax
    push rbx
    push rcx

    cmp byte [side], 0
    je .white
    lea rdi, [lang_txt_status_black]
    jmp .mode
.white:
    lea rdi, [lang_txt_status_white]

.mode:
    call write_cstr

    movzx rcx, byte [engine_side]
    cmp rcx, 0
    je .mode_w
    cmp rcx, 1
    je .mode_b
    cmp rcx, 2
    je .mode_2
    cmp rcx, 3
    je .mode_3
    jmp .newline

.mode_w:
    lea rdi, [lang_txt_mode_engine_white]
    jmp .write_mode
.mode_b:
    lea rdi, [lang_txt_mode_engine_black]
    jmp .write_mode
.mode_2:
    lea rdi, [lang_txt_mode_both]
    jmp .write_mode
.mode_3:
    lea rdi, [lang_txt_mode_none]
    jmp .write_mode
.write_mode:
    push rdi
    mov al, ' '
    call panel_status_char
    mov al, '|'
    call panel_status_char
    mov al, ' '
    call panel_status_char
    pop rdi
    call write_cstr

.newline:
    call print_newline

    pop rcx
    pop rbx
    pop rax
    ret

section .bss

panel_num_buf:  resb 16
panel_tmp_char: resb 1
panel_line_buf: resb 32
panel_line_pos: resq 1