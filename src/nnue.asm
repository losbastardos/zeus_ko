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

; ============================================================
; NNUE faza 2: 1-skryta-vrstva forward pass
; Format net v2: magic, ver=2, H, shift1, shift2, b1q[H] i32,
; W1q[F x H] i16 (feature-major: W1[i*H + j]), b2q i32, W2q[H] i16
; Inference: acc[j] = sum_i x[i]*W1q[i*H+j] + b1q[j]
;            h[j]   = clip(acc[j] >> shift1, 0, 255)
;            eval   = (sum_j h[j]*W2q[j] + b2q) >> shift2   (cp)
; Feature indexy (zhodne s trainerom):
;   non-king: (own*5 + typ-1)*64 + rel_sq ; king: 640 + own*64 + rel_sq
;   own = (farba figury == strana na tahu) ? 0 : 1
;   rel_sq = (strana na tahu == biela) ? sq : sq ^ 56
; ============================================================

%define NNUE2_F 768

section .bss
nnue2_buf:   resb 150000
nnue2_ready: resb 1

section .data
nnue2_H:      dd 0
nnue2_shift1: dd 0
nnue2_shift2: dd 0

section .text
global nnue2_load, nnue2_eval
extern board, side

; ============================================================
; nnue2_load - nacita net v2 do buffra
; Vstup: rdi = cesta ; Vystup: eax = 0 OK, 1 chyba
; ============================================================
nnue2_load:
    push rbx
    push r12
    mov rax, SYS_OPEN
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .fail
    mov r12, rax
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [nnue2_buf]
    mov rdx, 150000
    syscall
    mov rbx, rax                 ; nacitane
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    cmp rbx, 148000              ; minimalna velkost (H=96)
    jl .fail
    cmp dword [nnue2_buf], NNUE_MAGIC
    jne .fail
    cmp dword [nnue2_buf + 4], 2
    jne .fail
    mov eax, dword [nnue2_buf + 8]
    mov [nnue2_H], eax
    mov eax, dword [nnue2_buf + 12]
    mov [nnue2_shift1], eax
    mov eax, dword [nnue2_buf + 16]
    mov [nnue2_shift2], eax
    mov byte [nnue2_ready], 1
    xor eax, eax
    pop r12
    pop rbx
    ret
.fail:
    mov eax, 1
    pop r12
    pop rbx
    ret

; ============================================================
; nnue2_eval - forward pass, Vystup: eax = eval cp (STM perspektiva)
; ============================================================
nnue2_eval:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 400                 ; acc[96] int32 (max H)
    ; acc = b1q
    mov r15d, [nnue2_H]
    lea rsi, [nnue2_buf + 20]    ; b1q
    mov rcx, r15
    lea rdi, [rsp]
.copy_b1:
    mov eax, dword [rsi]
    mov dword [rdi], eax
    add rsi, 4
    add rdi, 4
    dec rcx
    jnz .copy_b1
    ; W1 base = buf + 20 + H*4
    mov eax, r15d
    shl eax, 2                   ; H*4 (b1 offset)
    lea r14, [nnue2_buf + 20]
    add r14, rax                 ; r14 = W1q base
    ; scan board
    lea rbx, [board]
    xor r12, r12                 ; sq
.sq_loop:
    cmp r12, 64
    jae .activate
    movzx eax, byte [rbx + r12]
    test eax, eax
    jz .sq_next
    ; typ / farba
    mov ecx, eax
    and ecx, PIECE_MASK          ; typ 1..6
    mov edx, eax
    and edx, COLOR_MASK
    shr edx, 3                   ; color_idx 0/1
    movzx edi, byte [side]       ; 0/1
    ; rel_sq: strana biela(0) -> sq ; cierna(1) -> sq^56
    mov esi, r12d
    cmp edi, 0
    je .rsq_ok
    xor esi, 56
.rsq_ok:
    ; own = (color_idx == side) ? 0 : 1
    xor edx, edi                 ; 0 ak rovnake
    ; feature idx -> rax
    cmp ecx, KING
    je .feat_king
    dec ecx                      ; typ-1 0..4
    imul eax, edx, 5
    add eax, ecx                 ; own*5 + typ-1
    shl eax, 6                   ; *64
    add eax, esi
    jmp .feat_done
.feat_king:
    mov eax, 640
    shl edx, 6                   ; own*64
    add eax, edx
    add eax, esi
.feat_done:
    ; acc[j] += W1[idx*H + j]
    imul eax, r15d               ; idx*H
    lea rsi, [r14 + rax*2]       ; W1 riadok (int16)
    xor ecx, ecx
.acc_loop:
    cmp ecx, r15d
    jae .sq_next
    movsx edx, word [rsi + rcx*2]
    add dword [rsp + rcx*4], edx
    inc ecx
    jmp .acc_loop
.sq_next:
    inc r12
    jmp .sq_loop
.activate:
    ; h[j] = clip(acc>>shift1, 0, 255); sum h*W2q
    ; W2 base = r14 + F*H*2 ; b2 za nim
    mov eax, NNUE2_F
    imul eax, r15d               ; F*H
    lea rsi, [r14 + rax*2]       ; W2q
    mov ebx, eax
    shl ebx, 1
    lea rdi, [r14 + rbx]         ; b2q (int32)
    mov ebx, dword [rdi]         ; sum = b2q
    mov ecx, [nnue2_shift1]
    xor r12, r12                 ; j
.out_loop:
    cmp r12, r15
    jae .finish
    mov eax, dword [rsp + r12*4]
    sar eax, cl                  ; acc >> shift1
    cmp eax, 0
    jge .clip_hi
    xor eax, eax
.clip_hi:
    cmp eax, 255
    jle .clip_ok
    mov eax, 255
.clip_ok:
    ; sum += h * W2q[j]
    movsx edx, word [rsi + r12*2]
    imul eax, edx
    add ebx, eax
    inc r12
    jmp .out_loop
.finish:
    mov ecx, [nnue2_shift2]
    sar ebx, cl
    mov eax, ebx
    add rsp, 400
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
