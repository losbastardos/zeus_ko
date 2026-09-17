; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; eval.asm - tapered evaluacia (MG/EG interpolacia)
; ============================================================

%include "chess.inc"
%include "eval_tune.inc"
%include "pst_tune.inc"

DEFAULT REL

section .data

global evaluate, eval_dbg_mg, eval_dbg_eg
eval_dbg_mg: dd 0
eval_dbg_eg: dd 0

; MG material = povodne hodnoty; EG: pesiaci viac, leziece menej
material_mg:
    dd 0            ; EMPTY
    dd 100          ; PAWN
    dd 320          ; KNIGHT
    dd 330          ; BISHOP
    dd 500          ; ROOK
    dd 900          ; QUEEN
    dd 20000        ; KING

material_eg:
    dd 0            ; EMPTY
    dd 120          ; PAWN
    dd 300          ; KNIGHT
    dd 310          ; BISHOP
    dd 520          ; ROOK
    dd 940          ; QUEEN
    dd 20000        ; KING

; vaha fazy podla typu figury (non-pawn material; max 24 = 4N+4B+4R+2Q... 2*(1+1+2+4))
phase_weights:
    db 0            ; EMPTY
    db 0            ; PAWN
    db 1            ; KNIGHT
    db 1            ; BISHOP
    db 2            ; ROOK
    db 4            ; QUEEN
    db 0            ; KING

; runtime PST tabulky (naplni pst_init z pst_tune.inc zakladov * scale,
; alebo nnue_load z net.nnue; layout [own 7x64][enemy 7x64] per faza)
section .bss
global pst_runtime_mg, pst_runtime_eg
pst_runtime_mg: resb 64*14
pst_runtime_eg: resb 64*14

section .data
global pst_ptrs_mg, pst_ptrs_eg
; index: 0..6 = own (EMPTY..KING), 7..13 = enemy (EMPTY..KING)
pst_ptrs_mg:
    dq pst_runtime_mg + 0*64
    dq pst_runtime_mg + 1*64
    dq pst_runtime_mg + 2*64
    dq pst_runtime_mg + 3*64
    dq pst_runtime_mg + 4*64
    dq pst_runtime_mg + 5*64
    dq pst_runtime_mg + 6*64
    dq pst_runtime_mg + 7*64
    dq pst_runtime_mg + 8*64
    dq pst_runtime_mg + 9*64
    dq pst_runtime_mg + 10*64
    dq pst_runtime_mg + 11*64
    dq pst_runtime_mg + 12*64
    dq pst_runtime_mg + 13*64

pst_ptrs_eg:
    dq pst_runtime_eg + 0*64
    dq pst_runtime_eg + 1*64
    dq pst_runtime_eg + 2*64
    dq pst_runtime_eg + 3*64
    dq pst_runtime_eg + 4*64
    dq pst_runtime_eg + 5*64
    dq pst_runtime_eg + 6*64
    dq pst_runtime_eg + 7*64
    dq pst_runtime_eg + 8*64
    dq pst_runtime_eg + 9*64
    dq pst_runtime_eg + 10*64
    dq pst_runtime_eg + 11*64
    dq pst_runtime_eg + 12*64
    dq pst_runtime_eg + 13*64

; masky stlpcov (bit f, f+8, ...) pre pawn structure / open files
file_masks:
    dq 0x0101010101010101
    dq 0x0202020202020202
    dq 0x0404040404040404
    dq 0x0808080808080808
    dq 0x1010101010101010
    dq 0x2020202020202020
    dq 0x4040404040404040
    dq 0x8080808080808080

; rank r: bity policok s VYSSIM rankom (r+1..7) - blockery pesiaca
hi_rank_masks:
    dq 0xFFFFFFFFFFFFFF00
    dq 0xFFFFFFFFFFFF0000
    dq 0xFFFFFFFFFF000000
    dq 0xFFFFFFFF00000000
    dq 0xFFFFFF0000000000
    dq 0xFFFF000000000000
    dq 0xFF00000000000000
    dq 0

; rank r: bity policok s NIZSIM rankom (0..r-1)
lo_rank_masks:
    dq 0
    dq 0xFF
    dq 0xFFFF
    dq 0xFFFFFF
    dq 0xFFFFFFFF
    dq 0xFFFFFFFFFF
    dq 0xFFFFFFFFFFFF
    dq 0xFFFFFFFFFFFFFF



section .text

extern board
extern side, eval_mode

; ============================================================
; MOB_WALK df, dr, sliding - krok/luc mobility z policka
; Zrata dosiahnutelne policka do ecx. Register set mobility pasu:
;   rbx = board base, r12 = from, r13d = farba (0/8),
;   r10d/r11d = zakladny file/rank, ecx = counter,
;   r8d/r9d = kurzor file/rank, eax/edx/esi/edi = scratch
; ============================================================
%macro MOB_WALK 3
    mov r8d, r10d
    add r8d, %1
    mov r9d, r11d
    add r9d, %2
%%step:
    cmp r8d, 7
    ja %%done               ; mimo 0..7 (unsigned chyti aj zaporne)
    cmp r9d, 7
    ja %%done
    mov esi, r9d
    shl esi, 3
    add esi, r8d            ; cielove policko
    movzx edi, byte [rbx + rsi]
    test edi, edi
    jz %%empty
    mov esi, edi
    and esi, COLOR_MASK
    cmp esi, r13d
    je %%done               ; vlastna figura: blokuje (nepocitaj)
    inc ecx                 ; nepriatelska figura: branie dostupne
    jmp %%done
%%empty:
    inc ecx
%if %3
    add r8d, %1
    add r9d, %2
    jmp %%step
%endif
%%done:
%endmacro

; ============================================================
; eval_knight_outpost - jazdec na outposte?
; Vstup:  r12 = sq, r13d = farba jazdca (0/8)
; Vystup: eax = 1 (outpost: rank 4-6, brany vlastnym pesiacom,
;                  bez utoku nepriatelskeho pesiaca), inak 0
; Clobber: rax, rcx, rdx, rsi, rdi, r8
; ============================================================
eval_knight_outpost:
    mov eax, r12d
    shr eax, 3              ; rank
    test r13d, r13d
    jnz .rank_b
    cmp eax, 3              ; biely rank 4-6 (idx 3-5)
    jb .no
    cmp eax, 5
    ja .no
    jmp .rank_ok
.rank_b:
    cmp eax, 2              ; cierny rank 3-5 (idx 2-4, mirror)
    jb .no
    cmp eax, 4
    ja .no
.rank_ok:
    mov r8d, r12d
    and r8d, 7              ; f
    lea rsi, [board]
    ; --- brany vlastnym pesiacom ---
    ; biely: pesiac na sq-7 (f>=1), sq-9 (f<=6)
    ; cierny: pesiac na sq+7 (f<=6), sq+9 (f>=1)
    test r13d, r13d
    jnz .def_b
    test r8d, r8d
    jz .def_w9
    lea ecx, [r12 - 7]
    movzx edx, byte [rsi + rcx]
    cmp edx, PAWN | WHITE
    je .defended
.def_w9:
    cmp r8d, 7
    je .no
    lea ecx, [r12 - 9]
    movzx edx, byte [rsi + rcx]
    cmp edx, PAWN | WHITE
    jne .no
    jmp .defended
.def_b:
    cmp r8d, 7
    je .def_b9
    lea ecx, [r12 + 7]
    movzx edx, byte [rsi + rcx]
    cmp edx, PAWN | BLACK
    je .defended
.def_b9:
    test r8d, r8d
    jz .no
    lea ecx, [r12 + 9]
    movzx edx, byte [rsi + rcx]
    cmp edx, PAWN | BLACK
    jne .no
.defended:
    ; --- nie je napadnutelny nepriatelskymi pesiacmi ---
    ; biely: cierni pesiaci na sq+7 (f<=6), sq+9 (f>=1)
    ; cierny: bieli pesiaci na sq-7 (f>=1), sq-9 (f<=6)
    test r13d, r13d
    jnz .atk_b
    cmp r8d, 7
    je .atk_w9
    lea ecx, [r12 + 7]
    movzx edx, byte [rsi + rcx]
    cmp edx, PAWN | BLACK
    je .no
.atk_w9:
    test r8d, r8d
    jz .yes
    lea ecx, [r12 + 9]
    movzx edx, byte [rsi + rcx]
    cmp edx, PAWN | BLACK
    je .no
    jmp .yes
.atk_b:
    test r8d, r8d
    jz .atk_b9
    lea ecx, [r12 - 7]
    movzx edx, byte [rsi + rcx]
    cmp edx, PAWN | WHITE
    je .no
.atk_b9:
    cmp r8d, 7
    je .yes
    lea ecx, [r12 - 9]
    movzx edx, byte [rsi + rcx]
    cmp edx, PAWN | WHITE
    je .no
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ============================================================
; evaluate - vrati skore z pohladu bieleho (tapered MG/EG)
; Vystup: eax = skore
; Fazy: phase = suma vah non-pawn materialu (max 24);
;       skore = (mg*phase + eg*(24-phase)) / 24
; ============================================================
evaluate:
    push rbp
    mov rbp, rsp
    sub rsp, 112
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rsi
    push rdi

    ; lokaly:
    ; [rbp-8]  = maska bielych pesiacov
    ; [rbp-16] = maska ciernych pesiacov
    ; [rbp-24..-17] = pocty bielych pesiacov per file
    ; [rbp-32..-25] = pocty ciernych pesiacov per file
    ; [rbp-36] = pocet bielych strelcov (dword)
    ; [rbp-40] = pocet ciernych strelcov (dword)
    ; [rbp-48] = EG akumulator (dword)
    ; [rbp-56] = faza hry (dword, max 24)
    ; [rbp-64] = policko bieleho krala (dword)
    ; [rbp-68] = policko cierneho krala (dword)
    ; [rbp-72] = king attack score pre bieleho (utok na cierneho krala) (dword)
    ; [rbp-76] = king attack score pre cierneho (utok na bieleho krala) (dword)
    ; [rbp-88] = passed white pawn bitmask (qword)  — POZOR: -80 by sa prekryvalo s -76!
    ; [rbp-96] = passed black pawn bitmask (qword)
    xor eax, eax
    mov [rbp - 8], rax
    mov [rbp - 16], rax
    mov [rbp - 24], rax
    mov [rbp - 32], rax
    mov [rbp - 40], rax
    mov [rbp - 48], rax
    mov [rbp - 56], rax
    mov [rbp - 64], rax
    mov [rbp - 68], rax
    mov dword [rbp - 72], 0
    mov dword [rbp - 76], 0
    mov qword [rbp - 88], 0    ; passed white mask (nie -80 — prekryv s -76!)
    mov qword [rbp - 96], 0    ; passed black mask

    xor r15d, r15d          ; MG akumulator
    xor r12, r12            ; index policka

.next_square:
    lea rsi, [board]
    movzx r13d, byte [rsi + r12]
    test r13d, r13d
    jz .skip

    mov r14d, r13d
    and r14d, PIECE_MASK    ; typ figury
    and r13d, COLOR_MASK    ; farba (0 alebo BLACK=8)

    ; --- MG/EG hodnota ---
    cmp byte [eval_mode], 0
    jne .nnue_lookup
    ; classic: mirror podla absolutnej farby, jedna tabulka na typ
    lea rdi, [material_mg]
    mov eax, dword [rdi + r14*4]
    lea rdi, [pst_ptrs_mg]
    mov rdi, [rdi + r14*8]
    mov rbx, r12
    test r13d, r13d
    jz .mg_index
    xor rbx, 56             ; mirror pre cierne
.mg_index:
    movsx edx, byte [rdi + rbx]
    add eax, edx            ; eax = MG hodnota figury

    ; --- EG hodnota (rovnaky mirror index v rbx) ---
    lea rdi, [material_eg]
    mov edx, dword [rdi + r14*4]
    lea rdi, [pst_ptrs_eg]
    mov rdi, [rdi + r14*8]
    movsx edi, byte [rdi + rbx]
    add edx, edi            ; edx = EG hodnota figury
    jmp .pst_done

.nnue_lookup:
    ; NNUE: own/enemy blok + rel. square z pohladu STM
    ; r14 = typ, r13d = farba (0/8), r12 = policko
    mov eax, r13d
    shr eax, 3              ; color_idx 0/1
    movzx edx, byte [side]
    xor eax, edx            ; 0 = own farba, 1 = enemy
    mov ecx, eax
    shl ecx, 3
    sub ecx, eax            ; color_rel*7
    add ecx, r14d           ; index do pst_ptrs (0..13)
    mov ebx, r12d
    test eax, eax
    jz .nnue_index
    xor ebx, 56             ; enemy figurky: mirror z pohladu STM
.nnue_index:
    lea rdi, [pst_ptrs_mg]
    mov rdi, [rdi + rcx*8]
    movsx edx, byte [rdi + rbx]
    lea rdi, [material_mg]
    mov eax, dword [rdi + r14*4]
    add eax, edx

    lea rdi, [material_eg]
    mov edx, dword [rdi + r14*4]
    lea rdi, [pst_ptrs_eg]
    mov rdi, [rdi + rcx*8]
    movsx edi, byte [rdi + rbx]
    add edx, edi
.pst_done:

    ; --- akumulacia (biely +, cierny -) ---
    test r13d, r13d
    jz .add_white
    sub r15d, eax
    sub dword [rbp - 48], edx
    jmp .phase_add
.add_white:
    add r15d, eax
    add dword [rbp - 48], edx

.phase_add:
    ; prispevok k faze (non-pawn material)
    lea rdi, [phase_weights]
    movzx eax, byte [rdi + r14]
    add dword [rbp - 56], eax

    ; policka kralov pre king safety
    cmp r14d, KING
    jne .collect
    test r13d, r13d
    jnz .king_b_sq
    mov [rbp - 64], r12d
    jmp .collect
.king_b_sq:
    mov [rbp - 68], r12d

.collect:
    ; zber dat pre pawn structure / bishop pair
    cmp r14d, PAWN
    jne .col_bishop
    mov ebx, r12d
    and ebx, 7              ; file
    mov rdi, 1
    mov ecx, r12d
    shl rdi, cl             ; bit policka
    test r13d, r13d
    jnz .col_black_pawn
    or [rbp - 8], rdi
    inc byte [rbp - 24 + rbx]
    jmp .skip
.col_black_pawn:
    or [rbp - 16], rdi
    inc byte [rbp - 32 + rbx]
    jmp .skip
.col_bishop:
    cmp r14d, BISHOP
    jne .skip
    test r13d, r13d
    jnz .col_black_bishop
    inc dword [rbp - 36]
    jmp .skip
.col_black_bishop:
    inc dword [rbp - 40]

.skip:
    inc r12
    cmp r12, 64
    jl .next_square

    ; ================= MOBILITY + OUTPOSTY =================
    ; pocet pseudo-legálnych cielov N/B/R/Q (prazdne + super policka,
    ; vlastne figury blokuju); vaha za policko podla typu, MG/EG
    lea rbx, [board]
    xor r12, r12
.mob_loop:
    movzx r13d, byte [rbx + r12]
    test r13d, r13d
    jz .mob_next
    mov r14d, r13d
    and r14d, PIECE_MASK
    cmp r14d, KNIGHT
    jb .mob_next
    cmp r14d, QUEEN
    ja .mob_next
    and r13d, COLOR_MASK
    mov r10d, r12d
    and r10d, 7              ; zakladny file
    mov r11d, r12d
    shr r11d, 3              ; zakladny rank
    cmp r14d, KNIGHT
    je .mob_knight
    cmp r14d, BISHOP
    je .mob_b
    cmp r14d, ROOK
    je .mob_r
    ; dama: diagonalne + rovne
    xor ecx, ecx
    MOB_WALK  1,  1, 1
    MOB_WALK  1, -1, 1
    MOB_WALK -1,  1, 1
    MOB_WALK -1, -1, 1
    MOB_WALK  1,  0, 1
    MOB_WALK -1,  0, 1
    MOB_WALK  0,  1, 1
    MOB_WALK  0, -1, 1
    jmp .mob_score
.mob_b:
    xor ecx, ecx
    MOB_WALK  1,  1, 1
    MOB_WALK  1, -1, 1
    MOB_WALK -1,  1, 1
    MOB_WALK -1, -1, 1
    ; outpost pre strelca (konzervativny, iba MG)
    push rcx
    call eval_knight_outpost      ; funkcia je genericka (rank + pesiak brani / neutok)
    test eax, eax
    jz .mob_b_done
    mov eax, B_OUTPOST_MG
    mov edx, B_OUTPOST_EG
    mov esi, r12d
    and esi, 7
    cmp esi, 2
    jb .mob_b_op_score
    cmp esi, 5
    jbe .mob_b_op_c
    jmp .mob_b_op_score
.mob_b_op_c:
    mov eax, B_OUTPOST_C_MG
    mov edx, B_OUTPOST_C_EG
.mob_b_op_score:
    test r13d, r13d
    jz .mob_b_op_w
    sub r15d, eax
    sub dword [rbp - 48], edx
    jmp .mob_b_done
.mob_b_op_w:
    add r15d, eax
    add dword [rbp - 48], edx
.mob_b_done:
    pop rcx
    jmp .mob_score
.mob_r:
    xor ecx, ecx
    MOB_WALK  1,  0, 1
    MOB_WALK -1,  0, 1
    MOB_WALK  0,  1, 1
    MOB_WALK  0, -1, 1
    jmp .mob_score
.mob_knight:
    ; outpost pred countom (ecx este volne)
    call eval_knight_outpost
    test eax, eax
    jz .mob_kn_count
    mov eax, OUTPOST_MG
    mov edx, OUTPOST_EG
    mov esi, r12d
    and esi, 7
    cmp esi, 2               ; centralne file c-f (2..5): viac
    jb .mob_op_score
    cmp esi, 5
    jbe .mob_op_c
    jmp .mob_op_score
.mob_op_c:
    mov eax, OUTPOST_C_MG
    mov edx, OUTPOST_C_EG
.mob_op_score:
    test r13d, r13d
    jz .mob_op_w
    sub r15d, eax
    sub dword [rbp - 48], edx
    jmp .mob_kn_count
.mob_op_w:
    add r15d, eax
    add dword [rbp - 48], edx
.mob_kn_count:
    xor ecx, ecx
    MOB_WALK  1,  2, 0
    MOB_WALK  2,  1, 0
    MOB_WALK  2, -1, 0
    MOB_WALK  1, -2, 0
    MOB_WALK -1, -2, 0
    MOB_WALK -2, -1, 0
    MOB_WALK -2,  1, 0
    MOB_WALK -1,  2, 0
.mob_score:
    mov r11d, ecx

    ; MG mobility: w * (count - baseline)
    mov eax, r11d
    lea rsi, [mob_base_mg]
    movzx edi, byte [rsi + r14]
    sub eax, edi
    lea rsi, [mob_w_mg]
    movzx edi, byte [rsi + r14]
    imul eax, edi

    ; EG mobility: w * (count - baseline)
    mov edx, r11d
    lea rsi, [mob_base_eg]
    movzx edi, byte [rsi + r14]
    sub edx, edi
    lea rsi, [mob_w_eg]
    movzx edi, byte [rsi + r14]
    imul edx, edi
    test r13d, r13d
    jz .mob_w
    sub r15d, eax
    sub dword [rbp - 48], edx
    jmp .mob_next
.mob_w:
    add r15d, eax
    add dword [rbp - 48], edx
.mob_next:
    inc r12
    cmp r12, 64
    jl .mob_loop

    ; ================= KING SAFETY (iba MG) =================
    ; plati na vlastnej polovici (biely rank 0-3, cierny 4-7):
    ; - suprada pesiacov 1-2 ranky pred kralom: +SHIELD_PAWN za kazdeho
    ; - file krala +/- susedne: otvoreny -KINGOPEN_PEN, semi -KINGSEMI_PEN
    ; --- biely kral ---
    mov r12d, [rbp - 64]
    mov eax, r12d
    shr eax, 3
    cmp eax, 3
    ja .ks_w_done               ; kral za centralizovany: bez bonusu
    lea ecx, [r12 + 8]
    cmp ecx, 64
    jae .ks_w_files
    movzx edx, byte [rbx + rcx]
    cmp edx, PAWN | WHITE
    jne .ks_w_sh2
    add r15d, SHIELD_PAWN
.ks_w_sh2:
    add ecx, 8
    cmp ecx, 64
    jae .ks_w_files
    movzx edx, byte [rbx + rcx]
    cmp edx, PAWN | WHITE
    jne .ks_w_files
    add r15d, SHIELD_PAWN
.ks_w_files:
    mov r8d, r12d
    and r8d, 7                  ; file krala
    lea r9d, [r8 - 1]
    cmp r9d, 0
    jge .ks_w_fx0
    xor r9d, r9d
.ks_w_fx0:
    mov r10d, r8d
    add r10d, 1
    cmp r10d, 7
    jle .ks_w_fx_loop
    mov r10d, 7
.ks_w_fx_loop:
    cmp r9d, r10d
    jg .ks_w_done
    movzx eax, byte [rbp - 24 + r9]    ; biele pesiacie na file
    movzx edx, byte [rbp - 32 + r9]    ; cierne pesiacie na file
    lea ecx, [rax + rdx]
    test ecx, ecx
    jnz .ks_w_semi
    sub r15d, KINGOPEN_PEN
    jmp .ks_w_fx_next
.ks_w_semi:
    test eax, eax
    jnz .ks_w_fx_next
    sub r15d, KINGSEMI_PEN
.ks_w_fx_next:
    inc r9d
    jmp .ks_w_fx_loop
.ks_w_done:

    ; --- cierny kral ---
    mov r12d, [rbp - 68]
    mov eax, r12d
    shr eax, 3
    cmp eax, 4
    jb .ks_b_done               ; kral prilis vysoko/centralizovany: skip
    lea ecx, [r12 - 8]
    jmp .ks_b_sh1
.ks_b_sh1:
    test ecx, ecx
    js .ks_b_files
    movzx edx, byte [rbx + rcx]
    cmp edx, PAWN | BLACK
    jne .ks_b_sh2
    sub r15d, SHIELD_PAWN
