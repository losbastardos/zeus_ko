; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; eco.asm - opening kniznica ECO kodov a mien otvoreni (eco.bin)
; Format: u32 magic 0x424F4345 | u32 ver=1 | u32 count |
;         u32 name_blob_size | name blob (UTF-8, NUL-term) |
;         entries x 20 B zoradene podla hash:
;         u64 hash, u32 name_off, u8 eco[4], u8 ply, 3 B pad
; ============================================================

%include "chess.inc"

DEFAULT REL

section .text

global eco_load, eco_lookup, eco_test_print
global eco_ready, eco_code, eco_name_ptr, eco_name_len

extern position_hash
extern write_cstr, print_number, print_newline, msg_newline

ECO_MAGIC   equ 0x424F4345
ECO_HDR     equ 16
ECO_ENT     equ 20

; ============================================================
; eco_load - mmap eco.bin, validacia hlavicky
; Vstup:  rdi = cesta k suboru
; Vystup: eco_ready = 1 pri uspechu, inak 0 (tiche vypnutie)
; ============================================================
eco_load:
    push rbx
    push r12
    push r13
    push r14

    mov byte [eco_ready], 0

    test rdi, rdi
    jz .done
    cmp byte [rdi], 0
    je .done

    ; open(filename, O_RDONLY)
    mov rax, 2              ; SYS_open
    xor rsi, rsi
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .done
    mov r12, rax            ; fd

    ; velkost cez lseek
    mov rax, 8              ; SYS_lseek
    mov rdi, r12
    xor rsi, rsi
    mov rdx, 2              ; SEEK_END
    syscall
    cmp rax, 0
    jle .close_done
    mov r13, rax            ; size

    ; vrat sa na zaciatok
    mov rax, 8
    mov rdi, r12
    xor rsi, rsi
    xor rdx, rdx            ; SEEK_SET
    syscall

    ; mmap
    mov rax, 9              ; SYS_mmap
    xor rdi, rdi
    mov rsi, r13
    xor rdx, rdx
    mov dl, 1               ; PROT_READ
    mov r10, 2              ; MAP_PRIVATE
    mov r8, r12
    xor r9, r9
    syscall
    cmp rax, 0
    jl .close_done
    mov r14, rax            ; ptr

    mov rax, 3              ; SYS_close
    mov rdi, r12
    syscall

    ; validacia: min. hlavicka + magic + verzia
    cmp r13, ECO_HDR
    jl .done
    cmp dword [r14], ECO_MAGIC
    jne .done
    cmp dword [r14 + 4], 1
    jne .done

    mov eax, [r14 + 8]      ; count
    mov [eco_count], rax
    mov ebx, [r14 + 12]     ; name_blob_size
    mov [eco_blob], rbx

    ; sanity: size >= hdr + blob + count*20
    mov rax, [eco_count]
    imul rax, ECO_ENT
    add rax, rbx
    add rax, ECO_HDR
    cmp r13, rax
    jl .done

    ; name blob base a entries base
    lea rax, [r14 + ECO_HDR]
    mov [eco_names], rax
    add rax, rbx
    mov [eco_entries], rax
    mov [eco_ptr], r14
    mov byte [eco_ready], 1

.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.close_done:
    mov rax, 3
    mov rdi, r12
    syscall
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; eco_lookup - binarne vyhladanie position_hash v entries
; Vystup: eax = 1 najdene / 0 nie; pri najdeni:
;         eco_code (3 znaky + NUL), eco_name_ptr, eco_name_len
; ============================================================
eco_lookup:
    cmp byte [eco_ready], 0
    je .no

    mov r8, [position_hash]
    xor rcx, rcx            ; lo
    mov rdx, [eco_count]
    dec rdx                 ; hi

.loop:
    cmp rcx, rdx
    ja .no
    lea rax, [rcx + rdx]
    shr rax, 1              ; mid

    mov rsi, rax
    imul rsi, ECO_ENT
    add rsi, [eco_entries]

    mov rdi, [rsi]          ; hash entry
    cmp r8, rdi
    jb .left
    ja .right

    ; najdene: name_off (rel. k zaciatku blobu), eco[4]
    mov eax, [rsi + 8]
    mov rdi, [eco_names]
    add rdi, rax
    mov [eco_name_ptr], rdi

    ; dlzka mena (po NUL)
    xor rax, rax
.len:
    cmp byte [rdi + rax], 0
    je .len_done
    inc rax
    jmp .len
.len_done:
    mov [eco_name_len], rax

    ; ECO kod: 4 bajty (3 znaky + NUL) z entry
    mov eax, [rsi + 12]
    mov [eco_code], eax

    mov eax, 1
    ret

.left:
    lea rdx, [rax - 1]      ; hi = mid - 1
    jmp .loop
.right:
    lea rcx, [rax + 1]      ; lo = mid + 1
    jmp .loop

.no:
    xor eax, eax
    ret

; ============================================================
; eco_test_print - diagnosticky vystup pre prikaz ecotest
; Vystup: "ECO: <code> <name>" alebo "ECO: not found hash=<dec>"
; ============================================================
eco_test_print:
    push rbx

    call eco_lookup
    test eax, eax
    jz .not_found

    lea rdi, [eco_str_found]
    call write_cstr
    lea rdi, [eco_code]
    call write_cstr
    mov al, ' '
    call .char
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, [eco_name_ptr]
    mov rdx, [eco_name_len]
    syscall
    call print_newline
    pop rbx
    ret

.not_found:
    lea rdi, [eco_str_nf]
    call write_cstr
    mov rax, [position_hash]
    call print_number
    call print_newline
    pop rbx
    ret

.char:
    mov [eco_tmp_char], al
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [eco_tmp_char]
    mov rdx, 1
    syscall
    ret

section .data

eco_str_found: db "ECO: ", 0
eco_str_nf:    db "ECO: not found hash=", 0

section .bss

eco_ready:    resb 1
eco_tmp_char: resb 1
eco_ptr:      resq 1
eco_entries:  resq 1
eco_names:    resq 1
eco_count:    resq 1
eco_blob:     resq 1
eco_code:     resb 4
eco_name_ptr: resq 1
eco_name_len: resq 1
