; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; gfx/mouse.asm - evdev mys
; ============================================================

%include "chess.inc"

DEFAULT REL

section .data

EV_SYN      equ 0
EV_KEY      equ 1
EV_REL      equ 2
EV_ABS      equ 3

BTN_LEFT    equ 0x110  ; 272

ABS_X       equ 0
ABS_Y       equ 1
REL_X       equ 0
REL_Y       equ 1

msg_mouse_open:
    db "Chyba: nedaol sa otvorit mys.", 10, 0
msg_mouse_open_len equ $ - msg_mouse_open - 1

; ============================================================
section .text

global mouse_init, mouse_read_event

extern fb_width, fb_height, mouse_device, mouse_fd, mouse_x, mouse_y, mouse_btn_left

; ============================================================
; print_msg_c - vypise string
; Vstup: rdi = pointer, esi = dlzka
; ============================================================
print_msg_c:
    push rax
    push rdx
    mov rax, SYS_WRITE
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, STDOUT
    syscall
    pop rdx
    pop rax
    ret

; ============================================================
; mouse_init - otvori evdev mys
; ============================================================
mouse_init:
    push rdi
    push rsi

    mov byte [mouse_btn_left], 0

    ; open mouse device
    lea rdi, [mouse_device]
    mov rax, 2          ; SYS_open
    xor rsi, rsi        ; O_RDONLY
    syscall
    cmp rax, 0
    jl .error
    mov [mouse_fd], rax

    ; default position to center
    mov eax, [fb_width]
    shr eax, 1
    mov [mouse_x], eax
    mov eax, [fb_height]
    shr eax, 1
    mov [mouse_y], eax

    xor rax, rax
    pop rsi
    pop rdi
    ret

.error:
    mov rdi, msg_mouse_open
    mov rsi, msg_mouse_open_len
    call print_msg_c
    mov rax, 1
    pop rsi
    pop rdi
    ret

; ============================================================
; mouse_read_event - precita jeden struct input_event
; Aktualizuje mouse_x/mouse_y/mouse_btn_left
; Vystup: rax = typ udalosti, -1 chyba
; ============================================================
mouse_read_event:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13

    sub rsp, 24

    mov r12, rsp
.read_loop:
    mov rax, 0          ; SYS_read
    mov rdi, [mouse_fd]
    mov rsi, r12
    mov rdx, 24
    syscall
    cmp rax, 24
    jne .error

    ; struct input_event: time(8), type(2), code(2), value(4)
    movzx rax, word [rsp + 8]   ; type
    movzx rbx, word [rsp + 10]  ; code
    mov ecx, dword [rsp + 12]   ; value

    cmp rax, EV_ABS
    jne .check_rel
    cmp rbx, ABS_X
    jne .abs_y
    mov [mouse_x], ecx
    jmp .done
.abs_y:
    cmp rbx, ABS_Y
    jne .done
    mov [mouse_y], ecx
    jmp .done

.check_rel:
    cmp rax, EV_REL
    jne .check_key
    cmp rbx, REL_X
    jne .rel_y
    mov edx, [mouse_x]
    add edx, ecx
    cmp edx, 0
    jge .x_positive
    xor edx, edx
.x_positive:
    mov r13d, [fb_width]
    cmp edx, r13d
    jl .x_store
    mov edx, r13d
    dec edx
.x_store:
    mov [mouse_x], edx
    jmp .done
.rel_y:
    cmp rbx, REL_Y
    jne .done
    mov edx, [mouse_y]
    add edx, ecx
    cmp edx, 0
    jge .y_positive
    xor edx, edx
.y_positive:
    mov r13d, [fb_height]
    cmp edx, r13d
    jl .y_store
    mov edx, r13d
    dec edx
.y_store:
    mov [mouse_y], edx
    jmp .done

.check_key:
    cmp rax, EV_KEY
    jne .done
    cmp rbx, BTN_LEFT
    jne .done
    cmp ecx, 1
    jne .release
    mov byte [mouse_btn_left], 1
    jmp .done
.release:
    mov byte [mouse_btn_left], 0

.done:
    add rsp, 24
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

.error:
    add rsp, 24
    mov rax, -1
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret