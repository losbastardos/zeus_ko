; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; nnue.asm - NNUE loader (faza 1: linearny PST model)
;
; Format net.nnue (little-endian):
;   magic "NNUE" u32, version u32 (=1)
;   MG: own[6][64] int16, enemy[6][64] int16
;   EG: own[6][64] int16, enemy[6][64] int16
;   spolu 3080 bajtov
;
; own/enemy su rel. strane na tahu (STM); figurky opacnej farby ako
; STM sa mirroruju (rel_sq = sq ^ 56). Loader nakopiruje hodnoty do
; pst_runtime_mg/eg layoutu [own 7x64][enemy 7x64] per faza
; (slot 0 = empty zostava nulovy), int16 -> int8 clip.
; Pri chybe suboru/magicu/verzie vrati eax=1 (caller fallback classic).
; ============================================================

%include "chess.inc"

DEFAULT REL

%define NNUE_MAGIC    0x45554e4e   ; "NNUE" little-endian
%define NNUE_VERSION  1
%define NNUE_FILESIZE (8 + 4*6*64*2)

section .bss
nnue_buf: resb NNUE_FILESIZE

section .text
global nnue_load
extern pst_runtime_mg, pst_runtime_eg

; ============================================================
; nnue_load - nacita net subor do pst_runtime tabuliek
; Vstup:  rdi = cesta (NUL-terminated)
; Vystup: eax = 0 OK, 1 = chyba
; ============================================================
nnue_load:
    push rbx
    push r12
    push r13
    push r14
    ; open(path, O_RDONLY) - rdi uz obsahuje cestu
    mov rax, SYS_OPEN
    xor esi, esi                 ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js .fail
    mov r12, rax                 ; fd
    ; read cely subor
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [nnue_buf]
    mov rdx, NNUE_FILESIZE
    syscall
    mov r13, rax                 ; nacitane bajty
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    cmp r13, NNUE_FILESIZE
    jl .fail
    ; magic + verzia
    mov eax, dword [nnue_buf]
    cmp eax, NNUE_MAGIC
    jne .fail
    mov eax, dword [nnue_buf + 4]
    cmp eax, NNUE_VERSION
    jne .fail
    ; 4 sekcie: MG own, MG enemy, EG own, EG enemy
    ; zdroj offset v bufri: 8 + sekcia*768 ; kazda sekcia = 6 fig x 128 B
    ; ciel: faza baza + (sekcia&1 ? 7*64 : 0) + (fig+1)*64
    xor r14, r14                 ; sekcia 0..3
.sect_loop:
    cmp r14, 4
    jae .ok
    ; zdrojovy base = nnue_buf + 8 + sekcia*768
    mov rax, r14
    imul rax, rax, 768
    lea rbx, [nnue_buf + 8]
    add rbx, rax                 ; rbx = zdroj
    ; cielovy base: sekcia 0,1 -> mg ; 2,3 -> eg ; own (0,2) / enemy (1,3)
    mov rax, r14
    shr rax, 1                   ; 0 = mg, 1 = eg
    lea rdx, [pst_runtime_mg]
    cmp rax, 0
    je .phase_ok
    lea rdx, [pst_runtime_eg]
.phase_ok:
    mov rax, r14
    and rax, 1
    imul rax, rax, 7*64          ; enemy = +7*64 bajtov
    lea r13, [rdx + rax]         ; ciel base
    ; 6 figurok
    xor r12, r12                 ; fig 0..5
.fig_loop:
    cmp r12, 6
    jae .next_sect
    ; zdroj: rbx + fig*128 ; ciel: r13 + (fig+1)*64
    mov rax, r12
    shl rax, 7                   ; fig*128 (int16 = 2B)
    lea rsi, [rbx + rax]
    mov rax, r12
    shl rax, 6                   ; fig*64
    lea rdi, [r13 + rax]
    add rdi, 64                  ; +64 = preskoc empty slot 0
    ; skopiruj 64 hodnot s int8 clip
    xor rcx, rcx
.copy_loop:
    cmp rcx, 64
    jae .next_fig
    movsx eax, word [rsi + rcx*2]
    cmp eax, 127
    jle .clip_lo
    mov eax, 127
.clip_lo:
    cmp eax, -128
    jge .clip_done
    mov eax, -128
.clip_done:
    mov [rdi + rcx], al
    inc rcx
    jmp .copy_loop
.next_fig:
    inc r12
    jmp .fig_loop
.next_sect:
    inc r14
    jmp .sect_loop
.ok:
    xor eax, eax
    jmp .ret
.fail:
    mov eax, 1
.ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
