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
TB_WDL_MAGIC equ 0x5d23e871
TB_DTZ_MAGIC equ 0xa50c66d7

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
tb_loaded_path: resb TB_PATH_MAX ; naposledy uspesne namapovana cesta
tb_wdl_payload_probe_byte: resb 1 ; debug/bootstrap: precitany bajt z WDL payloadu
tb_dtz_payload_probe_byte: resb 1 ; debug/bootstrap: precitany bajt z DTZ payloadu
tb_wdl_payload_probe_off: resq 1  ; debug/bootstrap: offset payload probe bajtu (0 = n/a)
tb_dtz_payload_probe_off: resq 1  ; debug/bootstrap: offset payload probe bajtu (0 = n/a)
tb_wdl_header_flags: resb 1       ; debug: data[4] flags pre WDL tabulku
tb_dtz_header_flags: resb 1       ; debug: data[4] flags pre DTZ tabulku
tb_wdl_pairs_header_off: resq 1   ; debug: offset setup_pairs hlavy (WDL)
tb_dtz_pairs_header_off: resq 1   ; debug: offset setup_pairs hlavy (DTZ)
tb_wdl_pairs_num_blocks: resd 1   ; debug: num_blocks z setup_pairs (WDL)
tb_dtz_pairs_num_blocks: resd 1   ; debug: num_blocks z setup_pairs (DTZ)
tb_wdl_pairs_num_syms: resd 1     ; debug: num_syms z setup_pairs (WDL)
tb_dtz_pairs_num_syms: resd 1     ; debug: num_syms z setup_pairs (DTZ)
tb_wdl_pairs_blocksize: resb 1    ; debug: blocksize (WDL)
tb_dtz_pairs_blocksize: resb 1    ; debug: blocksize (DTZ)
tb_wdl_pairs_idxbits: resb 1      ; debug: idxbits (WDL)
tb_dtz_pairs_idxbits: resb 1      ; debug: idxbits (DTZ)
tb_wdl_pairs_is_const: resb 1     ; debug: 1 ak constant table (WDL)
tb_dtz_pairs_is_const: resb 1     ; debug: 1 ak constant table (DTZ)

section .text

global tb_init, tb_probe_wdl, tb_probe_dtz, tb_piece_count
global tb_path, tb_path_len, tb_map, tb_map_size, tb_file_path
global tb_wdl_payload_probe_byte, tb_dtz_payload_probe_byte
global tb_wdl_payload_probe_off, tb_dtz_payload_probe_off
global tb_wdl_header_flags, tb_dtz_header_flags
global tb_wdl_pairs_header_off, tb_dtz_pairs_header_off
global tb_wdl_pairs_num_blocks, tb_dtz_pairs_num_blocks
global tb_wdl_pairs_num_syms, tb_dtz_pairs_num_syms
global tb_wdl_pairs_blocksize, tb_dtz_pairs_blocksize
global tb_wdl_pairs_idxbits, tb_dtz_pairs_idxbits
global tb_wdl_pairs_is_const, tb_dtz_pairs_is_const

extern board, side
extern generate_all_moves, is_in_check, move_count
extern filter_legal_moves

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
    mov byte [tb_loaded_path], 0
    pop r12
    ret

; ============================================================
; tb_str_eq - porovna dva NUL-terminated retazce
; Vstup: rdi = s1, rsi = s2
; Vystup: eax = 1 (equal) / 0 (not equal)
; ============================================================
tb_str_eq:
    push rcx
    xor ecx, ecx
.loop:
    cmp rcx, TB_PATH_MAX
    jae .equal
    movzx eax, byte [rdi + rcx]
    movzx edx, byte [rsi + rcx]
    cmp eax, edx
    jne .not_equal
    test al, al
    jz .equal
    inc rcx
    jmp .loop

.equal:
    mov eax, 1
    pop rcx
    ret

.not_equal:
    xor eax, eax
    pop rcx
    ret

; ============================================================
; tb_copy_path - skopiruje NUL-terminated cestu
; Vstup: rdi = dst, rsi = src
; ============================================================
tb_copy_path:
    push rcx
    xor ecx, ecx
.copy:
    cmp rcx, TB_PATH_MAX - 1
    jae .done
    movzx eax, byte [rsi + rcx]
    mov [rdi + rcx], al
    inc rcx
    test al, al
    jnz .copy
