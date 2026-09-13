; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; book.asm - opening book, podpora viacerych suborov
; Format zaznamu: hash(8B) | move(2B)  (little-endian)
; ============================================================

%include "chess.inc"

DEFAULT REL

section .text

global book_load_all, book_lookup

extern position_hash
extern book_ptrs, book_sizes, book_count

MAX_BOOKS equ 4

; ============================================================
; book_load_one - nacita jeden book subor cez mmap
; Vstup:  rdi = nazov suboru
; Vystup: rax = ukazatel (0 ak chyba), rdx = velkost
; ============================================================
book_load_one:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r15, rdi            ; filename

    ; open(filename, O_RDONLY)
    mov rax, 2              ; SYS_open
    mov rdi, r15
    xor rsi, rsi            ; O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .error
    mov r12, rax            ; fd

    ; ziskaj velkost cez lseek
    mov rax, 8              ; SYS_lseek
    mov rdi, r12
    xor rsi, rsi
    mov rdx, 2              ; SEEK_END
    syscall
    cmp rax, 0
    jle .close_error
    mov r13, rax            ; size

    ; vrat sa na zaciatok
    mov rax, 8              ; SYS_lseek
    mov rdi, r12
    xor rsi, rsi
    xor rdx, rdx            ; SEEK_SET
    syscall

    ; mmap
    mov rax, 9              ; SYS_mmap
    xor rdi, rdi            ; addr
    mov rsi, r13            ; length
    xor rdx, rdx
    mov dl, 1               ; PROT_READ
    mov r10, 2              ; MAP_PRIVATE
    mov r8, r12             ; fd
    xor r9, r9              ; offset
    syscall
    cmp rax, 0
    jl .close_error

    mov r14, rax            ; ptr

    ; close(fd)
    mov rax, 3              ; SYS_close
    mov rdi, r12
    syscall

    mov rax, r14
    mov rdx, r13
    jmp .done

.close_error:
    mov rax, 3
    mov rdi, r12
    syscall
.error:
    xor rax, rax
    xor rdx, rdx

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; book_load_all - nacita vsetky book subory z ciarkou oddeleneho zoznamu
; Vstup:  rdi = ukazatel na zoznam (napr. "book1.book,book2.book")
; ============================================================
book_load_all:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 320            ; buffer pre jeden nazov (256B) + padding

    mov r15, rdi            ; list
    mov qword [book_count], 0
    xor r14, r14            ; index do book_ptrs

.next_file:
    movzx rax, byte [r15]
    test rax, rax
    jz .done

    ; preskoc whitespace a ciarky na zaciatku
    cmp rax, ' '
    je .skip
    cmp rax, 9
    je .skip
    cmp rax, ','
    je .skip

    mov r12, r15            ; zaciatok nazvu

.find_end:
    movzx rax, byte [r15]
    cmp rax, 0
    je .copy
    cmp rax, ','
    je .copy
    inc r15
    jmp .find_end

.copy:
    mov r13, r15            ; koniec (na ',' alebo 0)

    ; trim zaciatku
.trim_start:
    movzx rax, byte [r12]
    cmp rax, ' '
    je .ts_inc
    cmp rax, 9
    je .ts_inc
    jmp .trim_end
.ts_inc:
    inc r12
    jmp .trim_start

.trim_end:
    ; trim konca
    mov rbx, r13
    dec rbx
.trim_loop:
    cmp rbx, r12
    jl .empty
    movzx rax, byte [rbx]
    cmp rax, ' '
    je .trim_dec
    cmp rax, 9
    je .trim_dec
    cmp rax, ','
    je .trim_dec
    jmp .copy_name
.trim_dec:
    mov byte [rbx], 0
    dec rbx
    jmp .trim_loop

.empty:
    cmp byte [r15], 0
    je .done
    inc r15
    jmp .next_file

.copy_name:
    ; skopiruj do stack buffra
    mov rdi, rsp
.copy_loop:
    cmp r12, r13
    jge .copy_done
    mov al, [r12]
    mov [rdi], al
    inc r12
    inc rdi
    jmp .copy_loop
.copy_done:
    mov byte [rdi], 0

    ; nacitaj subor
    mov rdi, rsp
    call book_load_one
    test rax, rax
    jz .skip_load

    cmp r14, MAX_BOOKS
    jge .skip_load

    lea rsi, [book_ptrs]
    mov [rsi + r14*8], rax
    lea rsi, [book_sizes]
    mov [rsi + r14*8], rdx
    inc r14
    mov [book_count], r14

.skip_load:
    movzx rax, byte [r15]
    test rax, rax
    jz .done
    inc r15               ; preskoc ciarku
    jmp .next_file

.skip:
    inc r15
    jmp .next_file

.done:
    add rsp, 320
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================
; book_lookup - vyhlada tah v knihach podla hashu
; Vystup: rax = 16-bitovy tah, alebo 0 ak nenajdene
; ============================================================
book_lookup:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14

    mov r14, [book_count]
    test r14, r14
    jz .not_found

    mov r13, [position_hash]
    xor r12, r12            ; index knihy

.book_loop:
    cmp r12, r14
    jge .not_found

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
    jmp .done

.next_entry:
    add rbx, 10
    jmp .entry_loop

.next_book:
    inc r12
    jmp .book_loop

.not_found:
    xor rax, rax

.done:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret