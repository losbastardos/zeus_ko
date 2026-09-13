; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; sdl_stub.asm - stub SDL backendu pre staticky linkovany build
; Staticky build (chess-static) nema libSDL2, tento stub nahradi
; gfx/sdl.o a vsetky SDL funkcie hlasia zlyhanie - engine padne
; automaticky naspat do textoveho modu.
; ============================================================

DEFAULT REL

; ============================================================
section .bss

global sdl_window, sdl_surface
sdl_window:     resq 1
sdl_surface:    resq 1

; ============================================================
section .rodata

msg_sdl_stub:       db "SDL nie je dostupny v statickom builde (chess-static).", 10
msg_sdl_stub_len    equ $ - msg_sdl_stub

; ============================================================
section .text

global sdl_gfx_init, sdl_gfx_close, sdl_gfx_run, sdl_gfx_refresh

%define SYS_WRITE 1

; ------------------------------------------------------------
; sdl_gfx_init - stub: vypise hlasku a vrati 1 (zlyhanie)
; ------------------------------------------------------------
sdl_gfx_init:
    mov eax, SYS_WRITE
    mov edi, 1
    lea rsi, [msg_sdl_stub]
    mov edx, msg_sdl_stub_len
    syscall
    mov eax, 1
    ret

; ------------------------------------------------------------
; sdl_gfx_close / sdl_gfx_run / sdl_gfx_refresh - stub: no-op
; ------------------------------------------------------------
sdl_gfx_close:
sdl_gfx_run:
sdl_gfx_refresh:
    xor eax, eax
    ret