.done:
    mov byte [rdi + TB_PATH_MAX - 1], 0
    pop rcx
    ret

; ============================================================
; tb_ensure_loaded_path - mapuj subor len ked nie je uz mapnuty
; Vstup: rdi = cesta
; Vystup: eax = 0 success, 1 fail
; ============================================================
tb_ensure_loaded_path:
    push rbx
    push r12
    mov rbx, rdi

    mov r12, [tb_map]
    test r12, r12
    jz .reload
    cmp qword [tb_map_size], 0
    jle .reload

    lea rdi, [tb_loaded_path]
    mov rsi, rbx
    call tb_str_eq
    test eax, eax
    jz .reload
    xor eax, eax
    jmp .done

.reload:
    call tb_unmap_current
    mov rdi, rbx
    call tb_load_path
    test eax, eax
    jnz .fail
    lea rdi, [tb_loaded_path]
    mov rsi, rbx
    call tb_copy_path
    xor eax, eax
    jmp .done

.fail:
    mov eax, 1

.done:
    pop r12
    pop rbx
    ret

; ============================================================
; tb_find_pairs_probe - najde setup_pairs hlavu a vrati nasledny offset
; Vstup:  rdi = map_ptr, rsi = map_size
; Vystup: eax = 0 fail, 1 constant setup_pairs, 2 non-constant setup_pairs
;         r8  = header offset setup_pairs
;         r9  = probe offset (next pointer setup_pairs)
;         dl  = probe byte (0 ak n/a)
;         r10d = num_blocks (0 pri constant)
;         r11d = num_syms (0 pri constant)
;         bl = blocksize (0 pri constant)
;         cl = idxbits (0 pri constant)
;         al = is_const (1/0) pri uspechu
; Pozn.: probe offset je "next" pointer zo setup_pairs, nie fixny +32.
; ============================================================
tb_find_pairs_probe:
    push rbx
    push r12
    push r13

    xor eax, eax
    xor r8, r8
    xor r9, r9
    xor edx, edx
    xor r10d, r10d
    xor r11d, r11d
    xor ebx, ebx
    xor ecx, ecx

    test rdi, rdi
    jz .fail
    cmp rsi, 16
    jb .fail
    mov r12, rsi                ; map_size

    ; Syzygy data cast zacina za uvodnou preambulou, hladame po parnych offsetoch.
    mov r13, 10

.scan_loop:
    ; Potrebujeme aspon 12 bajtov na nekonstantny setup_pairs header.
    mov rax, r13
    add rax, 12
    cmp rax, r12
    ja .fail

    movzx eax, byte [rdi + r13]
    test al, 0x80
    jz .non_const
    ; Constant setup_pairs ma byt striktne 0x80, inak je to cast preambuly.
    cmp al, 0x80
    jne .next_candidate

    ; Constant-table varianta: 2 bajty (flag|min_len), next = off + 2.
    mov r8, r13
    lea r9, [r13 + 2]
    cmp r9, r12
    ja .next_candidate
    cmp r9, r12
    je .const_ok
    movzx edx, byte [rdi + r9]
.const_ok:
    mov eax, 1
    jmp .ret

.non_const:
    movzx ebx, byte [rdi + r13 + 1]   ; blocksize
    cmp ebx, 1
    jb .next_candidate
    cmp ebx, 31
    ja .next_candidate

    movzx ecx, byte [rdi + r13 + 2]   ; idxbits
    cmp ecx, 1
    jb .next_candidate
    cmp ecx, 31
    ja .next_candidate

    mov r10d, dword [rdi + r13 + 4]   ; real_num_blocks
    test r10d, r10d
    jz .next_candidate

    movzx r11d, byte [rdi + r13 + 3]  ; extra blocks
    add r10d, r11d

    movzx eax, byte [rdi + r13 + 8]   ; max_len
    movzx edx, byte [rdi + r13 + 9]   ; min_len
    cmp eax, edx
    jb .next_candidate
    cmp eax, 63
    ja .next_candidate

    ; h = max_len - min_len + 1
    sub eax, edx
    inc eax
    mov esi, eax

    ; num_syms je na [off + 10 + 2*h]
    lea rax, [r13 + 10]
    lea rax, [rax + rsi*2]
    lea rdx, [rax + 2]
    cmp rdx, r12
    ja .next_candidate

    movzx r11d, word [rdi + rax]      ; num_syms
    test r11d, r11d
    jz .next_candidate
    cmp r11d, 4096
    ja .next_candidate

    ; next = off + 12 + 2*h + 3*num_syms + (num_syms & 1)
    mov r8, r13
    lea r9, [r13 + 12]
    lea r9, [r9 + rsi*2]
    lea rax, [r11 + r11*2]
    add r9, rax
    mov eax, r11d
    and eax, 1
    add r9, rax
    cmp r9, r12
    ja .next_candidate

    xor edx, edx
    cmp r9, r12
    je .pairs_ok
    movzx edx, byte [rdi + r9]