.ks_b_sh2:
    sub ecx, 8
    test ecx, ecx
    js .ks_b_files
    movzx edx, byte [rbx + rcx]
    cmp edx, PAWN | BLACK
    jne .ks_b_files
    sub r15d, SHIELD_PAWN
.ks_b_files:
    mov r8d, r12d
    and r8d, 7
    lea r9d, [r8 - 1]
    cmp r9d, 0
    jge .ks_b_fx0
    xor r9d, r9d
.ks_b_fx0:
    mov r10d, r8d
    add r10d, 1
    cmp r10d, 7
    jle .ks_b_fx_loop
    mov r10d, 7
.ks_b_fx_loop:
    cmp r9d, r10d
    jg .ks_b_done
    movzx eax, byte [rbp - 24 + r9]
    movzx edx, byte [rbp - 32 + r9]
    lea ecx, [rax + rdx]
    test ecx, ecx
    jnz .ks_b_semi
    add r15d, KINGOPEN_PEN      ; penal pre cierneho = plus pre bieleho
    jmp .ks_b_fx_next
.ks_b_semi:
    test edx, edx               ; vlastny = cierny
    jnz .ks_b_fx_next
    add r15d, KINGSEMI_PEN
.ks_b_fx_next:
    inc r9d
    jmp .ks_b_fx_loop
.ks_b_done:

    ; castled shelter (MG): krale na f/g/h1 resp. f/g/h8
    ; ciel: silnejsie trestat oslabenie rošádovej bariéry (hlavne g/h push)
    ; --- biely castled king (f1/g1/h1) ---
    mov eax, [rbp - 64]
    cmp eax, 5                  ; f1
    je .ks_wc_apply
    cmp eax, 6                  ; g1
    je .ks_wc_apply
    cmp eax, 7                  ; h1
    jne .ks_bc_check
.ks_wc_apply:
    ; f2 = 13, g2 = 14, h2 = 15
    movzx ecx, byte [rbx + 13]
    cmp ecx, PAWN | WHITE
    je .ks_wc_f_ok
    sub r15d, CASTLE_SHELTER_MISS
    jmp .ks_wc_g
.ks_wc_f_ok:
    add r15d, CASTLE_SHELTER_BONUS
.ks_wc_g:
    movzx ecx, byte [rbx + 14]
    cmp ecx, PAWN | WHITE
    je .ks_wc_g_ok
    sub r15d, CASTLE_SHELTER_MISS
    jmp .ks_wc_h
.ks_wc_g_ok:
    add r15d, CASTLE_SHELTER_BONUS
.ks_wc_h:
    movzx ecx, byte [rbx + 15]
    cmp ecx, PAWN | WHITE
    je .ks_wc_h_ok
    sub r15d, CASTLE_SHELTER_MISS
    jmp .ks_bc_check
.ks_wc_h_ok:
    add r15d, CASTLE_SHELTER_BONUS

    ; --- cierny castled king (f8/g8/h8) ---
.ks_bc_check:
    mov eax, [rbp - 68]
    cmp eax, 61                 ; f8
    je .ks_bc_apply
    cmp eax, 62                 ; g8
    je .ks_bc_apply
    cmp eax, 63                 ; h8
    jne .ks_castle_done
.ks_bc_apply:
    ; f7 = 53, g7 = 54, h7 = 55
    movzx ecx, byte [rbx + 53]
    cmp ecx, PAWN | BLACK
    je .ks_bc_f_ok
    add r15d, CASTLE_SHELTER_MISS
    jmp .ks_bc_g
.ks_bc_f_ok:
    sub r15d, CASTLE_SHELTER_BONUS
.ks_bc_g:
    movzx ecx, byte [rbx + 54]
    cmp ecx, PAWN | BLACK
    je .ks_bc_g_ok
    add r15d, CASTLE_SHELTER_MISS
    jmp .ks_bc_h
.ks_bc_g_ok:
    sub r15d, CASTLE_SHELTER_BONUS
.ks_bc_h:
    movzx ecx, byte [rbx + 55]
    cmp ecx, PAWN | BLACK
    je .ks_bc_h_ok
    add r15d, CASTLE_SHELTER_MISS
    jmp .ks_castle_done
.ks_bc_h_ok:
    sub r15d, CASTLE_SHELTER_BONUS
.ks_castle_done:

    ; ================= KING TROPISM (MG only) =================
    ; Pre kazdu nePesiacku nKralovsku figuru: Chebyshev <= 2 od nepriatelovho krala
    ; biela figura -> utok na cierneho krala ([rbp-68]); cierna -> na bieleho ([rbp-64])
    lea rsi, [board]
    xor r12, r12
.trop_loop:
    movzx eax, byte [rsi + r12]
    test eax, eax
    jz .trop_next
    mov r13d, eax
    and r13d, COLOR_MASK
    mov r14d, eax
    and r14d, PIECE_MASK
    cmp r14d, PAWN
    je .trop_next
    cmp r14d, KING
    je .trop_next
    ; vybrat cieloveho krala
    test r13d, r13d
    jnz .trop_is_black
    mov ebx, [rbp - 68]         ; cierna figura: biely utocnik -> cierne kralov sq
    jmp .trop_dist
.trop_is_black:
    mov ebx, [rbp - 64]         ; cierna figura -> biely kral
.trop_dist:
    ; file distance
    mov ecx, r12d
    and ecx, 7
    mov edx, ebx
    and edx, 7
    sub ecx, edx
    test ecx, ecx
    jns .trop_fok
    neg ecx
.trop_fok:
    ; rank distance
    mov r8d, r12d
    shr r8d, 3
    mov r9d, ebx
    shr r9d, 3
    sub r8d, r9d
    test r8d, r8d
    jns .trop_rok
    neg r8d
