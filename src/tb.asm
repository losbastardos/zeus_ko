; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; tb.asm - Syzygy/Nalimov tablebase interface (E6)
; Realne otvaranie a mmap tabuľky podľa syzygy= v chess.ini je pripravené.
; Plná Syzygy indexácia/probing zostáva na ďalší krok.
; ============================================================

%include "chess.inc"

DEFAULT REL

TB_PATH_MAX equ 256
TB_MMAP_SIZE equ 4096

%define SYS_OPEN    2
%define SYS_CLOSE   3
%define SYS_LSEEK   8
%define SYS_MMAP    9
%define SYS_MUNMAP  11

%define PROT_READ   1
%define MAP_PRIVATE 2
%define MAP_FAILED  -1

%define SEEK_SET    0
%define SEEK_CUR    1
%define SEEK_END    2

section .bss

tb_path:     resb TB_PATH_MAX   ; cesta k tabulkam (null-terminated)
tb_path_len: resq 1             ; dlzka ulozenej cesty (bez NUL)
tb_fd:       resq 1             ; otvoreny fd alebo -1
tb_map:      resq 1             ; mapped adresar/subor
tb_map_size: resq 1             ; dlzka mapovania
tb_file_path: resb TB_PATH_MAX  ; realna cielova cesta k WDL suboru
tb_payload_probe_byte: resb 1   ; debug/bootstrap: precitany bajt z WDL payloadu

section .text

global tb_init, tb_probe_wdl, tb_probe_dtz, tb_piece_count
global tb_path, tb_path_len, tb_map, tb_map_size

extern board, side
extern generate_all_moves, is_in_check, move_count

; ============================================================
; tb_unmap_current - uvolni aktualne mmap mapovanie, ak existuje
; ============================================================
tb_unmap_current:
    push r12
    mov r12, [tb_map]
    test r12, r12
    jz .clear
    mov rax, SYS_MUNMAP
    mov rdi, r12
    mov rsi, [tb_map_size]
    syscall
.clear:
    mov qword [tb_map], 0
    mov qword [tb_map_size], 0
    mov qword [tb_fd], -1
    pop r12
    ret

; ============================================================
; tb_piece_char - prevedie typ figury na znak Q/R/B/N/P
; Vstup: edx = typ figury
; Vystup: al = ASCII znak alebo 0
; ============================================================
tb_piece_char:
    cmp edx, QUEEN
    je .q
    cmp edx, ROOK
    je .r
    cmp edx, BISHOP
    je .b
    cmp edx, KNIGHT
    je .n
    cmp edx, PAWN
    je .p
    xor eax, eax
    ret
.q:
    mov al, 'Q'
    ret
.r:
    mov al, 'R'
    ret
.b:
    mov al, 'B'
    ret
.n:
    mov al, 'N'
    ret
.p:
    mov al, 'P'
    ret

; ============================================================
; tb_build_wdl_path - pripravi cestu k *.rtbw podla materialu
; Vstup: r13d = white non-king piece (0/typ), r14d = black non-king piece
; Vystup: rdi = cesta, eax = 1 success / 0 fail
; Pozn.: ak tb_path uz konci na .rtbw/.rtbz, pouzije sa priamo
; ============================================================
tb_build_wdl_path:
    push rbx
    push rcx
    push rdx
    push r8
    push r9

    ; prazdna cesta -> fail
    lea rdi, [tb_path]
    cmp byte [rdi], 0
    jne .len
    xor eax, eax
    jmp .ret

.len:
    xor rcx, rcx
.len_loop:
    cmp rcx, TB_PATH_MAX - 1
    jae .dir_mode
    cmp byte [rdi + rcx], 0
    je .have_len
    inc rcx
    jmp .len_loop

.have_len:
    ; priame subory: *.rtbw / *.rtbz
    cmp rcx, 5
    jb .dir_mode
    movzx eax, byte [rdi + rcx - 5]
    cmp al, '.'
    jne .dir_mode
    movzx eax, byte [rdi + rcx - 4]
    cmp al, 'r'
    jne .dir_mode
    movzx eax, byte [rdi + rcx - 3]
    cmp al, 't'
    jne .dir_mode
    movzx eax, byte [rdi + rcx - 2]
    cmp al, 'b'
    jne .dir_mode
    movzx eax, byte [rdi + rcx - 1]
    cmp al, 'w'
    je .direct
    cmp al, 'z'
    je .direct
    jmp .dir_mode

