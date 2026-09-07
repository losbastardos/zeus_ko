; ============================================================
; gfx/config.asm - jednoduchy INI parser
; ============================================================

%include "chess.inc"

DEFAULT REL

section .text

global load_config, config_get, load_lang_pack, lang_get

extern config_buf, lang_buf

; ============================================================
; parse_int - prevedie C-string cisla na int
; Vstup:  rsi = ukazatel na retazec
; Vystup: rax = cislo (0 ak chyba)
; ============================================================
global parse_int
parse_int:
    push rbx
    push rcx
    xor rax, rax
    xor rcx, rcx
.loop:
    movzx rbx, byte [rsi + rcx]
    test rbx, rbx
    jz .done
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
; load_config - nacita chess.ini do config_buf
; Vstup:  rdi = nazov suboru
; Vystup: rax = 0 OK, 1 chyba
; ============================================================
load_config:
    push rbx
    push r12
    push r13
    push r14

    mov r15, rdi

    ; open(filename, O_RDONLY)
    mov rax, 2              ; SYS_open
    mov rdi, r15
    xor rsi, rsi            ; O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .error
    mov r12, rax            ; fd

    ; read do config_buf, max 4095
    mov rax, 0              ; SYS_read
    mov rdi, r12
    lea rsi, [config_buf]
    mov rdx, 4095
    syscall
    cmp rax, 0
    jl .close_error
    mov r13, rax            ; nacitane bajty

    ; null-terminate
    lea rbx, [config_buf]
    mov byte [rbx + r13], 0

    ; close
    mov rax, 3              ; SYS_close
    mov rdi, r12
    syscall

    xor rax, rax
    jmp .done

.close_error:
    mov rax, 3
    mov rdi, r12
    syscall
.error:
    mov byte [config_buf], 0
    mov rax, 1
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; load_lang_pack - nacita jazykovy subor do lang_buf
; Vstup:  rdi = nazov suboru
; Vystup: rax = 0 OK, 1 chyba
; ============================================================
load_lang_pack:
    push rbx
    push r12
    push r13
    push r14

    mov r15, rdi

    mov rax, 2
    mov rdi, r15
    xor rsi, rsi
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .error
    mov r12, rax

    mov rax, 0
    mov rdi, r12
    lea rsi, [lang_buf]
    mov rdx, 4095
    syscall
    cmp rax, 0
    jl .close_error
    mov r13, rax

    lea rbx, [lang_buf]
    mov byte [rbx + r13], 0

    mov rax, 3
    mov rdi, r12
    syscall

    xor rax, rax
    jmp .done

.close_error:
    mov rax, 3
    mov rdi, r12
    syscall
.error:
    mov byte [lang_buf], 0
    mov rax, 1
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; config_get - vyhlada hodnotu kluca v config_buf
; Vstup:  rdi = ukazatel na kluc (C-string)
;         rsi = predvolena hodnota (ukazatel)
; Vystup: rax = ukazatel na hodnotu alebo default
; ============================================================
config_get:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r14, rdi            ; key
    mov r15, rsi            ; default
    lea rbx, [config_buf]

.next_char:
    movzx rax, byte [rbx]
    test rax, rax
    jz .not_found

    ; preskoc whitespace a prazdne riadky
    cmp rax, ' '
    je .skip
    cmp rax, 9
    je .skip
    cmp rax, 10
    je .skip
    cmp rax, 13
    je .skip

    ; komentar alebo sekcia -> preskoc riadok
    cmp rax, ';'
    je .skip_line
    cmp rax, '['
    je .skip_line

    ; porovnaj kluc
    mov r12, rbx            ; zaciatok riadku
    mov r13, r14            ; key pointer
.compare:
    movzx rax, byte [r13]
    test rax, rax
    jz .key_matched
    movzx rdx, byte [r12]
    cmp dl, al
    jne .skip_line
    inc r12
    inc r13
    jmp .compare

.key_matched:
    ; za klucom musi byt '=' alebo whitespace
    movzx rax, byte [r12]
    cmp rax, '='
    je .found_eq
    cmp rax, ' '
    je .find_eq
    cmp rax, 9
    je .find_eq
    jmp .skip_line

.find_eq:
    movzx rax, byte [r12]
    cmp rax, '='
    je .found_eq
    cmp rax, ' '
    je .skip_ws
    cmp rax, 9
    je .skip_ws
    jmp .skip_line