.trop_rok:
    ; chebyshev = max
    cmp ecx, r8d
    jge .trop_cheb
    mov ecx, r8d
.trop_cheb:
    cmp ecx, 2
    jg .trop_next
    lea rdi, [tropism_weights]
    movzx r10d, byte [rdi + r14]
    test r13d, r13d
    jnz .trop_acc_black
    add dword [rbp - 72], r10d  ; biely utoci na cierneho krala
    jmp .trop_next
.trop_acc_black:
    add dword [rbp - 76], r10d  ; cierny utoci na bieleho krala
.trop_next:
    inc r12
    cmp r12, 64
    jl .trop_loop

    ; aplikovat: cap na 16, * TROPISM_SCALE, len v MG
    mov eax, [rbp - 72]
    cmp eax, 16
    jle .trop_w_cap
    mov eax, 16
.trop_w_cap:
    imul eax, eax, TROPISM_SCALE
    add r15d, eax               ; biely profituje

    mov eax, [rbp - 76]
    cmp eax, 16
    jle .trop_b_cap
    mov eax, 16
.trop_b_cap:
    imul eax, eax, TROPISM_SCALE
    sub r15d, eax               ; cierny profituje (penalty pre bieleho)

    ; DEBUG dump
    mov [eval_dbg_mg], r15d
    mov eax, [rbp - 48]
    mov [eval_dbg_eg], eax

    ; --- tapered interpolacia: skore = (mg*phase + eg*(24-phase)) / 24 ---
    mov eax, [rbp - 48]         ; eg
    mov ecx, 24
    sub ecx, [rbp - 56]         ; 24 - phase
    imul eax, ecx               ; eg * (24-phase)
    mov edx, r15d               ; mg
    imul edx, [rbp - 56]        ; mg * phase
    add eax, edx
    cdq
    mov ecx, 24
    idiv ecx
    mov r15d, eax               ; tapered skore do r15 (dalsie termy pripocitavaju)

    ; --- bishop pair ---
    cmp dword [rbp - 36], 2
    jl .no_bp_w
    add r15d, BISHOP_PAIR
.no_bp_w:
    cmp dword [rbp - 40], 2
    jl .no_bp_b
    sub r15d, BISHOP_PAIR
.no_bp_b:

    ; --- pawn structure per file: doubled + isolated ---
    xor r12, r12            ; file
.file_loop:
    movzx eax, byte [rbp - 24 + r12]    ; wcount
    movzx ebx, byte [rbp - 32 + r12]    ; bcount

    ; doubled: kazdy dalsi pesiak na file -DOUBLED_PEN
    cmp eax, 1
    jle .no_dbl_w
    lea ecx, [eax - 1]
    imul ecx, ecx, DOUBLED_PEN
    sub r15d, ecx
.no_dbl_w:
    cmp ebx, 1
    jle .no_dbl_b
    lea ecx, [ebx - 1]
    imul ecx, ecx, DOUBLED_PEN
    add r15d, ecx
.no_dbl_b:

    ; isolated biely: ziadny biely pesiak na susednych files
    test eax, eax
    jz .iso_w_done
    test r12, r12
    jz .iso_w_left_ok
    cmp byte [rbp - 24 + r12 - 1], 0
    jne .iso_w_done
.iso_w_left_ok:
    cmp r12, 7
    je .iso_w_pen
    cmp byte [rbp - 24 + r12 + 1], 0
    jne .iso_w_done
.iso_w_pen:
    imul ecx, eax, ISOLATED_PEN
    sub r15d, ecx
.iso_w_done:

    ; isolated cierny
    test ebx, ebx
    jz .iso_b_done
    test r12, r12
    jz .iso_b_left_ok
    cmp byte [rbp - 32 + r12 - 1], 0
    jne .iso_b_done
.iso_b_left_ok:
    cmp r12, 7
    je .iso_b_pen
    cmp byte [rbp - 32 + r12 + 1], 0
    jne .iso_b_done
.iso_b_pen:
    imul ecx, ebx, ISOLATED_PEN
    add r15d, ecx
.iso_b_done:

    inc r12
    cmp r12, 8
    jl .file_loop

    ; --- passed pawns: biele ---
    mov rax, [rbp - 8]
.pp_w_loop:
    test rax, rax
    jz .pp_w_done
    bsf rdx, rax
    btr rax, rdx
    ; file mask so susednymi
    mov rbx, rdx
    and rbx, 7
    lea rsi, [file_masks]
    mov rdi, [rsi + rbx*8]
    test rbx, rbx
    jz .pp_w_noleft
    or rdi, [rsi + rbx*8 - 8]
.pp_w_noleft:
    cmp rbx, 7
    je .pp_w_noright
    or rdi, [rsi + rbx*8 + 8]
.pp_w_noright:
    ; blockery = cierne pesiacie vysie ranky na 3 files
    mov rcx, rdx
    shr rcx, 3
    lea rsi, [hi_rank_masks]
    mov rsi, [rsi + rcx*8]
    and rdi, rsi
    and rdi, [rbp - 16]
    jnz .pp_w_loop
    ; passed: bonus = PASSED_BASE + PASSED_STEP * rank
    bts qword [rbp - 88], rdx   ; zaznac bieleho passera
    imul ecx, ecx, PASSED_STEP
    add ecx, PASSED_BASE
    add r15d, ecx
    jmp .pp_w_loop
.pp_w_done:

    ; --- passed pawns: cierne ---
    mov rax, [rbp - 16]