.direct:
    mov eax, 1
    jmp .ret

.dir_mode:
    ; skopiruj base dir do tb_file_path
    lea rsi, [tb_path]
    lea rdi, [tb_file_path]
    xor r8, r8
.copy_dir:
    cmp r8, TB_PATH_MAX - 1
    jae .fail
    movzx eax, byte [rsi + r8]
    test al, al
    jz .after_dir
    mov [rdi + r8], al
    inc r8
    jmp .copy_dir

.after_dir:
    ; pridaj / ak chyba
    test r8, r8
    jz .add_slash
    movzx eax, byte [rdi + r8 - 1]
    cmp al, '/'
    je .name_start
.add_slash:
    cmp r8, TB_PATH_MAX - 1
    jae .fail
    mov byte [rdi + r8], '/'
    inc r8

.name_start:
    ; canonical: K{W}v{B}K / K{W}vK / Kv{B}K / KvK
    cmp r8, TB_PATH_MAX - 1
    jae .fail
    mov byte [rdi + r8], 'K'
    inc r8

    test r13d, r13d
    jz .no_white_piece
    mov edx, r13d
    call tb_piece_char
    test al, al
    jz .fail
    cmp r8, TB_PATH_MAX - 1
    jae .fail
    mov [rdi + r8], al
    inc r8

.no_white_piece:
    cmp r8, TB_PATH_MAX - 1
    jae .fail
    mov byte [rdi + r8], 'v'
    inc r8

    test r14d, r14d
    jz .no_black_piece
    mov edx, r14d
    call tb_piece_char
    test al, al
    jz .fail
    cmp r8, TB_PATH_MAX - 1
    jae .fail
    mov [rdi + r8], al
    inc r8

.no_black_piece:
    cmp r8, TB_PATH_MAX - 1
    jae .fail
    mov byte [rdi + r8], 'K'
    inc r8

    ; suffix .rtbw
    cmp r8, TB_PATH_MAX - 6
    ja .fail
    mov byte [rdi + r8], '.'
    mov byte [rdi + r8 + 1], 'r'
    mov byte [rdi + r8 + 2], 't'
    mov byte [rdi + r8 + 3], 'b'
    mov byte [rdi + r8 + 4], 'w'
    mov byte [rdi + r8 + 5], 0

    lea rdi, [tb_file_path]
    mov eax, 1
    jmp .ret

.fail:
    xor eax, eax

.ret:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; tb_init - ulozi cestu k tabulkam do interneho buffra
; Vstup:  rdi = ukazatel na null-terminated retazec
; Vystup: eax = 0 (success)
; ============================================================
tb_init:
    push rbx
    push r12
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

    ; ak existuje predchadzajuce mapovanie, uvolni ho
    call tb_unmap_current
    xor eax, eax
    pop r12
    pop rbx
    ret

; ============================================================
; tb_load_path - open + mmap TB subor, ak cesta existuje
; Vstup:  rdi = cesta
; Vystup: eax = 0 success, 1 fail
; ============================================================
tb_load_path:
    push rbx
    push r12
    mov rbx, rdi
    mov rax, SYS_OPEN
    xor esi, esi                ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js .fail
    mov r12, rax

    mov rax, SYS_LSEEK
    xor esi, esi
    mov edx, SEEK_END
    mov rdi, r12
    syscall
    test rax, rax
    jle .close_fail

    mov [tb_map_size], rax

    mov rax, SYS_MMAP
    xor rdi, rdi
    mov rsi, [tb_map_size]
    mov edx, PROT_READ
    mov r10d, MAP_PRIVATE
    mov r8, r12
    xor r9d, r9d
    syscall
    test rax, rax
    js .close_fail

    mov [tb_map], rax
    ; fd uz nepotrebujeme po mmap
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    mov qword [tb_fd], -1
    xor eax, eax
    jmp .done

.close_fail:
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
.fail:
    mov eax, 1
.done:
    pop r12
    pop rbx
    ret

