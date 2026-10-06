check_time:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    ; stop signal z helper procesov cez MAP_SHARED stranku (smp modul)
    call smp_check_stop
    test eax, eax
    jnz .ret_one
    cmp byte [uci_stop_flag], 0
    je .poll_input
    mov eax, 1
    jmp .ret

.poll_input:
    ; worker procesy pri SMP nesmu siahat na stdin/UCI protokol
    cmp dword [smp_worker_mode], 0
    jne .check_mode

    ; neblokujuce spracovanie stdin (stop/ponderhit/isready/quit)
    ; kazdych 128 nodov: pri pomalsich eval moduloch (napr. NNUE2)
    ; by 1024-node polling reagoval na stop/movetime prilis neskoro.
    cmp byte [book_rating_flag], 0
    jne .check_mode              ; book rating: nech nezožiera stdin (text mode)
    mov rax, [nodes_searched]
    and rax, 127
    jnz .check_mode
    call search_poll_input
    cmp byte [uci_stop_flag], 0
    je .check_mode
    mov eax, 1
    jmp .ret

.check_mode:
    movzx eax, byte [search_limits + 0] ; mode
    cmp eax, 3                           ; infinite
    je .no_stop
    cmp eax, 4                           ; ponder
    je .no_stop

    mov rax, [search_limits + 64]        ; hard_limit ms
    test rax, rax
    jz .no_stop

    mov rax, [nodes_searched]
    and rax, 127
    jnz .no_stop

    mov rax, SYS_CLOCK_GETTIME
    mov rdi, CLOCK_MONOTONIC
    lea rsi, [search_timespec]
    syscall
    test rax, rax
    js .no_stop

    mov rax, [search_timespec]
    imul rax, 1000
    mov rbx, rax
    mov rax, [search_timespec + 8]
    mov rcx, 1000000
    xor rdx, rdx
    div rcx
    add rax, rbx
    sub rax, [search_limits + 48]        ; elapsed ms

    cmp rax, [search_limits + 64]
    jl .no_stop
    mov byte [uci_stop_flag], 1
    call smp_signal_stop         ; povedz helperom, nech tiez zastavia
    mov eax, 1
    jmp .ret

.no_stop:
    xor eax, eax
    jmp .ret

.ret_one:
    mov eax, 1
    jmp .ret

.ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; trace_print_signed - vypise signed cislo
; Vstup: rax = hodnota
; ============================================================
trace_print_signed:
    cmp rax, 0
    jge .tp_num
    push rax
    mov byte [trace_char], '-'
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [trace_char]
    mov rdx, 1
    syscall
    pop rax
    neg rax
.tp_num:
    call print_number
    ret

; ============================================================
; trace_nl - newline
; ============================================================
trace_nl:
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, msg_newline
    mov rdx, 1
    syscall
    ret



; ============================================================

; make_move - aplikuje tah a ulozi undo informacie do undo_stack
; Vstup: ax = 16-bitovy tah
; ============================================================