.pp_b_loop:
    test rax, rax
    jz .pp_b_done
    bsf rdx, rax
    btr rax, rdx
    mov rbx, rdx
    and rbx, 7
    lea rsi, [file_masks]
    mov rdi, [rsi + rbx*8]
    test rbx, rbx
    jz .pp_b_noleft
    or rdi, [rsi + rbx*8 - 8]
.pp_b_noleft:
    cmp rbx, 7
    je .pp_b_noright
    or rdi, [rsi + rbx*8 + 8]
.pp_b_noright:
    ; blockery = biele pesiacie na nizsich rankoch
    mov rcx, rdx
    shr rcx, 3
    lea rsi, [lo_rank_masks]
    mov rsi, [rsi + rcx*8]
    and rdi, rsi
    and rdi, [rbp - 8]
    jnz .pp_b_loop
    ; passed: bonus = PASSED_BASE + PASSED_STEP * (7 - rank); rcx = rank
    ; pozor: nepouzivat eax/rax - v rax je maska ciernych pesiacov!
    bts qword [rbp - 96], rdx   ; zaznac cierneho passera
    mov edx, 7
    sub edx, ecx
    imul edx, edx, PASSED_STEP
    add edx, PASSED_BASE
    sub r15d, edx
    jmp .pp_b_loop
.pp_b_done:

    ; --- connected passed pawns ---
    ; passed pesiak s kamaratom na susednom file (rovnaky/susedny rank)
    ; dostane maly bonus; pri postupe rastie.
    lea rsi, [board]

    ; bieli passeri
    mov rax, [rbp - 88]
.cpp_w_loop:
    test rax, rax
    jz .cpp_b_start
    bsf rdx, rax
    btr rax, rdx

    mov ecx, edx
    and ecx, 7              ; file
    mov r8d, edx
    shr r8d, 3              ; rank
    xor r9d, r9d            ; found flag

    ; lava strana (f-1)
    test ecx, ecx
    jz .cpp_w_right
    lea r10d, [edx - 1]     ; rovnaky rank
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | WHITE
    je .cpp_w_found
    test r8d, r8d
    jz .cpp_w_l_up
    lea r10d, [edx - 9]     ; rank-1
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | WHITE
    je .cpp_w_found
.cpp_w_l_up:
    cmp r8d, 7
    je .cpp_w_right
    lea r10d, [edx + 7]     ; rank+1
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | WHITE
    je .cpp_w_found

.cpp_w_right:
    cmp ecx, 7
    je .cpp_w_apply
    lea r10d, [edx + 1]     ; rovnaky rank
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | WHITE
    je .cpp_w_found
    test r8d, r8d
    jz .cpp_w_r_up
    lea r10d, [edx - 7]     ; rank-1
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | WHITE
    je .cpp_w_found
.cpp_w_r_up:
    cmp r8d, 7
    je .cpp_w_apply
    lea r10d, [edx + 9]     ; rank+1
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | WHITE
    je .cpp_w_found
    jmp .cpp_w_apply

.cpp_w_found:
    mov r9d, 1

.cpp_w_apply:
    test r9d, r9d
    jz .cpp_w_loop
    mov r10d, r8d
    imul r10d, CONNECTED_PP_STEP
    add r10d, CONNECTED_PP_BASE
    add r15d, r10d
    jmp .cpp_w_loop

.cpp_b_start:
    mov rax, [rbp - 96]
.cpp_b_loop:
    test rax, rax
    jz .cpp_done
    bsf rdx, rax
    btr rax, rdx

    mov ecx, edx
    and ecx, 7              ; file
    mov r8d, edx
    shr r8d, 3              ; rank
    xor r9d, r9d            ; found flag

    ; lava strana (f-1)
    test ecx, ecx
    jz .cpp_b_right
    lea r10d, [edx - 1]
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | BLACK
    je .cpp_b_found
    test r8d, r8d
    jz .cpp_b_l_up
    lea r10d, [edx - 9]
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | BLACK
    je .cpp_b_found
.cpp_b_l_up:
    cmp r8d, 7
    je .cpp_b_right
    lea r10d, [edx + 7]
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | BLACK
    je .cpp_b_found

.cpp_b_right:
    cmp ecx, 7
    je .cpp_b_apply
    lea r10d, [edx + 1]
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | BLACK
    je .cpp_b_found
    test r8d, r8d
    jz .cpp_b_r_up
    lea r10d, [edx - 7]
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | BLACK
    je .cpp_b_found
.cpp_b_r_up:
    cmp r8d, 7
    je .cpp_b_apply
    lea r10d, [edx + 9]
    movzx r11d, byte [rsi + r10]
    cmp r11d, PAWN | BLACK
    je .cpp_b_found
    jmp .cpp_b_apply

.cpp_b_found:
    mov r9d, 1

.cpp_b_apply:
    test r9d, r9d
    jz .cpp_b_loop
    mov r10d, 7
    sub r10d, r8d
    imul r10d, CONNECTED_PP_STEP
    add r10d, CONNECTED_PP_BASE
    sub r15d, r10d
    jmp .cpp_b_loop

.cpp_done:

    ; --- veze: open/semi-open file, 7. rank ---
    xor r12, r12
.rook_loop:
    lea rsi, [board]
    movzx eax, byte [rsi + r12]
    mov ebx, eax
    and ebx, PIECE_MASK
    cmp ebx, ROOK
    jne .rook_next
    mov r13d, eax
    and r13d, COLOR_MASK
    mov rbx, r12
    and rbx, 7
    lea rsi, [file_masks]
    mov rdi, [rsi + rbx*8]
    ; open file? ziadny pesiak (ani biely ani cierny)
    mov rax, [rbp - 8]
    or rax, [rbp - 16]
    test rax, rdi
    jnz .rook_semi
    test r13d, r13d
    jnz .rook_open_b
    add r15d, ROOK_OPEN
    jmp .rook_rank
