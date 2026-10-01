#!/usr/bin/env python3
# tests/interactive_repro.py
# Interaktivna reprodukcia cez pty (nie pipe!) pre problemy:
#   - neviditelna sachovnica po spusteni bez debug
#   - nezobrazovanie tahov z kniznice (book=eco.book neexistuje)
#   - "Engine: Segmentation fault" po prikaze `go`
# Pouzitie: tests/tuning/.venv/bin/python tests/interactive_repro.py [--verbose]
# Skript docasne meni chess.ini (debug, book, search_depth), po dobehnuti ho obnovi.

import os, re, select, shutil, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INI = os.path.join(ROOT, "chess.ini")
BIN = os.path.join(ROOT, "chess-static")
VERBOSE = "--verbose" in sys.argv

ANSI = re.compile(r"\x1b\[[0-9;]*m")

def clean(t):
    return ANSI.sub("", t)

def set_ini(**kv):
    with open(INI) as f:
        lines = f.readlines()
    out = []
    for ln in lines:
        replaced = False
        for k, v in kv.items():
            if re.match(rf"^\s*{re.escape(k)}\s*=", ln):
                out.append(f"{k}={v}\n")
                replaced = True
                break
        if not replaced:
            out.append(ln)
    with open(INI, "w") as f:
        f.writelines(out)