.pairs_ok:
    mov eax, 2
    jmp .ret

.next_candidate:
    add r13, 2
    cmp r13, 256
    jb .scan_loop

.fail:
    xor eax, eax
    xor r8, r8
    xor r9, r9
    xor edx, edx
    xor r10d, r10d
    xor r11d, r11d
    xor ebx, ebx
    xor ecx, ecx

.ret:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; tb_validate_map_and_probe - validuj magic a vrat debug payload byte
; Vstup:  rdi = map_ptr, rsi = map_size, edx = expected magic
; Vystup: eax = 1 valid / 0 invalid
;         r8  = payload probe offset (0 = n/a)
;         dl  = payload probe byte (0 ak n/a)
; Pozn.: payload probe offset je odvodeny zo setup_pairs parsera.
; ============================================================
tb_validate_map_and_probe:
    ; map + minimalna hlava
    test rdi, rdi
    jz .fail
    cmp rsi, 4
    jb .fail

    mov ecx, dword [rdi]
    cmp ecx, edx
    jne .fail

    ; debug payload probe z realneho setup_pairs parsera
    call tb_find_pairs_probe
    test eax, eax
    jz .clear_probe
    mov r8, r9
    mov eax, 1
    ret

.clear_probe:
    xor r8, r8
    xor edx, edx

.ok:
    mov eax, 1
    ret

.fail:
    xor eax, eax
    xor r8, r8
    xor edx, edx
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
    ; pre diagnostiku chceme mat vzdy aktualnu realnu cestu v tb_file_path
    lea rsi, [tb_path]
    lea rdi, [tb_file_path]
    xor r8, r8
.copy_direct:
    cmp r8, TB_PATH_MAX - 1
    jae .copy_direct_end
    movzx eax, byte [rsi + r8]
    mov [rdi + r8], al
    inc r8
    test al, al
    jnz .copy_direct
.copy_direct_end:
    mov byte [rdi + TB_PATH_MAX - 1], 0

    ; WDL probe potrebuje .rtbw. Ak uzivatel zada priamo .rtbz,
    ; prehod suffix na .rtbw (DTZ probe si ho neskor prehodi naspat).
    cmp rcx, 1
    jb .direct_done
    cmp byte [rdi + rcx - 1], 'z'
    jne .direct_done
    mov byte [rdi + rcx - 1], 'w'

.direct_done:
    lea rdi, [tb_file_path]
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

    mov byte [tb_wdl_payload_probe_byte], 0
    mov qword [tb_wdl_payload_probe_off], 0
    mov byte [tb_wdl_header_flags], 0
    mov qword [tb_wdl_pairs_header_off], 0
    mov dword [tb_wdl_pairs_num_blocks], 0
    mov dword [tb_wdl_pairs_num_syms], 0
    mov byte [tb_wdl_pairs_blocksize], 0
    mov byte [tb_wdl_pairs_idxbits], 0
    mov byte [tb_wdl_pairs_is_const], 0
    mov byte [tb_file_path], 0

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
    jz .not_found
    lea rdi, [tb_file_path]
    call tb_ensure_loaded_path
    test eax, eax
    jnz .not_found

    ; Syzygy regular WDL magic guard + payload probe byte
    mov rdi, [tb_map]
    mov rsi, [tb_map_size]
    mov edx, TB_WDL_MAGIC
    call tb_validate_map_and_probe
    test eax, eax
    jz .not_found
    mov [tb_wdl_payload_probe_off], r8
    mov [tb_wdl_payload_probe_byte], dl

    ; metadata setup_pairs parsera pre dalsi decode krok
    mov rdi, [tb_map]
    mov rsi, [tb_map_size]
    call tb_find_pairs_probe
    test eax, eax
    jz .wdl_meta_done
    mov [tb_wdl_pairs_header_off], r8
    mov [tb_wdl_pairs_num_blocks], r10d
    mov [tb_wdl_pairs_num_syms], r11d
    mov [tb_wdl_pairs_blocksize], bl
    mov [tb_wdl_pairs_idxbits], cl
    cmp eax, 1
    jne .wdl_not_const
    mov byte [tb_wdl_pairs_is_const], 1
    jmp .wdl_meta_done
