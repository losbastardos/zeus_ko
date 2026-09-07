; ============================================================
; io.asm - vstup/vystup, pomocne tlaciarne
; ============================================================

%include "chess.inc"

DEFAULT REL

section .text

global print_title, print_prompt, print_newline, print_number
global read_move, print_move, print_move_list, square_to_str
global is_valid_file, is_valid_rank

extern move_buf, move_buf_len, move_list, move_count
extern perft_depth
extern msg_title, msg_title_len
extern msg_move_count, msg_move_count_len
extern msg_newline
extern square_str_buf, num_buf
extern lang_txt_prompt_move, lang_txt_prompt_invalid_input
extern write_cstr

; ============================================================
; print_title
; ============================================================
print_title:
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, msg_title
    mov rdx, msg_title_len
    syscall
    ret

; ============================================================
; print_prompt
; ============================================================
print_prompt:
    lea rdi, [lang_txt_prompt_move]
    call write_cstr
    ret

; ============================================================
; print_newline
; ============================================================
print_newline:
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, msg_newline
    mov rdx, 1
    syscall
    ret

; ============================================================
; print_number - vypise cislo v rax
; ============================================================
print_number:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi

    mov rcx, 10
    lea rsi, [num_buf + 15]
    mov byte [rsi], 0

.conv_loop:
    xor rdx, rdx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .conv_loop

    lea rax, [num_buf + 15]
    sub rax, rsi
    mov rdx, rax

    mov rax, SYS_WRITE
    mov rdi, STDOUT
    syscall

    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================
; read_move - nacita jeden riadok zo stdin
; Vystup: rax = 0 (OK), 1 (exit/koniec), 2 (neplatny vstup)
; ============================================================
read_move:
    push rbx
    push r12
    push r13

    xor r12, r12

.read_loop:
    mov rax, SYS_READ
    mov rdi, STDIN
    lea rsi, [move_buf + r12]
    mov rdx, 1
    syscall
    cmp rax, 1
    jne .got_line

    movzx rbx, byte [move_buf + r12]
    cmp rbx, 10
    je .got_line

    inc r12
    cmp r12, 31
    jl .read_loop

    ; buffer plny, zozerie zvysok riadku
.consume:
    mov rax, SYS_READ
    mov rdi, STDIN
    lea rsi, [move_buf + 31]
    mov rdx, 1
    syscall
    cmp rax, 1
    jne .got_line
    movzx rbx, byte [move_buf + 31]
    cmp rbx, 10
    je .got_line
    jmp .consume

.got_line:
    mov [move_buf_len], r12
    test r12, r12
    jz .invalid

    mov al, [move_buf]
    cmp al, 'e'
    je .check_exit
    cmp al, 'q'
    je .check_quit
    cmp al, 'l'
    je .check_list
    cmp al, 'f'
    je .check_flip
    cmp al, 'p'
    je .check_perft
    cmp al, 'g'
    je .check_gfx_or_go
    cmp al, 't'
    je .check_text
    cmp al, 'n'
    je .check_new
    cmp al, 'u'
    je .check_uci

.validate_move:
    cmp r12, 4
    jne .invalid

    movzx rax, byte [move_buf+0]
    call is_valid_file
    test rax, rax
    jz .invalid
    movzx rax, byte [move_buf+1]
    call is_valid_rank
    test rax, rax
    jz .invalid
    movzx rax, byte [move_buf+2]
    call is_valid_file
    test rax, rax
    jz .invalid
    movzx rax, byte [move_buf+3]
    call is_valid_rank
    test rax, rax
    jz .invalid

    xor rax, rax
    jmp .done

.check_exit:
    cmp r12, 4
    jne .validate_move
    cmp byte [move_buf+1], 'x'
    jne .validate_move
    cmp byte [move_buf+2], 'i'
    jne .validate_move
    cmp byte [move_buf+3], 't'
    jne .validate_move
    jmp .exit_cmd

.check_quit:
    cmp r12, 4
    jne .validate_move
    cmp byte [move_buf+1], 'u'
    jne .validate_move
    cmp byte [move_buf+2], 'i'
    jne .validate_move
    cmp byte [move_buf+3], 't'
    jne .validate_move
    jmp .exit_cmd

.check_list:
    cmp r12, 4
    jne .invalid
    cmp byte [move_buf+1], 'i'
    jne .invalid
    cmp byte [move_buf+2], 's'
    jne .invalid
    cmp byte [move_buf+3], 't'
    jne .invalid
    xor rax, rax
    jmp .done

