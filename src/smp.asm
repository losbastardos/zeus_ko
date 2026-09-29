; ============================================================
; smp.asm - Lazy SMP helper procesy (clone bez CLONE_VM)
; Ucel: shared stop-flag stranka + spawn/reap helperov.
; Helperi maju vlastny BSS (COW), zdielaju len TT (MAP_SHARED)
; a tuto stop stranku. Bestmove vzdy z hlavneho procesu.
; ============================================================

%include "chess.inc"

DEFAULT REL

; SYS_MMAP chyba v chess.inc, definujeme lokalne (SYS_EXIT, SYS_WAIT4,
; SYS_CLOCK_GETTIME, SYS_CLONE, CLOCK_MONOTONIC uz existuju)
%define SYS_MMAP        9
%define SMP_STOP_OK     0
%define PROT_RW         3        ; PROT_READ|PROT_WRITE
%define MAP_SH_ANON     0x21     ; MAP_SHARED|MAP_ANONYMOUS

section .bss
smp_status: resd 1

section .text

global smp_init, smp_clear_stop, smp_check_stop, smp_signal_stop
global smp_spawn_helpers, smp_stop_and_reap, smp_worker_main
extern smp_shared, smp_child_count
extern uci_threads, uci_stop_flag
extern search_best_move, search_last_score, nodes_searched, asp_use

; ============================================================
; smp_init - vytvor (alebo zrecykluj) MAP_SHARED stranku
; ============================================================
smp_init:
    cmp qword [smp_shared], 0
    jne .clear
    mov rax, SYS_MMAP
    xor rdi, rdi
    mov rsi, 4096
    mov rdx, PROT_RW
    mov r10, MAP_SH_ANON
    mov r8, -1
    xor r9, r9
    syscall
    cmp rax, -4096
    ja .fail            ; chyba: shared stop nepojde, SMP sa vypne
    mov [smp_shared], rax
.clear:
    mov rax, [smp_shared]
    mov byte [rax], 0
.fail:
    ret

; ============================================================
; smp_clear_stop - vynuluj stop flag pre novy search
; ============================================================
smp_clear_stop:
    mov rax, [smp_shared]
    test rax, rax
    jz .done
    mov byte [rax], 0
.done:
    ret

; ============================================================
; smp_check_stop - eax=1 ak helperi/hlavny proces signalizoval stop
; Bezpecne volatelne z lubovolneho procesu.
; ============================================================
smp_check_stop:
    mov rax, [smp_shared]
    test rax, rax
    jz .no
    cmp byte [rax], 0
    je .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ============================================================
; smp_signal_stop - nastav stop pre vsetky helper procesy
; ============================================================
smp_signal_stop:
    mov rax, [smp_shared]
    test rax, rax
    jz .done
    mov byte [rax], 1
.done:
    ret

; ============================================================
; Docasne stuby - naplni ich Task 2 (spawn/worker logika)
; ============================================================
smp_spawn_helpers:
smp_stop_and_reap:
smp_worker_main:
    ret