.wdl_not_const:
    mov byte [tb_wdl_pairs_is_const], 0
.wdl_meta_done:

    mov rax, [tb_map]
    mov dl, byte [rax + 4]
    mov [tb_wdl_header_flags], dl

.wdl_eval:
    ; legal/stalemate guard pre male koncovky (nutne cez legal moves)
    call generate_all_moves
    call filter_legal_moves
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
    ; KQvK: zatial klasifikacia heuristikou, payload probe bezi globalne vyssie.
    jmp .white_strong

.black_queen:
    ; KvQK: zatial klasifikacia heuristikou, payload probe bezi globalne vyssie.
    jmp .black_strong

.pawn_vs_king:
    ; KPvK prakticka klasifikacia (bez plneho WDL decode):
    ; ak obranca stihne promotivne policko, povazuj za draw, inak win.
    lea rbx, [board]
    mov r8d, -1              ; white pawn sq
    mov r9d, -1              ; black king sq
    xor ecx, ecx
.kpvk_scan:
    cmp ecx, 64
    jae .kpvk_have
    movzx eax, byte [rbx + rcx]
    test eax, eax
    jz .kpvk_next
    mov edx, eax
    and edx, PIECE_MASK
    cmp edx, PAWN
    jne .kpvk_try_king
    test eax, COLOR_MASK
    jnz .kpvk_next
    mov r8d, ecx
    jmp .kpvk_next
.kpvk_try_king:
    cmp edx, KING
    jne .kpvk_next
    test eax, COLOR_MASK
    jz .kpvk_next
    mov r9d, ecx
.kpvk_next:
    inc ecx
    jmp .kpvk_scan

.kpvk_have:
    cmp r8d, 0
    jl .draw
    cmp r9d, 0
    jl .draw

    ; pawn file/rank
    mov eax, r8d
    and eax, 7
    mov r10d, eax            ; pawn file
    mov eax, r8d
    shr eax, 3
    mov r11d, eax            ; pawn rank

    ; black king file/rank
    mov eax, r9d
    and eax, 7
    mov r12d, eax            ; king file
    mov eax, r9d
    shr eax, 3
    mov r13d, eax            ; king rank

    ; okamzita blokada pred pesiakom na rovnakom file = draw
    cmp r12d, r10d
    jne .kpvk_steps
    cmp r13d, r11d
    jle .kpvk_steps
    jmp .draw

.kpvk_steps:
    ; steps do premeny white pawnu
    mov eax, 7
    sub eax, r11d
    mov r14d, eax

    ; king distance ku promotivnemu polu (file pawnu, rank 7)
    mov eax, r12d
    sub eax, r10d
    jns .kpvk_abs_file
    neg eax
.kpvk_abs_file:
    mov edx, eax
    mov eax, r13d
    sub eax, 7
    jns .kpvk_abs_rank
    neg eax
.kpvk_abs_rank:
    cmp edx, eax
    jge .kpvk_have_dist
    mov edx, eax
.kpvk_have_dist:

    ; ak white na tahu, obranca ma efektivne o tempo menej
    movzx eax, byte [side]
    test eax, eax
    jnz .kpvk_no_tempo
    dec r14d
.kpvk_no_tempo:
    cmp r14d, 0
    jl .white_strong
    ; Konzervativny fallback: hranicne opozicne pozicie casto vychadzaju na draw,
    ; preto obrancovi davame +1 tempo rezervu oproti cistej vzdialenosti.
    mov eax, r14d
    inc eax
    cmp edx, eax
    jle .draw
    jmp .white_strong