.rook_open_b:
    sub r15d, ROOK_OPEN
    jmp .rook_rank
.rook_semi:
    ; semi-open: ziadny vlastny pesiak na file
    test r13d, r13d
    jnz .rook_semi_b
    mov rax, [rbp - 8]
    jmp .rook_semi_test
.rook_semi_b:
    mov rax, [rbp - 16]
.rook_semi_test:
    test rax, rdi
    jnz .rook_rank
    test r13d, r13d
    jnz .rook_semi_b2
    add r15d, ROOK_SEMI
    jmp .rook_rank
.rook_semi_b2:
    sub r15d, ROOK_SEMI
.rook_rank:
    ; 7. rank: biely rank 6, cierny rank 1
    mov rax, r12
    shr eax, 3
    test r13d, r13d
    jnz .rook_rank_b
    cmp eax, 6
    jne .rook_behind_w
    add r15d, ROOK_SEVENTH
    jmp .rook_behind_w
.rook_rank_b:
    cmp eax, 1
    jne .rook_behind_b
    sub r15d, ROOK_SEVENTH
    jmp .rook_behind_b

.rook_behind_w:
    ; rook behind passed pawn (biely): veza je na rovnakom file, nizsi rank ako passer
    ; file mask = rdi (uz vypocitana ako jednofile mask v rbx*8)
    lea rsi, [file_masks]
    mov rdi, [rsi + rbx*8]     ; rbx = file of rook
    test r13d, r13d
    jnz .rook_behind_b          ; len biela veza
    mov rax, [rbp - 88]         ; passed white bitmask
    and rax, rdi                ; biely passer na rovnakom file?
    jz .rook_next
    bsf rcx, rax                ; najdi passera
    mov edx, ecx
    shr edx, 3                  ; rank passera
    mov eax, r12d
    shr eax, 3                  ; rank vezy
    cmp eax, edx                ; veza musi byt NIZSSIE ako passer
    jge .rook_next
    add r15d, ROOK_BEHIND_PP
    jmp .rook_next
.rook_behind_b:
    ; cierna veza za ciernym passerom: veza je na rovnakom file, VYSSI rank ako passer
    test r13d, r13d
    jz .rook_next               ; len cierna veza
    lea rsi, [file_masks]
    mov rdi, [rsi + rbx*8]
    mov rax, [rbp - 96]         ; passed black bitmask
    and rax, rdi
    jz .rook_next
    bsf rcx, rax
    mov edx, ecx
    shr edx, 3
    mov eax, r12d
    shr eax, 3
    cmp eax, edx
    jle .rook_next              ; veza musi byt VYSSSIE (vacsi rank) ako passer
    sub r15d, ROOK_BEHIND_PP
.rook_next:
    inc r12
    cmp r12, 64
    jl .rook_loop

    ; --- tempo bonus pre stranu na tahu ---
    lea rsi, [side]
    movzx eax, byte [rsi]
    test eax, eax
    jnz .tempo_b
    add r15d, TEMPO_BONUS
    jmp .tempo_done
.tempo_b:
    sub r15d, TEMPO_BONUS
.tempo_done:

    mov eax, r15d

    pop rdi
    pop rsi
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov rsp, rbp
    pop rbp
    ret
; ============================================================
; pst_init - naplni runtime PST tabulky zo zakladov * scale
; runtime[piece*64 + sq] = base[piece][sq] * scale[piece] / 64
; Volat raz na starte (pred prvym evaluate). Zachova r12/r13.
; ============================================================
global pst_init
pst_init:
    push r12
    push r13
    mov r12, 1              ; typ figury 1..6 (0 = empty, zostava 0)
.piece_loop:
    cmp r12, 6
    ja .done
    ; zdrojove pointery
    lea rax, [pst_base_ptrs_mg]
    mov rbx, [rax + r12*8]
    lea rax, [pst_base_ptrs_eg]
    mov rcx, [rax + r12*8]
    ; scale faktory
    lea rax, [pst_scale_mg]
    mov r8d, dword [rax + r12*4]
    lea rax, [pst_scale_eg]
    mov r9d, dword [rax + r12*4]
    ; cielove base offsety = piece*64 (own) a (piece+7)*64 (enemy)
    mov r10, r12
    shl r10, 6              ; piece*64
    lea rdi, [pst_runtime_mg]
    add rdi, r10            ; dst MG own
    lea rsi, [pst_runtime_eg]
    add rsi, r10            ; dst EG own
    mov r10, r12
    add r10, 7
    shl r10, 6              ; (piece+7)*64
    lea rdx, [pst_runtime_mg]
    add rdx, r10            ; dst MG enemy
    push rdx                ; [rsp] = mg enemy dst
    mov r10, r12
    add r10, 7
    shl r10, 6
    lea rdx, [pst_runtime_eg]
    add rdx, r10            ; dst EG enemy
    push rdx                ; [rsp] = eg enemy dst
    xor r13, r13
.sq_loop:
    cmp r13, 64
    jae .next_piece
    ; MG
    movsx eax, byte [rbx + r13]
    imul eax, r8d
    sar eax, 6
    mov [rdi + r13], al
    mov rdx, [rsp + 8]      ; mg enemy dst
    mov [rdx + r13], al
    ; EG
    movsx eax, byte [rcx + r13]
    imul eax, r9d
    sar eax, 6
    mov [rsi + r13], al
    mov rdx, [rsp]          ; eg enemy dst
    mov [rdx + r13], al
    inc r13
    jmp .sq_loop
.next_piece:
    pop rdx
    pop rdx
    inc r12
    jmp .piece_loop
.done:
    pop r13
    pop r12
    ret
