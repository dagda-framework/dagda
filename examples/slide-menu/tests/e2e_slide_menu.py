#!/usr/bin/env python3
"""Acceptance tests for slide-row context menus.

    MENUS=1 python3 examples/slide-menu/tests/e2e_slide_menu.py

Each case starts a fresh slide-menu window (slides A=10 and
B=11), drives it over --control-stdin with bounded waits, and
checks the app's recorded COMMIT / ACTION / COMPOSITION
lines plus driver inspection. Focus and caret are proved by
typing a marker. Popup clicks use the window-coordinate
bounds dagda-client inspect reports, so a popup may extend
over a letterbox.

Without a host context-menu implementation (MENUS unset, or
MENUS=1 against a host without it), these cases fail at the
popup-opened checks: that baseline is the handoff state.
"""
import json
import os
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

EXAMPLE = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ["DAGDA_REPO"]).resolve() if os.environ.get("DAGDA_REPO") else Path(__file__).resolve().parents[3]
ODIN = os.environ.get("ODIN") or str(ROOT / "scripts" / "odin.sh")


class Window:
    def __init__(self, binary, client):
        self.client = client
        self.socket = Path(tempfile.mkdtemp(prefix="dagda-slide-sock-")) / "slide.sock"
        args = [str(binary), "--size", "960x540", "--control-stdin", "--socket", str(self.socket)]
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.fd = self.proc.stdout.fileno()
        self.buf = bytearray()
        self.events = []
        self.errors = []

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=3)
        for stream in (self.proc.stdin, self.proc.stdout):
            try:
                stream.close()
            except OSError:
                pass
        self.socket.unlink(missing_ok=True)
        self.socket.parent.rmdir()

    def call(self, *args):
        done = subprocess.run([str(self.client), str(self.socket), *args], capture_output=True, text=True, timeout=10)
        try:
            return json.loads(done.stdout)
        except json.JSONDecodeError:
            return {"unreadable": done.stdout, "stderr": done.stderr}

    def find(self, role):
        elements = self.call("inspect").get("elements", [])
        found = [el for el in elements if el.get("role") == role]
        return found[0] if len(found) == 1 else None

    def text_of(self, role):
        el = self.find(role)
        return el and el.get("text")

    def status(self):
        return self.text_of("slide.status") or ""

    def popup_open(self, role):
        el = self.find(role)
        box = el and el.get("bounds")
        return bool(box) and box.get("width", 0) > 0 and box.get("height", 0) > 0

    def read_line(self, timeout=5.0):
        deadline = time.monotonic() + timeout
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                raw = bytes(self.buf[:nl])
                del self.buf[: nl + 1]
                return raw.decode("utf-8")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"no complete line within {timeout}s; partial {bytes(self.buf)!r}")
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if ready:
                chunk = os.read(self.fd, 4096)
                if not chunk:
                    raise EOFError("the window exited")
                self.buf.extend(chunk)

    def note(self, line):
        if line.startswith("CONTROL_"):
            if line.startswith("CONTROL_ERR"):
                self.errors.append(f"host refused: {line}")
            return True
        kind, _, rest = line.partition(" ")
        if kind in ("COMMIT", "ACTION", "COMPOSITION"):
            self.events.append((kind, rest))
        return False

    def settle(self):
        self.proc.stdin.write(b"window-info\n")
        self.proc.stdin.flush()
        while True:
            line = self.read_line()
            if self.note(line) and "window-info" in line:
                return

    def wait_ready(self):
        while not self.read_line().startswith("READY"):
            pass
        self.settle()

    def send(self, line):
        self.proc.stdin.write((line + "\n").encode("utf-8"))
        self.proc.stdin.flush()
        try:
            while not self.note(self.read_line(timeout=2.0)):
                pass
        except TimeoutError:
            # A host that ignores this control (for example a
            # build with context-menu opening bypassed) sends
            # no reply; record it and let the caller's own
            # checks name what is missing.
            self.errors.append(f"no control reply to {line!r}")
        self.settle()

    def click_role(self, role, button="click"):
        el = self.find(role)
        box = el and el.get("bounds")
        if not box:
            self.errors.append(f"nothing on screen to {button} for {role!r}")
            return
        self.send(f"{button} {box['x'] + box['width'] / 2:g} {box['y'] + box['height'] / 2:g}")

    def caret_ab_cd(self):
        self.click_role("slide.a")
        for cmd in ["key ctrl+a", "key left", "key right", "key right"]:
            self.send(cmd)

    def select_cd(self):
        self.click_role("slide.a")
        for cmd in ["key ctrl+a", "key right", "key shift+left", "key shift+left"]:
            self.send(cmd)

    def count(self, kind, needle=""):
        return sum(1 for k, rest in self.events if k == kind and needle in rest)


def check(w, cond, message):
    if not cond:
        w.errors.append(message)


def case_dismiss(w):
    w.caret_ab_cd()
    w.click_role("slide.b", button="right-click")
    check(w, w.popup_open("slide.b.cmd.mark"), "popup never opened for slide B after secondary click")
    w.send("key escape")
    w.send("text X")
    check(w, w.events == [("COMMIT", "id=10 text=abXcd")], f"events {w.events}")
    check(w, w.text_of("slide.a") == "abXcd", f"A text {w.text_of('slide.a')!r}")
    check(w, w.text_of("slide.b") == "Beta", f"B text {w.text_of('slide.b')!r}")
    check(w, "selected=10" in w.status(), f"status {w.status()!r}")
    check(w, w.count("ACTION") == 0, f"actions {w.events}")