.king_vs_pawn:
    ; KvPK prakticka klasifikacia, symetria pre cierneho pesiaka.
    lea rbx, [board]
    mov r8d, -1              ; black pawn sq
    mov r9d, -1              ; white king sq
    xor ecx, ecx
.kvpk_scan:
    cmp ecx, 64
    jae .kvpk_have
    movzx eax, byte [rbx + rcx]
    test eax, eax
    jz .kvpk_next
    mov edx, eax
    and edx, PIECE_MASK
    cmp edx, PAWN
    jne .kvpk_try_king
    test eax, COLOR_MASK
    jz .kvpk_next
    mov r8d, ecx
    jmp .kvpk_next
.kvpk_try_king:
    cmp edx, KING
    jne .kvpk_next
    test eax, COLOR_MASK
    jnz .kvpk_next
    mov r9d, ecx
.kvpk_next:
    inc ecx
    jmp .kvpk_scan

.kvpk_have:
    cmp r8d, 0
    jl .draw
    cmp r9d, 0
    jl .draw

    ; pawn file/rank
    mov eax, r8d
    and eax, 7
    mov r10d, eax            ; pawn file
    mov eax, r8d
    shr eax, 3
    mov r11d, eax            ; pawn rank

    ; white king file/rank
    mov eax, r9d
    and eax, 7
    mov r12d, eax            ; king file
    mov eax, r9d
    shr eax, 3
    mov r13d, eax            ; king rank

    ; okamzita blokada pred pesiakom na rovnakom file = draw
    cmp r12d, r10d
    jne .kvpk_steps
    cmp r13d, r11d
    jge .kvpk_steps
    jmp .draw

.kvpk_steps:
    ; steps do premeny black pawnu (na rank 0)
    mov eax, r11d
    mov r14d, eax

    ; king distance ku promotivnemu polu (file pawnu, rank 0)
    mov eax, r12d
    sub eax, r10d
    jns .kvpk_abs_file
    neg eax
.kvpk_abs_file:
    mov edx, eax
    mov eax, r13d
    cmp edx, eax
    jge .kvpk_have_dist
    mov edx, eax
.kvpk_have_dist:

    ; ak black na tahu, obranca ma efektivne o tempo menej
    movzx eax, byte [side]
    test eax, eax
    jz .kvpk_no_tempo
    dec r14d
.kvpk_no_tempo:
    cmp r14d, 0
    jl .black_strong
    ; Konzervativny fallback: hranicne opozicne pozicie casto vychadzaju na draw,
    ; preto obrancovi davame +1 tempo rezervu oproti cistej vzdialenosti.
    mov eax, r14d
    inc eax
    cmp edx, eax
    jle .draw
    jmp .black_strong

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
; tb_probe_dtz - DTZ probe (bootstrap)
; Vystup: eax = DTZ alebo TB_NOT_FOUND
; ============================================================
tb_probe_dtz:
    push rbx
    push rcx
    push r12
    push r13
    push r14

    mov byte [tb_dtz_payload_probe_byte], 0
    mov qword [tb_dtz_payload_probe_off], 0
    mov byte [tb_dtz_header_flags], 0
    mov qword [tb_dtz_pairs_header_off], 0
    mov dword [tb_dtz_pairs_num_blocks], 0
    mov dword [tb_dtz_pairs_num_syms], 0
    mov byte [tb_dtz_pairs_blocksize], 0
    mov byte [tb_dtz_pairs_idxbits], 0
    mov byte [tb_dtz_pairs_is_const], 0
    mov byte [tb_file_path], 0

    ; DTZ bootstrap zatial len pre male 2-3 figurkove koncovky.
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
    ; Pred DTZ mapovanim si zober WDL klasifikaciu rovnakej pozicie.
    ; Vdaka tomu sa DTZ bootstrap vie riadit realnym WDL bez rozbitia
    ; DTZ map_bytes/path diagnostiky.
    call tb_probe_wdl
    mov r12d, eax

    ; Postav cestu podla materialu, potom prepni suffix na .rtbz.
    call tb_build_wdl_path
    test eax, eax
    jz .not_found

    lea rbx, [tb_file_path]

    xor rcx, rcx