; ============================================================
; tb_probe_wdl - konzervativny WDL probe
; Vystup: eax = TB_WIN / TB_DRAW / TB_LOSS / TB_NOT_FOUND
; ============================================================
tb_probe_wdl:
    push rbx
    push rcx
    push r12
    push r13
    push r14

    ; Tento krok je zamerany na male (2-3 figurkove) koncovky.
    ; Pri nepoznanych typoch vratime TB_NOT_FOUND.
    call tb_piece_count
    cmp eax, 3
    jg .not_found

    lea rbx, [board]
    xor r13d, r13d          ; white non-king piece type
    xor r14d, r14d          ; black non-king piece type
    xor ecx, ecx
.scan:
    cmp ecx, 64
    jae .scan_done
    movzx eax, byte [rbx + rcx]
    test eax, eax
    jz .next
    mov edx, eax
    and edx, PIECE_MASK
    cmp edx, KING
    je .next
    test eax, COLOR_MASK
    jz .white_piece
    test r14d, r14d
    jnz .not_found
    mov r14d, edx
    jmp .next
.white_piece:
    test r13d, r13d
    jnz .not_found
    mov r13d, edx
.next:
    inc ecx
    jmp .scan

.scan_done:
    ; skus otvorit/mapovat relevantny WDL subor (ak je nastavena cesta)
    call tb_build_wdl_path
    test eax, eax
    jz .wdl_eval
    push r13
    push r14
    call tb_unmap_current
    call tb_load_path
    pop r14
    pop r13

.wdl_eval:
    ; legal/stalemate guard pre male koncovky
    call generate_all_moves
    movzx eax, word [move_count]
    test eax, eax
    jnz .classify
    movzx eax, byte [side]
    call is_in_check
    test eax, eax
    jnz .loss
    jmp .draw

.classify:
    ; KvK -> draw
    test r13d, r13d
    jnz .white_has_piece
    test r14d, r14d
    jnz .black_has_piece
    mov eax, TB_DRAW
    jmp .done

.white_has_piece:
    test r14d, r14d
    jnz .not_found
    cmp r13d, BISHOP
    je .draw
    cmp r13d, KNIGHT
    je .draw
    cmp r13d, PAWN
    je .pawn_vs_king
    cmp r13d, QUEEN
    je .white_queen
    cmp r13d, ROOK
    je .white_strong
    jmp .not_found

.black_has_piece:
    test r13d, r13d
    jnz .not_found
    cmp r14d, BISHOP
    je .draw
    cmp r14d, KNIGHT
    je .draw
    cmp r14d, PAWN
    je .king_vs_pawn
    cmp r14d, QUEEN
    je .black_queen
    cmp r14d, ROOK
    je .black_strong
    jmp .not_found

.white_queen:
    ; Bootstrap krok: realne citanie mapnuteho WDL payloadu pre KQvK.
    ; Zatial este nedehcodujeme indexaciu celej tabulky, len validujeme pristup.
    mov rax, [tb_map]
    test rax, rax
    jz .not_found
    mov rcx, [tb_map_size]
    cmp rcx, 33
    jb .not_found
    movzx edx, byte [rax + 32]
    mov [tb_payload_probe_byte], dl
    jmp .white_strong

.black_queen:
    ; Analogicky bootstrap pre KvQK.
    mov rax, [tb_map]
    test rax, rax
    jz .not_found
    mov rcx, [tb_map_size]
    cmp rcx, 33
    jb .not_found
    movzx edx, byte [rax + 32]
    mov [tb_payload_probe_byte], dl
    jmp .black_strong

.pawn_vs_king:
    ; Konzervativne: pawnful ending bez plneho decode nechavame na TB decode.
    ; legal/stalemate guard uz bol aplikovany vyssie.
    jmp .not_found

.king_vs_pawn:
    ; Konzervativne: pawnful ending bez plneho decode nechavame na TB decode.
    ; legal/stalemate guard uz bol aplikovany vyssie.
    jmp .not_found

.white_strong:
    movzx eax, byte [side]
    test eax, eax
    jz .win
    jmp .loss

.black_strong:
    movzx eax, byte [side]
    test eax, eax
    jz .loss
    jmp .win

.draw:
    mov eax, TB_DRAW
    jmp .done
.win:
    mov eax, TB_WIN
    jmp .done
.loss:
    mov eax, TB_LOSS
    jmp .done

.not_found:
    mov eax, TB_NOT_FOUND

.done:
    pop r14
    pop r13
    pop r12
    pop rcx
    pop rbx
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