def case_composition(w):
    w.select_cd()
    w.send("preedit é")
    check(w, w.count("COMPOSITION", "id=10 composing=true") == 1, f"composition starts {w.events}")
    w.click_role("slide.b", button="right-click")
    check(w, w.popup_open("slide.b.cmd.mark"), "popup never opened for slide B during composition")
    w.send("key escape")
    check(w, w.count("COMPOSITION", "composing=true") == 1, f"composition starts after dismissal {w.events}")
    check(w, w.count("COMPOSITION", "composing=false") == 0, f"composition ends after dismissal {w.events}")
    check(w, w.count("COMMIT") == 0, f"writer commits before final {w.events}")
    w.send("text é")
    commits = [rest for kind, rest in w.events if kind == "COMMIT"]
    check(w, commits == ["id=10 text=abé"], f"commits {commits}")
    kinds = [kind for kind, _ in w.events]
    check(w, kinds.index("COMMIT") < len(kinds) - 1 - kinds[::-1].index("COMPOSITION"), f"order {w.events}")
    check(w, w.count("COMPOSITION", "composing=false") == 1, f"composition ends {w.events}")
    w.send("text |")
    check(w, w.text_of("slide.a") == "abé|", f"A text after marker {w.text_of('slide.a')!r}")


def case_activate_b(w):
    w.caret_ab_cd()
    w.click_role("slide.b", button="right-click")
    check(w, w.popup_open("slide.b.cmd.mark"), "popup never opened for slide B")
    w.send("key down")  # past the disabled Lock B to Mark B
    w.send("key enter")
    actions = [rest for kind, rest in w.events if kind == "ACTION"]
    check(w, actions == ["mark-b target=11 origin=local"], f"actions {actions}")
    check(w, "selected=10" in w.status(), f"selection after B command {w.status()!r}")
    check(w, w.count("COMMIT") == 0, f"commits before typing {w.events}")
    w.send("text X")
    check(w, w.text_of("slide.a") == "abXcd", f"typing after B command went to {w.text_of('slide.a')!r}")
    check(w, w.text_of("slide.b") == "Beta", f"B text {w.text_of('slide.b')!r}")


def case_keyboard(w):
    w.caret_ab_cd()
    w.click_role("slide.b", button="move")  # pointer over B, keyboard stays with A
    w.send("key shift+f10")
    check(w, w.popup_open("slide.a.cmd.mark"), "Shift+F10 popup did not target the focused row A")
    check(w, not w.popup_open("slide.b.cmd.mark"), "Shift+F10 popup wrongly targeted the hovered row B")
    w.send("key escape")
    w.send("text X")
    check(w, w.text_of("slide.a") == "abXcd", f"typing after Escape {w.text_of('slide.a')!r}")
    check(w, w.count("ACTION") == 0, f"actions {w.events}")


def case_keyboard_composition(w):
    w.select_cd()
    w.send("preedit é")
    w.send("key shift+f10")
    check(w, not w.popup_open("slide.a.cmd.mark"), "Shift+F10 opened a menu during composition")
    check(w, w.count("COMPOSITION", "composing=false") == 0, f"composition ended by Shift+F10 {w.events}")
    w.send("text é")
    commits = [rest for kind, rest in w.events if kind == "COMMIT"]
    check(w, commits == ["id=10 text=abé"], f"commits {commits}")
    w.send("text |")
    check(w, w.text_of("slide.a") == "abé|", f"A text after marker {w.text_of('slide.a')!r}")


CASES = [
    ("dismiss over B while editing A", case_dismiss),
    ("preserve composition across B dismissal", case_composition),
    ("activate a command on B", case_activate_b),
    ("open from the keyboard targets the focused row", case_keyboard),
    ("Shift+F10 during composition keeps IME precedence", case_keyboard_composition),
]


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="run cases whose name contains this text")
    opts = parser.parse_args()
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
    menus = os.environ.get("MENUS") == "1"
    with tempfile.TemporaryDirectory(prefix="dagda-slide-menu-") as tmp:
        binary, client = Path(tmp) / "slide-menu", Path(tmp) / "dagda-client"
        build = [ODIN, "build", str(EXAMPLE), f"-collection:dagda={ROOT}", f"-out:{binary}"]
        if menus:
            build.append("-define:MENUS=true")
        if subprocess.call(build, cwd=ROOT) != 0:
            print("\nthe slide fixture did not build" + (" with its host-menu opt-in" if menus else ""))
            return 2
        subprocess.check_call([ODIN, "build", "examples/dagda-client", f"-collection:dagda={ROOT}", f"-out:{client}"], cwd=ROOT)
        chosen = [(n, f) for n, f in CASES if not opts.only or opts.only in n]
        failed = 0
        for name, fn in chosen:
            window = Window(binary, client)
            try:
                window.wait_ready()
                fn(window)
            except (TimeoutError, EOFError, subprocess.TimeoutExpired) as err:
                window.errors.append(f"stopped early: {err}")
            finally:
                window.close()
            print(f"{'FAIL' if window.errors else 'PASS'}  {name}")
            for line in window.errors:
                print(f"      {line}")
            failed += bool(window.errors)
    print(f"\n{len(chosen) - failed} of {len(chosen)} slide cases passed (SDL {os.environ['SDL_VIDEODRIVER']})")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