.len_loop:
    cmp rcx, TB_PATH_MAX - 1
    jae .not_found
    cmp byte [rbx + rcx], 0
    je .have_len
    inc rcx
    jmp .len_loop

.have_len:
    cmp rcx, 1
    jb .not_found
    cmp byte [rbx + rcx - 1], 'w'
    je .to_rtbz
    cmp byte [rbx + rcx - 1], 'z'
    je .load
    jmp .not_found

.to_rtbz:
    mov byte [rbx + rcx - 1], 'z'

.load:
    lea rdi, [tb_file_path]
    call tb_ensure_loaded_path
    test eax, eax
    jnz .not_found

    ; Syzygy regular DTZ magic guard + payload probe byte
    mov rdi, [tb_map]
    mov rsi, [tb_map_size]
    mov edx, TB_DTZ_MAGIC
    call tb_validate_map_and_probe
    test eax, eax
    jz .not_found
    mov [tb_dtz_payload_probe_off], r8
    mov [tb_dtz_payload_probe_byte], dl

    ; metadata setup_pairs parsera pre dalsi decode krok
    mov rdi, [tb_map]
    mov rsi, [tb_map_size]
    call tb_find_pairs_probe
    test eax, eax
    jz .dtz_meta_done
    mov [tb_dtz_pairs_header_off], r8
    mov [tb_dtz_pairs_num_blocks], r10d
    mov [tb_dtz_pairs_num_syms], r11d
    mov [tb_dtz_pairs_blocksize], bl
    mov [tb_dtz_pairs_idxbits], cl
    cmp eax, 1
    jne .dtz_not_const
    mov byte [tb_dtz_pairs_is_const], 1
    jmp .dtz_meta_done
.dtz_not_const:
    mov byte [tb_dtz_pairs_is_const], 0
.dtz_meta_done:

    mov rax, [tb_map]
    mov dl, byte [rax + 4]
    mov [tb_dtz_header_flags], dl

    ; DTZ bootstrap vratime podla WDL vysledku rovnakej pozicie,
    ; aby sa male koncovky (najma KPvK/KvPK draw) neklasifikovali chybne.
    cmp r12d, TB_WIN
    je .dtz_win
    cmp r12d, TB_LOSS
    je .dtz_loss
    cmp r12d, TB_DRAW
    je .dtz_draw

    ; Kym nebude plny decode .rtbz, vrat konzervativnu klasifikaciu.
    test r13d, r13d
    jnz .white_has_piece
    test r14d, r14d
    jnz .black_has_piece
    jmp .dtz_draw

.white_has_piece:
    test r14d, r14d
    jnz .not_found
    cmp r13d, BISHOP
    je .dtz_draw
    cmp r13d, KNIGHT
    je .dtz_draw
    cmp r13d, PAWN
    je .dtz_pawn_vs_king
    movzx eax, byte [side]
    test eax, eax
    jz .dtz_win
    jmp .dtz_loss

.black_has_piece:
    test r13d, r13d
    jnz .not_found
    cmp r14d, BISHOP
    je .dtz_draw
    cmp r14d, KNIGHT
    je .dtz_draw
    cmp r14d, PAWN
    je .dtz_king_vs_pawn
    movzx eax, byte [side]
    test eax, eax
    jz .dtz_loss
    jmp .dtz_win

.dtz_pawn_vs_king:
    ; KPvK fallback pre DTZ klasifikaciu.
    lea rbx, [board]
    mov r8d, -1              ; white pawn sq
    mov r9d, -1              ; black king sq
    xor ecx, ecx
.dtz_kpvk_scan:
    cmp ecx, 64
    jae .dtz_kpvk_have
    movzx eax, byte [rbx + rcx]
    test eax, eax
    jz .dtz_kpvk_next
    mov edx, eax
    and edx, PIECE_MASK
    cmp edx, PAWN
    jne .dtz_kpvk_try_king
    test eax, COLOR_MASK
    jnz .dtz_kpvk_next
    mov r8d, ecx
    jmp .dtz_kpvk_next
.dtz_kpvk_try_king:
    cmp edx, KING
    jne .dtz_kpvk_next
    test eax, COLOR_MASK
    jz .dtz_kpvk_next
    mov r9d, ecx
