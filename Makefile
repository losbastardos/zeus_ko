# ============================================================
# Copyright (c) 2026 Marek Suchy <marek.suchy@gmail.com>
# Vsetky prava vyhradene / All rights reserved.
# ============================================================

# Makefile pre sachovy engine (NASM x86-64 Linux)

TARGET      = chess
TARGET_STATIC = chess-static
SRCDIR      = src
OBJDIR      = obj

SRCS        = main.asm board.asm move.asm movegen.asm legal.asm io.asm data.asm eval.asm search.asm see.asm hash.asm tt.asm book.asm tb.asm uci.asm panel.asm fen.asm pgn.asm gfx/config.asm gfx/gfx.asm gfx/mouse.asm gfx/sdl.asm

SRCS_STATIC = $(filter-out gfx/sdl.asm,$(SRCS)) gfx/sdl_stub.asm

OBJS        = $(SRCS:%.asm=$(OBJDIR)/%.o)
OBJS_STATIC = $(SRCS_STATIC:%.asm=$(OBJDIR)/%.o)

CC          ?= gcc
SDL_CONFIG  ?= $(shell command -v sdl2-config 2>/dev/null || command -v pkg-config 2>/dev/null)
SDL_LIBS    ?= $(shell $(SDL_CONFIG) --libs 2>/dev/null || $(SDL_CONFIG) --libs sdl2 2>/dev/null)
# Standardny interpreter ak existuje (FHS systemy), inac cesta od gcc (NixOS).
DYN_LINKER  ?= $(shell [ -e /lib64/ld-linux-x86-64.so.2 ] && echo /lib64/ld-linux-x86-64.so.2 || $(CC) -print-file-name=ld-linux-x86-64.so.2)
LDFLAGS_BIN ?= -Wl,--dynamic-linker=$(DYN_LINKER)

NASMFLAGS   = -f elf64 -I $(SRCDIR)/ -DBUILD_DATE=$(BUILD_DATE)
BUILD_DATE := $(shell date +%Y%m%d)

.PHONY: all clean run test

all: $(TARGET) $(TARGET_STATIC)

$(TARGET): $(OBJS)
	$(CC) -no-pie -nostartfiles $(OBJS) -o $(TARGET) $(LDFLAGS_BIN) $(SDL_LIBS)

# Staticky text-only build (bez SDL2 ani libc - engine je cisty syscall) -
# spustitelny aj v sandboxoch (GUI engine manager, snap/flatpak), kde chyba
# dynamicky linker/libSDL2. Raw ld namiesto "gcc -static": v nix-shell
# nie je staticka libc a engine ju nepotrebuje.
$(TARGET_STATIC): $(OBJS_STATIC)
	$(LD) -o $(TARGET_STATIC) $(OBJS_STATIC)

$(OBJDIR)/%.o: $(SRCDIR)/%.asm $(SRCDIR)/chess.inc
	@mkdir -p $(dir $@)
	nasm $(NASMFLAGS) $< -o $@

clean:
	rm -rf $(OBJDIR) $(TARGET) $(TARGET_STATIC)

run: $(TARGET)
	./$(TARGET)

test: $(TARGET)
	bash tests/regression.sh