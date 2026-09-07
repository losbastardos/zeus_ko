#!/usr/bin/env bash
# Pomocny build script - pouziva nasm (cez nix-shell ak nie je v PATH)
#
# Vysledkom je jedina binarka ./chess obsahujuca vsetky backendy
# (text, framebuffer aj SDL - SDL sa linkuje dynamicky).

set -e

# Na NixOS buildni v nix-shell, aby bol vysledny ELF spustitelny priamo lokalne.
if [ -f /etc/NIXOS ] && [ -z "${IN_NIX_SHELL:-}" ]; then
    if command -v nix-shell &> /dev/null; then
        exec nix-shell -p nasm SDL2 gcc --run "bash $0"
    fi
fi

if ! command -v nasm &> /dev/null; then
    if command -v nix-shell &> /dev/null; then
        exec nix-shell -p nasm SDL2 --run "bash $0"
    else
        echo "Chyba: nasm nie je nainstalovany." >&2
        exit 1
    fi
fi

# Priprav assets/book ak chybaju
if [ ! -f "assets/wP.bmp" ] || [ ! -f "assets/bK.bmp" ]; then
    echo "Pripravujem figury..."
    utils/.venv/bin/python utils/download_assets.py
fi
if [ ! -f "book.book" ]; then
    echo "Pripravujem vzorovu knihu..."
    utils/.venv/bin/python utils/make_sample_book.py
fi

make clean || true
make all
echo "Build OK: ./chess (text + gfx: framebuffer/SDL)"
