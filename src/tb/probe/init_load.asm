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
