# Makefile pre sachovy engine (NASM x86-64 Linux)

TARGET      = chess
SRCDIR      = src
OBJDIR      = obj

SRCS        = main.asm board.asm move.asm movegen.asm legal.asm io.asm data.asm eval.asm search.asm hash.asm tt.asm book.asm uci.asm panel.asm fen.asm pgn.asm gfx/config.asm gfx/gfx.asm gfx/mouse.asm gfx/sdl.asm

OBJS        = $(SRCS:%.asm=$(OBJDIR)/%.o)

CC          ?= gcc
SDL_CONFIG  ?= $(shell command -v sdl2-config 2>/dev/null || command -v pkg-config 2>/dev/null)
SDL_LIBS    ?= $(shell $(SDL_CONFIG) --libs 2>/dev/null || $(SDL_CONFIG) --libs sdl2 2>/dev/null)
DYN_LINKER  ?= $(shell $(CC) -print-file-name=ld-linux-x86-64.so.2)
LDFLAGS_BIN ?= -Wl,--dynamic-linker=$(DYN_LINKER)

NASMFLAGS   = -f elf64 -I $(SRCDIR)/

.PHONY: all clean run test

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) -no-pie -nostartfiles $(OBJS) -o $(TARGET) $(LDFLAGS_BIN) $(SDL_LIBS)

$(OBJDIR)/%.o: $(SRCDIR)/%.asm $(SRCDIR)/chess.inc
	@mkdir -p $(dir $@)
	nasm $(NASMFLAGS) $< -o $@

clean:
	rm -rf $(OBJDIR) $(TARGET)

run: $(TARGET)
	./$(TARGET)

test: $(TARGET)
	bash tests/regression.sh
