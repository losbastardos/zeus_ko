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
tb_sym_cache_state: resb 4096     ; 0=unknown,1=visiting,2=ok,3=mixed/invalid
tb_sym_cache_value: resb 4096     ; cache leaf hodnot pre symboly
tb_dec_symlen: resb 4096          ; symlen cache pre realny decode
tb_dec_offabs: resw 64            ; absolute offset[l] (l=0..63)
tb_dec_baseabs: resq 64           ; absolute base[l] (l=0..63)
tb_dec_idxbits: resd 1
tb_dec_blocksize: resd 1
tb_dec_num_blocks: resd 1
tb_dec_num_syms: resd 1
tb_dec_min_len: resd 1
tb_dec_max_len: resd 1
tb_dec_real_blocks: resd 1
tb_dec_sympat: resq 1
tb_dec_indextable: resq 1
tb_dec_sizetable: resq 1
tb_dec_data: resq 1
tb_dec_num_indices: resq 1
tb_dec_bside_tmp: resb 1
tb_dec_cmirror_tmp: resb 1
tb_dec_mirror_tmp: resb 1
tb_dec_file_tmp: resb 1
tb_dec_target_tmp: resd 1
tb_dec_stage_tmp: resb 1
tb_dec_slot_count_tmp: resd 1
tb_dec_headers_start_tmp: resq 1
tb_dec_override_ptrs: resb 1
tb_dec_override_indextable: resq 1
tb_dec_override_sizetable: resq 1
tb_dec_override_data: resq 1
tb_dec_slot_size0: resq 8
tb_dec_slot_size1: resq 8
tb_dec_slot_size2: resq 8

section .rodata

tb_offdiag:
    db 0,-1,-1,-1,-1,-1,-1,-1
    db 1,0,-1,-1,-1,-1,-1,-1
    db 1,1,0,-1,-1,-1,-1,-1
    db 1,1,1,0,-1,-1,-1,-1
    db 1,1,1,1,0,-1,-1,-1
    db 1,1,1,1,1,0,-1,-1
    db 1,1,1,1,1,1,0,-1
    db 1,1,1,1,1,1,1,0

tb_triangle:
    db 6,0,1,2,2,1,0,6
    db 0,7,3,4,4,3,7,0
    db 1,3,8,5,5,8,3,1
    db 2,4,5,9,9,5,4,2
    db 2,4,5,9,9,5,4,2
    db 1,3,8,5,5,8,3,1
    db 0,7,3,4,4,3,7,0
    db 6,0,1,2,2,1,0,6

tb_flipdiag:
    db 0,8,16,24,32,40,48,56
    db 1,9,17,25,33,41,49,57
    db 2,10,18,26,34,42,50,58
    db 3,11,19,27,35,43,51,59
    db 4,12,20,28,36,44,52,60
    db 5,13,21,29,37,45,53,61
    db 6,14,22,30,38,46,54,62
    db 7,15,23,31,39,47,55,63

tb_flap:
    db 0,0,0,0,0,0,0,0
    db 0,6,12,18,18,12,6,0
    db 1,7,13,19,19,13,7,1
    db 2,8,14,20,20,14,8,2
    db 3,9,15,21,21,15,9,3
    db 4,10,16,22,22,16,10,4
    db 5,11,17,23,23,17,11,5
    db 0,0,0,0,0,0,0,0

tb_piece_key:
    dq 0x0000000000000000
    dq 0x5ced000000000001
    dq 0xe173000000000010
    dq 0xd64d000000000100
    dq 0xab88000000001000
    dq 0x680b000000010000
    dq 0x0000000000000000
    dq 0x0000000000000000
    dq 0x0000000000000000
    dq 0xf209000000100000
    dq 0xbb14000001000000
    dq 0x58df000010000000
    dq 0xa15f000100000000
    dq 0x7c94001000000000
    dq 0x0000000000000000
    dq 0x0000000000000000

tb_KK_idx:
    dw -1,-1,-1,0,1,2,3,4,-1,-1,-1,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57
    dw 58,-1,-1,-1,59,60,61,62,63,-1,-1,-1,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115
    dw 116,117,-1,-1,-1,118,119,120,121,122,-1,-1,-1,123,124,125,126,127,128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,160,161,162,163,164,165,166,167,168,169,170,171,172,173
    dw 174,-1,-1,-1,175,176,177,178,179,-1,-1,-1,180,181,182,183,184,-1,-1,-1,185,186,187,188,189,190,191,192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223,224,225,226,227,228
    dw 229,230,-1,-1,-1,231,232,233,234,235,-1,-1,-1,236,237,238,239,240,-1,-1,-1,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,279,280,281,282,283
    dw 284,285,286,287,288,289,290,291,292,293,-1,-1,-1,294,295,296,297,298,-1,-1,-1,299,300,301,302,303,-1,-1,-1,304,305,306,307,308,309,310,311,312,313,314,315,316,317,318,319,320,321,322,323,324,325,326,327,328,329,330,331,332,333,334,335,336,337,338
    dw -1,-1,339,340,341,342,343,344,-1,-1,345,346,347,348,349,350,-1,-1,441,351,352,353,354,355,-1,-1,-1,442,356,357,358,359,-1,-1,-1,-1,443,360,361,362,-1,-1,-1,-1,-1,444,363,364,-1,-1,-1,-1,-1,-1,445,365,-1,-1,-1,-1,-1,-1,-1,446
    dw -1,-1,-1,366,367,368,369,370,-1,-1,-1,371,372,373,374,375,-1,-1,-1,376,377,378,379,380,-1,-1,-1,447,381,382,383,384,-1,-1,-1,-1,448,385,386,387,-1,-1,-1,-1,-1,449,388,389,-1,-1,-1,-1,-1,-1,450,390,-1,-1,-1,-1,-1,-1,-1,451
    dw 452,391,392,393,394,395,396,397,-1,-1,-1,-1,398,399,400,401,-1,-1,-1,-1,402,403,404,405,-1,-1,-1,-1,406,407,408,409,-1,-1,-1,-1,453,410,411,412,-1,-1,-1,-1,-1,454,413,414,-1,-1,-1,-1,-1,-1,455,415,-1,-1,-1,-1,-1,-1,-1,456
    dw 457,416,417,418,419,420,421,422,-1,458,423,424,425,426,427,428,-1,-1,-1,-1,-1,429,430,431,-1,-1,-1,-1,-1,432,433,434,-1,-1,-1,-1,-1,435,436,437,-1,-1,-1,-1,-1,459,438,439,-1,-1,-1,-1,-1,-1,460,440,-1,-1,-1,-1,-1,-1,-1,461

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


%include "tb/core_io.asm"
%include "tb/pairs_decode.asm"
%include "tb/probe_api.asm"