.check_flip:
    cmp r12, 4
    jne .validate_move
    cmp byte [move_buf+1], 'l'
    jne .validate_move
    cmp byte [move_buf+2], 'i'
    jne .validate_move
    cmp byte [move_buf+3], 'p'
    jne .validate_move
    xor rax, rax
    jmp .done

.check_perft:
    cmp r12, 6
    jl .invalid
    cmp byte [move_buf+1], 'e'
    jne .invalid
    cmp byte [move_buf+2], 'r'
    jne .invalid
    cmp byte [move_buf+3], 'f'
    jne .invalid
    cmp byte [move_buf+4], 't'
    jne .invalid
    cmp byte [move_buf+5], ' '
    jne .invalid
    jmp .parse_perft

.check_gfx_or_go:
    cmp r12, 2
    jne .check_gfx
    cmp byte [move_buf+1], 'o'
    jne .check_gfx
    mov rax, 4
    jmp .done

.check_gfx:
    cmp r12, 3
    jne .validate_move
    cmp byte [move_buf+1], 'f'
    jne .validate_move
    cmp byte [move_buf+2], 'x'
    jne .validate_move
    xor rax, rax
    jmp .done

.check_text:
    cmp r12, 4
    jne .invalid
    cmp byte [move_buf+1], 'e'
    jne .invalid
    cmp byte [move_buf+2], 'x'
    jne .invalid
    cmp byte [move_buf+3], 't'
    jne .invalid
    xor rax, rax
    jmp .done

.check_new:
    cmp r12, 3
    jne .invalid
    cmp byte [move_buf+1], 'e'
    jne .invalid
    cmp byte [move_buf+2], 'w'
    jne .invalid
    mov rax, 3
    jmp .done

.check_uci:
    cmp r12, 3
    jne .invalid
    cmp byte [move_buf+1], 'c'
    jne .invalid
    cmp byte [move_buf+2], 'i'
    jne .invalid
    mov rax, 5
    jmp .done

.check_go:
    cmp r12, 2
    jne .invalid
    cmp byte [move_buf+1], 'o'
    jne .invalid
    mov rax, 4
    jmp .done

.parse_perft:
    mov r13, 6
    xor rax, rax
.digit_loop:
    cmp r13, r12
    jge .store_depth
    movzx rbx, byte [move_buf + r13]
    sub rbx, '0'
    cmp rbx, 9
    ja .invalid
    imul rax, 10
    add rax, rbx
    cmp rax, 255
    jg .invalid
    inc r13
    jmp .digit_loop

.store_depth:
    mov [perft_depth], al
    xor rax, rax
    jmp .done

.exit_cmd:
    mov rax, 1
    jmp .done

.invalid:
    lea rdi, [lang_txt_prompt_invalid_input]
    call write_cstr
    call print_newline
    mov rax, 2

.done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; is_valid_file / is_valid_rank
; ============================================================
is_valid_file:
    cmp rax, 'a'
    jl .no
    cmp rax, 'h'
    jg .no
    mov rax, 1
    ret
.no:
    xor rax, rax
    ret

is_valid_rank:
    cmp rax, '1'
    jl .no
    cmp rax, '8'
    jg .no
    mov rax, 1
    ret
.no:
    xor rax, rax
    ret

; ============================================================
; square_to_str
; ============================================================
square_to_str:
    push rax
    push rbx

    mov rbx, rax
    and rbx, 7
    add rbx, 'a'
    mov [square_str_buf], bl

    mov rbx, rax
    shr rbx, 3
    add rbx, '1'
    mov [square_str_buf+1], bl

    pop rbx
    pop rax
    ret

; ============================================================
; print_move - vypise tah vo formate e2e4
; Vstup: ax = 16-bitovy tah
; ============================================================
print_move:
    push rax
    push rbx
    push rsi

    mov bx, ax              ; uloz tah do bx

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

    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, msg_newline
    mov rdx, 1
    syscall

    pop rsi
    pop rbx
    pop rax
    ret

; ============================================================
; print_move_list
; ============================================================
print_move_list:
    push rax
    push rbx
    push rcx
    push rsi

    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, msg_move_count
    mov rdx, msg_move_count_len
    syscall

    movzx rax, word [move_count]
    call print_number
    call print_newline

    xor rbx, rbx
    movzx rcx, word [move_count]
    test rcx, rcx
    jz .done

    lea rsi, [move_list]
.loop:
    movzx rax, word [rsi + rbx*2]
    push rcx
    call print_move
    pop rcx
    inc rbx
    cmp rbx, rcx
    jl .loop

.done:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret
