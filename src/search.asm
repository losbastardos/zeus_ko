; ============================================================
; Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
; Vsetky prava vyhradene / All rights reserved.
; ============================================================

; ============================================================
; search.asm - tematicky rozdelene moduly (bez zmeny spravania)
; ============================================================

%include "search/00_header.asm"
%include "search/10_time_trace.asm"
%include "search/20_make_unmake.asm"
%include "search/30_quiescence.asm"
%include "search/40_negamax_a.asm"
%include "search/41_negamax_b.asm"
%include "search/50_root_search.asm"
%include "search/60_perft_pv_book.asm"
