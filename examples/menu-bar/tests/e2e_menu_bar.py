#!/usr/bin/env python3
"""Drives the menu-bar fixture through the running window.

Every scenario starts a fresh process, sends input over --control-stdin,
and compares the exact sequence of COMMIT and ACTION lines the app
printed with the sequence written down here. The app never learns where
the caret is, which element has the keyboard or which menu is open, so a
scenario proves those by typing a marker or pressing Enter and checking
what arrived. A menu title or item is clicked where `inspect` over the
--socket driver says it is, so nothing here depends on how the host lays
a menu out.

    python3 examples/menu-bar/tests/e2e_menu_bar.py
    MENUS=1 python3 examples/menu-bar/tests/e2e_menu_bar.py

Without MENUS the fixture builds its menus from buttons, which is all
today's host offers, and the run shows what that cannot do. MENUS=1
builds the fixture with its host-menu opt-in and is the run that has to
pass.

DAGDA_REPO points at a Dagda checkout when this file lives outside one,
and ODIN at a compiler when the checkout has none installed.
"""

import argparse
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

# The fixture starts with "abcd" in its title field. This leaves the
# caret at ab|cd whatever a click did: select all, collapse to the start,
# two steps right.
CARET = [("click", "note.title"), "key ctrl+a", "key left", "key right", "key right"]
# Typed last in most scenarios: it lands at the caret only if the field
# still has the keyboard and its caret has not moved.
TYPE_X = "text X"
KEPT = ("COMMIT", "abXcd")


def action(name, origin="local"):
    return ("ACTION", f"{name} origin={origin}")


def click(what):
    """A click in the middle of an element, found by role or, for a menu
    title, by its text."""
    return ("click", what)


def invoke(role, ok=True):
    """A separate dagda-client activates the element with this role."""
    return ("invoke", role, ok)


def listed(role, actions):
    """A separate dagda-client's inspect lists this role with these actions."""
    return ("listed", role, actions)


SCENARIOS = [
    {
        "name": "Escape closes a menu and the caret is where it was: ab|cd, File, Escape, X",
        "steps": CARET + [click("File"), "key escape", TYPE_X],
        "expect": [KEPT],
    },
    {
        "name": "typing while a menu is open does not reach the field",
        "steps": CARET + [click("File"), "text Z", "key escape", TYPE_X],
        "expect": [KEPT],
    },
    {
        "name": "Down then Enter runs the first item, and the field has the keyboard back",
        "steps": CARET + [click("File"), "key down", "key enter", TYPE_X],
        "expect": [action("stamp"), KEPT],
    },
    {
        "name": "Down skips an item that is not enabled",
        "steps": CARET + [click("File"), "key down", "key down", "key enter", TYPE_X],
        "expect": [action("mark"), KEPT],
    },
    {
        "name": "Up from the top goes to the last enabled item",
        "steps": CARET + [click("File"), "key down", "key up", "key enter", TYPE_X],
        "expect": [action("mark"), KEPT],
    },
    {
        "name": "Right opens the next menu, and Left from the first opens the last",
        "steps": [click("File"), "key right", "key down", "key enter", click("File"), "key left", "key down", "key enter"],
        "expect": [action("flip"), action("flip")],
    },
    {
        "name": "Enter with nothing highlighted runs nothing and leaves the menu open",
        "steps": CARET + [click("File"), "key enter", "key down", "key enter", TYPE_X],
        "expect": [action("stamp"), KEPT],
    },
    {
        "name": "F10 opens the first menu on its first item, from the keyboard alone",
        "steps": CARET + ["key f10", "key enter", TYPE_X],
        "expect": [action("stamp"), KEPT],
    },
    {
        "name": "Alt+V opens the View menu by its letter",
        "steps": CARET + ["key alt+v", "key enter", TYPE_X],
        "expect": [action("flip"), KEPT],
    },
    {
        "name": "a click on an item runs it once and closes the menu",
        "steps": CARET + [click("File"), click("cmd.mark"), "key enter", TYPE_X],
        "expect": [action("mark"), KEPT],
    },
    {
        "name": "a click on an item that is not enabled does nothing and the menu stays open",
        "steps": CARET + [click("File"), click("cmd.locked"), "key down", "key enter", TYPE_X],
        "expect": [action("stamp"), KEPT],
    },
    {
        "name": "a click on the open menu's title closes it",
        "steps": CARET + [click("File"), click("File"), "key down", "key enter", TYPE_X],
        "expect": [KEPT],
    },
    {
        "name": "a focused button has the keyboard back after Escape",
        "steps": [click("note.title"), "key tab", "key f10", "key escape", "key enter"],
        "expect": [action("bump")],
    },
    {
        "name": "a driver finds every item with no menu open, and running one leaves the caret alone",
        "steps": CARET
        + [listed("cmd.stamp", ["activate"]), listed("cmd.locked", []), invoke("cmd.mark"), invoke("cmd.locked", ok=False), TYPE_X],
        "expect": [action("mark", "driver"), KEPT],
    },
    {
        "name": "a driver's activation does not close or move the person's open menu",
        "steps": CARET + [click("File"), "key down", invoke("cmd.flip"), "key enter", TYPE_X],
        "expect": [action("flip", "driver"), action("stamp"), KEPT],
    },
]


