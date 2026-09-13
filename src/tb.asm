; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; tb.asm - Syzygy/Nalimov tablebase interface (stub E6)
; Zatial sa nenacitavaju ziadne .rtbw/.rtbz tabulky;
; probe funkcie vzdy vracaju TB_NOT_FOUND.
; ============================================================

%include "chess.inc"

DEFAULT REL

TB_PATH_MAX equ 256

section .bss

tb_path:     resb TB_PATH_MAX   ; cesta k tabulkam (null-terminated)
tb_path_len: resq 1             ; dlzka ulozenej cesty (bez NUL)

section .text

global tb_init, tb_probe_wdl, tb_probe_dtz, tb_piece_count
global tb_path, tb_path_len

extern board

; ============================================================
; tb_init - ulozi cestu k tabulkam do interneho buffra
; Vstup:  rdi = ukazatel na null-terminated retazec
; Vystup: eax = 0 (success)
; ============================================================
tb_init:
    push rbx
    mov rbx, rdi                ; zdrojovy retazec
    lea rdx, [tb_path]          ; cielovy buffer
    xor ecx, ecx                ; index
.copy_loop:
    cmp rcx, TB_PATH_MAX - 1
    jae .truncate
    movzx eax, byte [rbx + rcx]
    mov [rdx + rcx], al
    test al, al
    jz .copied
    inc rcx
    jmp .copy_loop
.truncate:
    mov byte [rdx + TB_PATH_MAX - 1], 0   ; bezpecne ukoncenie pri truncite
.copied:
    mov [tb_path_len], rcx
    xor eax, eax
    pop rbx
    ret

; ============================================================
; tb_probe_wdl - WDL probe (stub)
; Vystup: eax = TB_WIN / TB_DRAW / TB_LOSS / TB_NOT_FOUND
; ============================================================
tb_probe_wdl:
    mov eax, TB_NOT_FOUND
    ret

; ============================================================
; tb_probe_dtz - DTZ probe (stub)
; Vystup: eax = DTZ alebo TB_NOT_FOUND
; ============================================================
tb_probe_dtz:
    mov eax, TB_NOT_FOUND
    ret

; ============================================================
; tb_piece_count - spocita neprazdne policka na sachovnici
; Vystup: eax = pocet figurok na sachovnici (0..64)
; ============================================================
tb_piece_count:
    lea rdx, [board]
    xor eax, eax
    xor ecx, ecx
.scan:
    cmp ecx, 64
    jae .done
    cmp byte [rdx + rcx], EMPTY
    je .next
    inc eax
.next:
    inc ecx
    jmp .scan
.done:
    ret