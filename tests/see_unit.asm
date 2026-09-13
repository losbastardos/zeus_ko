; ============================================================
; see_unit.asm - standalone unit test pre see (src/see.asm)
; Build: nasm -f elf64 -I src/ tests/see_unit.asm -o /tmp/see_unit.o
;        ld /tmp/see_unit.o obj/see.o -o /tmp/see_unit
; ============================================================

%include "chess.inc"

DEFAULT REL

extern see

section .data

global promo_pieces
promo_pieces: db 0, QUEEN, ROOK, BISHOP, KNIGHT

msg_t:      db "test "
msg_t_len   equ $ - msg_t
msg_ok:     db ": OK  see="
msg_ok_len  equ $ - msg_ok
msg_fail:   db ": FAIL see="
msg_fail_len equ $ - msg_fail
msg_want:   db "  ocakavane="
msg_want_len equ $ - msg_want
msg_nl:     db 10

; --- testove pozicie ---
; struktura: 64B board, 1B side, 2B move, 4B expected, 1B pad = 72B

; t1: Q d5xQ d6 (nebranene): +900
t1:
    db 6,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,5,0,0,0,0
    db 0,0,0,13,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,14,0,0,0
    db 0
    dw 35 | (43 << 6)
    dd 900
    db 0

; t2: Q d4xp d5, pesiac c6 brani: +100-900 = -800
t2:
    db 6,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,5,0,0,0,0
    db 0,0,0,9,0,0,0,0
    db 0,0,9,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,14,0,0,0
    db 0
    dw 27 | (35 << 6)
    dd -800
    db 0

; t3: R d1xR d5; cierny najprv berie pesciakom c6 (najmenej hodnotny),
; potom N c3, Q d8 - cierny ma prestat -> 0
t3:
    db 6,0,0,4,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,2,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,12,0,0,0,0
    db 0,0,9,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,13,0,0,14,0
    db 0
    dw 3 | (35 << 6)
    dd 0
    db 0

; t4: exd6 e.p. (brany pesiak, bez recaptury): +100
t4:
    db 0,0,0,0,6,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,9,1,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,14,0,0,0
    db 0
    dw 36 | (43 << 6) | (FLAG_ENPASSANT << 12)
    dd 100
    db 0

; t5: a7xb8=Q (branie veze promociou): +500
t5:
    db 6,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 1,0,0,0,0,0,0,0
    db 0,12,0,0,0,0,0,14
    db 0
    dw 48 | (57 << 6) | (FLAG_PROMO_Q << 12)
    dd 500
    db 0

; t6: Q d4xR d5, druha vez d8 x-ray: 500-900 = -400
t6:
    db 6,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,5,0,0,0,0
    db 0,0,0,12,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,12,0,0,14,0
    db 0
    dw 27 | (35 << 6)
    dd -400
    db 0

; t7: exd5, c6 brani (vymena pesiacov): 0
t7:
    db 6,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,1,0,0,0
    db 0,0,0,9,0,0,0,0
    db 0,0,9,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,14,0,0,0
    db 0
    dw 28 | (35 << 6)
    dd 0
    db 0

; t8: cierny Q d4xp d5, biely pesiac c4 brani: -800 (side = 1)
t8:
    db 6,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,1,13,0,0,0,0
    db 0,0,0,1,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,14,0,0,0
    db 1
    dw 27 | (35 << 6)
    dd -800
    db 0

; t9: J e5xp d7, kral c8 brani: 100-320 = -220
t9:
    db 6,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,2,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,9,0,0,0,0
    db 0,0,14,0,0,0,0,0
    db 0
    dw 36 | (51 << 6)
    dd -220
    db 0

; t10: exd6 e.p., kral c7 recaptura: 100-100 = 0
t10:
    db 6,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,9,1,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,14,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0
    dw 36 | (43 << 6) | (FLAG_ENPASSANT << 12)
    dd 0
    db 0

; t11: TICHY tah N e4-f6 (ciel bez obrancov): 0
t11:
    db 6,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,2,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,14,0,0,0
    db 0
    dw 28 | (45 << 6)
    dd 0
    db 0

; t12: TICHY tah Q d4-d5, pesiac c6 ju bere (zisk 0): 0-900 = -900
t12:
    db 6,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,5,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,9,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,14,0,0,0
    db 0
    dw 27 | (35 << 6)
    dd -900
    db 0

; t13: TICHY tah N e4-d6, p c7xd6, V d1xd6: 0-320+100 = -220
t13:
    db 0,0,0,4,14,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,2,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0
    db 0,0,9,0,0,0,0,0
    db 6,0,0,0,0,0,0,0
    db 0
    dw 28 | (43 << 6)
    dd -220
    db 0

NUM_TESTS equ 13
TEST_SIZE equ 72

section .bss

global board, side
board:      resb 64
side:       resb 1
numbuf:     resb 16
fail_count: resd 1

section .text
global _start

; ============================================================
; print_write - write(1, rsi, rdx)
; ============================================================
print_write:
    mov eax, SYS_WRITE
    mov edi, STDOUT
    syscall
    ret

; ============================================================
; print_int - vytlac eax (signed) desiatkovo (bez newline)
; ============================================================
print_int:
    push rbx
    push rcx
    push rdx
    push rsi
    mov ecx, eax            ; zachovaj znamienko
    test ecx, ecx
    jns .pos
    neg eax
.pos:
    lea rsi, [numbuf + 16]
    mov ebx, 10
.digit:
    xor edx, edx
    div ebx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test eax, eax
    jnz .digit
    test ecx, ecx
    jns .out
    dec rsi
    mov byte [rsi], '-'
.out:
    lea rdx, [numbuf + 16]
    sub rdx, rsi
    call print_write
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; _start - prebehni vsetky testy; exit code = pocet FAIL
; ============================================================
_start:
    mov dword [fail_count], 0
    xor r12d, r12d          ; index testu
    lea r13, [t1]           ; ukazovatel testu

.test_loop:
    cmp r12d, NUM_TESTS
    jge .all_done

    ; kopiruj board + nastav side
    lea rdi, [board]
    mov rsi, r13
    mov ecx, 64
.copy:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .copy
    mov al, [r13 + 64]
    mov [side], al

    ; vypis "test N"
    lea rsi, [msg_t]
    mov edx, msg_t_len
    call print_write
    lea eax, [r12d + 1]
    call print_int

    ; see(tah)
    movzx eax, word [r13 + 65]
    call see
    mov r14d, eax           ; vysledok

    ; porovnaj s ocakavanym (offset 67)
    cmp r14d, dword [r13 + 67]
    jne .fail

    lea rsi, [msg_ok]
    mov edx, msg_ok_len
    call print_write
    mov eax, r14d
    call print_int
    lea rsi, [msg_nl]
    mov edx, 1
    call print_write
    jmp .next

.fail:
    inc dword [fail_count]
    lea rsi, [msg_fail]
    mov edx, msg_fail_len
    call print_write
    mov eax, r14d
    call print_int
    lea rsi, [msg_want]
    mov edx, msg_want_len
    call print_write
    mov eax, dword [r13 + 67]
    call print_int
    lea rsi, [msg_nl]
    mov edx, 1
    call print_write

.next:
    add r13, TEST_SIZE
    inc r12d
    jmp .test_loop

.all_done:
    mov eax, [fail_count]
    call print_int          ; vytlac pocet FAIL
    mov eax, SYS_EXIT
    mov edi, [fail_count]   ; exit code = pocet zlyhan
    syscall