class Pty:
    def __init__(self, argv):
        self.pid, self.fd = os.forkpty()
        if self.pid == 0:
            os.chdir(ROOT)
            os.execv(argv[0], argv)
        self.buf = b""
        self.alive = True
        self.status = None

    def _pump(self):
        if not self.alive:
            return
        r, _, _ = select.select([self.fd], [], [], 0)
        if r:
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                data = b""
            if not data:
                self.alive = False
                try:
                    done, self.status = os.waitpid(self.pid, os.WNOHANG)
                    if not done:
                        os.kill(self.pid, 9)
                        _, self.status = os.waitpid(self.pid, 0)
                except ChildProcessError:
                    pass
            else:
                self.buf += data

    def read_until(self, patterns, timeout=30):
        """Cakaj kym sa objavi niektory z regexov (bez ANSI). Vrati (index, cisty_text)."""
        deadline = time.time() + timeout
        regexes = [re.compile(p) for p in patterns]
        while time.time() < deadline:
            self._pump()
            text = clean(self.buf.decode("utf-8", "replace"))
            for i, rx in enumerate(regexes):
                if rx.search(text):
                    return i, text
            if not self.alive:
                break
            time.sleep(0.1)
        return None, clean(self.buf.decode("utf-8", "replace"))

    def send(self, s):
        if self.alive:
            os.write(self.fd, s.encode() + b"\r")

    def wait_exit(self, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self._pump()
            if not self.alive:
                return self.status
            time.sleep(0.1)
        return None

    def close(self):
        if self.alive:
            try:
                os.kill(self.pid, 9)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass
            self.alive = False
        try:
            os.close(self.fd)
        except OSError:
            pass

def board_drawn(text):
    rows = re.findall(r"^\s*[1-8] \|", text, re.M)
    return len(rows) >= 8

def crash_status_str(status):
    if status is None:
        return "nezname (timeout)"
    if os.WIFSIGNALED(status):
        return f"SIG{os.WTERMSIG(status)}"
    return f"exit {os.WEXITSTATUS(status)}"

def run_scenario(name, ini, steps, checks):
    set_ini(**ini)
    print(f"\n=== {name} ===")
    if VERBOSE:
        print(f"    ini: {ini}")
    p = Pty([BIN])
    results = {}
    try:
        idx, text = p.read_until(["Enter choice", "Zadaj vo"], timeout=15)
        results["menu_text"] = text
        if idx is None:
            print("  [FAIL] menu sa nezobrazilo")
            if VERBOSE:
                print(text[-1500:])
            return results
        results["menu"] = True
        for send, wait_pats, label, timeout in steps:
            if send:
                p.send(send)
            idx, text = p.read_until(wait_pats, timeout=timeout)
            results[label + "_text"] = text
            results[label + "_idx"] = idx
            if not p.alive:
                results["crash_status"] = crash_status_str(p.wait_exit(2))
                print(f"  [CRASH] proces skoncil: {results['crash_status']} (po kroku '{label}')")
                break
        else:
            if p.alive:
                p.send("exit")
                p.wait_exit(5)
    finally:
        if p.alive:
            p.close()
    for label, fn in checks.items():
        text = results.get(label + "_text", "")
        ok, detail = fn(text, results)
        print(f"  [{'OK ' if ok else 'FAIL'}] {label}: {detail}")
        if not ok and VERBOSE:
            print(text[-2000:])
    return results

def main():
    shutil.copy2(INI, INI + ".repro_backup")
    try:
        base = {"debug": "0", "search_depth": "3", "eval_mode": "2",
                "nnue_file": "net2.nnue", "eco": "eco.bin"}

        run_scenario(
            "A) mod 2 (2 hraci), debug=0, book=eco.book(chyba)",
            {**base, "book": "eco.book"},
            [("2", [r"e2e4, list"], "board", 15)],
            {"board": lambda t, r: (board_drawn(t), f"board_drawn={board_drawn(t)}")},
        )
        run_scenario(
            "A2) mod 2, debug=1",
            {**base, "debug": "1", "book": "eco.book"},
            [("2", [r"e2e4, list"], "board", 15)],
            {"board": lambda t, r: (board_drawn(t), f"board_drawn={board_drawn(t)}")},
        )

        def checks_b(t, r):
            eco = re.search(r"ECO: .+", t)
            engine_move = re.search(r"Engine: [a-h][1-8][a-h][1-8]", t)
            board = board_drawn(t)
            return (board and engine_move is not None,
                    f"board={board} engine_move={engine_move.group(0) if engine_move else None} eco={eco.group(0) if eco else None}")
        for book in ["eco.book", "basic.book"]:
            for dbg in ["0", "1"]:
                run_scenario(
                    f"B) mod 1, sila 3, biely, e2e4 — book={book}, debug={dbg}",
                    {**base, "debug": dbg, "book": book},
                    [("1", [r"ELO"], "strength", 15),
                     ("3", [r"Enter"], "color", 15),
                     ("1", [r"e2e4, list"], "turn", 15),
                     ("e2e4", [r"Engine: [a-h]"], "engine", 120)],
                    {"engine": checks_b},
                )

        run_scenario(
            "C) mod 1, sila 3, cierny — book=eco.book(chyba), debug=0",
            {**base, "book": "eco.book"},
            [("1", [r"ELO"], "strength", 15),
             ("3", [r"Enter"], "color", 15),
             ("2", [r"Engine: [a-h]"], "engine", 120)],
            {"engine": lambda t, r: (bool(re.search(r"Engine: [a-h][1-8][a-h][1-8]", t)),
                                     f"engine_move={re.search(r'Engine: [a-h].*', t).group(0) if re.search(r'Engine: [a-h]', t) else None}")},
        )

        run_scenario(
            "D) mod 2, potom `go` — debug=0, book=eco.book(chyba)",
            {**base, "book": "eco.book"},
            [("2", [r"e2e4, list"], "board", 15),
             ("go", [r"Engine: [a-h]"], "go", 120)],
            {"go": lambda t, r: ("crash_status" not in r and bool(re.search(r"Engine: [a-h][1-8][a-h][1-8]", t)),
                                 f"alive_after_go={('crash_status' not in r)} engine={re.search(r'Engine: [a-h].*', t).group(0) if re.search(r'Engine: [a-h]', t) else None}")},
        )
    finally:
        shutil.move(INI + ".repro_backup", INI)
        print("\nchess.ini obnoveny")

if __name__ == "__main__":
    main()