class Window:
    def __init__(self, binary, client):
        self.client = client
        self.socket = Path(tempfile.mkdtemp(prefix="dagda-menu-sock-")) / "menu.sock"
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
        self.proc.stdin.close()
        self.proc.stdout.close()
        self.socket.unlink(missing_ok=True)
        self.socket.parent.rmdir()

    def call(self, *args):
        done = subprocess.run([str(self.client), str(self.socket), *args], capture_output=True, text=True, timeout=10)
        try:
            return json.loads(done.stdout)
        except json.JSONDecodeError:
            return {"unreadable": done.stdout, "stderr": done.stderr}

    def find(self, what):
        """The one element with this role, or this text for a menu title."""
        elements = self.call("inspect").get("elements", [])
        found = [el for el in elements if el.get("role") == what or (el.get("text") == what and what in ("File", "View"))]
        return found[0] if len(found) == 1 else None

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
        """Keeps an app line; returns True for a control reply."""
        if line.startswith("CONTROL_"):
            if line.startswith("CONTROL_ERR"):
                self.errors.append(f"host refused: {line}")
            return True
        kind, _, rest = line.partition(" ")
        if kind == "COMMIT":
            self.events.append((kind, rest.partition("text=")[2]))
        elif kind == "ACTION":
            self.events.append((kind, rest))
        return False

    def settle(self):
        """Returns once every event queued before this call has been handled."""
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
        while not self.note(self.read_line()):
            pass
        self.settle()

    def step(self, step):
        if isinstance(step, str):
            self.send(step)
            return
        if step[0] == "click":
            el = self.find(step[1])
            # Click the bounds inspect reports, which are window
            # coordinates: a popup may extend over a letterbox,
            # where visible_canvas_bounds is null or clipped.
            box = el and el.get("bounds")
            if not box:
                self.errors.append(f"nothing on screen to click for {step[1]!r}")
                return
            self.send(f"click {box['x'] + box['width'] / 2:g} {box['y'] + box['height'] / 2:g}")
        elif step[0] == "listed":
            el = self.find(step[1])
            if el is None:
                self.errors.append(f"inspect does not list {step[1]}")
            elif el.get("actions") != step[2]:
                self.errors.append(f"inspect lists {step[1]} with actions {el.get('actions')}, wanted {step[2]}")
        elif step[0] == "invoke":
            el = self.find(step[1])
            if el is None:
                self.errors.append(f"a driver cannot find {step[1]}")
                return
            reply = self.call("invoke", str(el["id"]), "activate")
            if reply.get("ok") is not step[2]:
                self.errors.append(f"driver invoke {step[1]}: wanted ok={step[2]}, got {reply}")
            if step[2] is False and reply.get("error") != "Unsupported_Action":
                self.errors.append(f"driver invoke {step[1]}: wanted error Unsupported_Action, got {reply}")
            self.settle()


def show(event):
    return f"{event[0]} {'text=' if event[0] == 'COMMIT' else ''}{event[1]}"


def run_scenario(binary, client, scenario):
    window = Window(binary, client)
    problem = None
    try:
        window.wait_ready()
        for step in scenario["steps"]:
            window.step(step)
    except (TimeoutError, EOFError, subprocess.TimeoutExpired) as err:
        problem = str(err)
    finally:
        window.close()
    lines = []
    if problem:
        lines.append(f"stopped early: {problem}")
    lines += window.errors
    if window.events != scenario["expect"]:
        lines.append("expected:")
        lines += [f"    {show(e)}" for e in scenario["expect"]] or ["    (nothing)"]
        lines.append("got:")
        lines += [f"    {show(e)}" for e in window.events] or ["    (nothing)"]
    return lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="run scenarios whose name contains this text")
    opts = parser.parse_args()

    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
    menus = os.environ.get("MENUS") == "1"

    with tempfile.TemporaryDirectory(prefix="dagda-menu-") as tmp:
        binary = Path(tmp) / "menu-bar"
        build = [ODIN, "build", str(EXAMPLE), f"-collection:dagda={ROOT}", f"-out:{binary}"]
        if menus:
            build.append("-define:MENUS=true")
        if subprocess.call(build, cwd=ROOT) != 0:
            print("\nthe fixture did not build" + (" with its host-menu opt-in" if menus else ""))
            return 2
        client = Path(tmp) / "dagda-client"
        subprocess.check_call([ODIN, "build", "examples/dagda-client", f"-collection:dagda={ROOT}", f"-out:{client}"], cwd=ROOT)

        chosen = [s for s in SCENARIOS if not opts.only or opts.only in s["name"]]
        failed = 0
        for scenario in chosen:
            lines = run_scenario(binary, client, scenario)
            print(f"{'FAIL' if lines else 'PASS'}  {scenario['name']}")
            for line in lines:
                print(f"      {line}")
            failed += bool(lines)

    mode = "host menus" if menus else "today's host, menus built from buttons"
    print(f"\n{len(chosen) - failed} of {len(chosen)} scenarios passed ({mode}, SDL {os.environ['SDL_VIDEODRIVER']})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
