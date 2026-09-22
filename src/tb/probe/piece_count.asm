
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