.dtz_kpvk_next:
    inc ecx
    jmp .dtz_kpvk_scan

.dtz_kpvk_have:
    cmp r8d, 0
    jl .dtz_draw
    cmp r9d, 0
    jl .dtz_draw

    mov eax, r8d
    and eax, 7
    mov r10d, eax            ; pawn file
    mov eax, r8d
    shr eax, 3
    mov r11d, eax            ; pawn rank

    mov eax, r9d
    and eax, 7
    mov r12d, eax            ; king file
    mov eax, r9d
    shr eax, 3
    mov r13d, eax            ; king rank

    cmp r12d, r10d
    jne .dtz_kpvk_steps
    cmp r13d, r11d
    jle .dtz_kpvk_steps
    jmp .dtz_draw

.dtz_kpvk_steps:
    mov eax, 7
    sub eax, r11d
    mov r14d, eax

    mov eax, r12d
    sub eax, r10d
    jns .dtz_kpvk_abs_file
    neg eax
.dtz_kpvk_abs_file:
    mov edx, eax
    mov eax, r13d
    sub eax, 7
    jns .dtz_kpvk_abs_rank
    neg eax
.dtz_kpvk_abs_rank:
    cmp edx, eax
    jge .dtz_kpvk_have_dist
    mov edx, eax
.dtz_kpvk_have_dist:

    movzx eax, byte [side]
    test eax, eax
    jnz .dtz_kpvk_no_tempo
    dec r14d
.dtz_kpvk_no_tempo:
    cmp r14d, 0
    jl .dtz_win
    cmp edx, r14d
    jle .dtz_draw
    jmp .dtz_win

.dtz_king_vs_pawn:
    ; KvPK fallback pre DTZ klasifikaciu.
    lea rbx, [board]
    mov r8d, -1              ; black pawn sq
    mov r9d, -1              ; white king sq
    xor ecx, ecx
.dtz_kvpk_scan:
    cmp ecx, 64
    jae .dtz_kvpk_have
    movzx eax, byte [rbx + rcx]
    test eax, eax
    jz .dtz_kvpk_next
    mov edx, eax
    and edx, PIECE_MASK
    cmp edx, PAWN
    jne .dtz_kvpk_try_king
    test eax, COLOR_MASK
    jz .dtz_kvpk_next
    mov r8d, ecx
    jmp .dtz_kvpk_next
.dtz_kvpk_try_king:
    cmp edx, KING
    jne .dtz_kvpk_next
    test eax, COLOR_MASK
    jnz .dtz_kvpk_next
    mov r9d, ecx
.dtz_kvpk_next:
    inc ecx
    jmp .dtz_kvpk_scan

.dtz_kvpk_have:
    cmp r8d, 0
    jl .dtz_draw
    cmp r9d, 0
    jl .dtz_draw

    mov eax, r8d
    and eax, 7
    mov r10d, eax            ; pawn file
    mov eax, r8d
    shr eax, 3
    mov r11d, eax            ; pawn rank

    mov eax, r9d
    and eax, 7
    mov r12d, eax            ; king file
    mov eax, r9d
    shr eax, 3
    mov r13d, eax            ; king rank

    cmp r12d, r10d
    jne .dtz_kvpk_steps
    cmp r13d, r11d
    jge .dtz_kvpk_steps
    jmp .dtz_draw

.dtz_kvpk_steps:
    mov eax, r11d
    mov r14d, eax

    mov eax, r12d
    sub eax, r10d
    jns .dtz_kvpk_abs_file
    neg eax
.dtz_kvpk_abs_file:
    mov edx, eax
    mov eax, r13d
    cmp edx, eax
    jge .dtz_kvpk_have_dist
    mov edx, eax
.dtz_kvpk_have_dist:

    movzx eax, byte [side]
    test eax, eax
    jz .dtz_kvpk_no_tempo
    dec r14d
.dtz_kvpk_no_tempo:
    cmp r14d, 0
    jl .dtz_loss
    cmp edx, r14d
    jle .dtz_draw
    jmp .dtz_loss

.dtz_draw:
    xor eax, eax
    jmp .done

.dtz_win:
    mov eax, 1
    jmp .done

.dtz_loss:
    mov eax, 2
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