.skip_ws:
    inc r12
    jmp .find_eq

.found_eq:
    inc r12                 ; za '='
    ; preskoc whitespace za '='
.skip_val_ws:
    movzx rax, byte [r12]
    cmp rax, ' '
    je .skip_val
    cmp rax, 9
    je .skip_val
    cmp rax, 13
    je .skip_val
    jmp .found
.skip_val:
    inc r12
    jmp .skip_val_ws

.found:
    mov r13, r12
.term_loop:
    movzx rax, byte [r13]
    test rax, rax
    jz .term_done
    cmp rax, 10
    je .term_done
    cmp rax, 13
    je .term_done
    inc r13
    jmp .term_loop
.term_done:
    ; skopiruj hodnotu do ini_val_buf (bez mutacie zdroja!)
    mov rcx, r13
    sub rcx, r12
    cmp rcx, 4095
    jbe .copy_val
    mov rcx, 4095
.copy_val:
    lea rdi, [ini_val_buf]
    mov rsi, r12
    push rcx
    rep movsb
    pop rcx
    mov byte [rdi], 0
    lea rax, [ini_val_buf]
    jmp .done

.skip:
    inc rbx
    jmp .next_char

.skip_line:
    movzx rax, byte [rbx]
    test rax, rax
    jz .not_found
    cmp rax, 10
    je .next_line
    inc rbx
    jmp .skip_line

.next_line:
    inc rbx
    jmp .next_char

.not_found:
    mov rax, r15

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .bss

ini_val_buf: resb 4096

section .text

; ============================================================
; lang_get - vyhlada hodnotu kluca v lang_buf
; Vstup:  rdi = ukazatel na kluc (C-string)
;         rsi = predvolena hodnota (ukazatel)
; Vystup: rax = ukazatel na hodnotu alebo default
; ============================================================
lang_get:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r14, rdi
    mov r15, rsi
    lea rbx, [lang_buf]

.next_char:
    movzx rax, byte [rbx]
    test rax, rax
    jz .not_found

    cmp rax, ' '
    je .skip
    cmp rax, 9
    je .skip
    cmp rax, 10
    je .skip
    cmp rax, 13
    je .skip

    cmp rax, ';'
    je .skip_line
    cmp rax, '['
    je .skip_line

    mov r12, rbx
    mov r13, r14
.compare:
    movzx rax, byte [r13]
    test rax, rax
    jz .key_matched
    movzx rdx, byte [r12]
    cmp dl, al
    jne .skip_line
    inc r12
    inc r13
    jmp .compare

.key_matched:
    movzx rax, byte [r12]
    cmp rax, '='
    je .found_eq
    cmp rax, ' '
    je .find_eq
    cmp rax, 9
    je .find_eq
    jmp .skip_line

.find_eq:
    movzx rax, byte [r12]
    cmp rax, '='
    je .found_eq
    cmp rax, ' '
    je .skip_ws
    cmp rax, 9
    je .skip_ws
    jmp .skip_line
.skip_ws:
    inc r12
    jmp .find_eq

.found_eq:
    inc r12
.skip_val_ws:
    movzx rax, byte [r12]
    cmp rax, ' '
    je .skip_val
    cmp rax, 9
    je .skip_val
    cmp rax, 13
    je .skip_val
    jmp .found
.skip_val:
    inc r12
    jmp .skip_val_ws

.found:
    mov r13, r12
.term_loop:
    movzx rax, byte [r13]
    test rax, rax
    jz .term_done
    cmp rax, 10
    je .term_done
    cmp rax, 13
    je .term_done
    inc r13
    jmp .term_loop
.term_done:
    ; skopiruj hodnotu do ini_val_buf (bez mutacie zdroja!)
    mov rcx, r13
    sub rcx, r12
    cmp rcx, 4095
    jbe .copy_val
    mov rcx, 4095
.copy_val:
    lea rdi, [ini_val_buf]
    mov rsi, r12
    push rcx
    rep movsb
    pop rcx
    mov byte [rdi], 0
    lea rax, [ini_val_buf]
    jmp .done

.skip:
    inc rbx
    jmp .next_char

.skip_line:
    movzx rax, byte [rbx]
    test rax, rax
    jz .not_found
    cmp rax, 10
    je .next_line
    inc rbx
    jmp .skip_line

.next_line:
    inc rbx
    jmp .next_char

.not_found:
    mov rax, r15

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
