#!/usr/bin/env python3
"""Drives the multiline-text fixture through the running window.

Every scenario starts a fresh process, sends input over --control-stdin,
and compares the exact sequence of commit, reject, undo and composition
callbacks the app printed with the sequence written down here. The app
never learns where the caret is, so a scenario proves a caret position by
typing a marker and checking where it landed. Two scenarios also edit the
body over the --socket driver with dagda-client and check each reply.

    python3 examples/multiline-text/tests/e2e_multiline_text.py
    MULTILINE=1 python3 examples/multiline-text/tests/e2e_multiline_text.py

Without MULTILINE the body is today's single-line field and the run shows
which expectations the current host misses. MULTILINE=1 builds the fixture
with its multiline opt-in and is the run that has to pass.

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

BODY, TITLE = 1, 2

# Points inside the fields, in window coordinates at the 960x540 canvas size.
CLICK_BODY = "click 120 70"
CLICK_TITLE = "click 120 380"
BODY_TOP_LEFT = "84 44"
BODY_BOTTOM_RIGHT = "876 316"

# The caret after a click depends on layout, so scenarios park it first:
# select everything, then collapse the selection to one end.
TO_END = ["key ctrl+a", "key right"]
TO_START = ["key ctrl+a", "key left"]


def commit(text, field=BODY):
    return ("COMMIT", field, text)


def reject(text, field=BODY):
    return ("REJECT", field, text)


def undo(text, field=BODY):
    return ("UNDO", field, text)


def composing(on, field=BODY):
    return ("COMPOSITION", field, on)


def edit(text, field=BODY):
    return ("EDIT", field, text)


def driver(*args, reply):
    """A dagda-client call in place of a batch. Every key in reply must match."""
    return ("driver", list(args), reply)


AGENT_TEXT = "agent one\nagent two — ✓"


def keys(name, count):
    return [f"key {name}"] * count


def escape(text):
    return text.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r")


def unescape(text):
    out, i = [], 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            out.append({"n": "\n", "r": "\r"}.get(text[i + 1], text[i + 1]))
            i += 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


# Each scenario: the body the app starts with, then batches of control
# lines, then the callbacks expected in order. One batch is one write to
# the host, so everything in it is queued before any of it is handled.
SCENARIOS = [
    {
        "name": "paste two lines",
        "text": "",
        "batches": [
            [CLICK_BODY],
            ["clipboard Première ligne\\nZweite Zeile", "key ctrl+v"],
            ["text !"],
            ["key ctrl+z"],
            ["key ctrl+z"],
        ],
        "expect": [
            commit("Première ligne\nZweite Zeile"),
            commit("Première ligne\nZweite Zeile!"),
            undo("Première ligne\nZweite Zeile"),
            undo(""),
        ],
    },
    {
        "name": "paste turns CRLF and CR into line feeds",
        "text": "",
        "batches": [
            [CLICK_BODY],
            ["clipboard one\\r\\ntwo\\rthree", "key ctrl+v"],
            ["text !"],
        ],
        "expect": [commit("one\ntwo\nthree"), commit("one\ntwo\nthree!")],
    },
    {
        "name": "Enter splits the line at the caret",
        "text": "Première ligne\nZweiteZeile",
        "batches": [[CLICK_BODY] + TO_END, keys("left", 5), ["key enter"], ["text |"]],
        "expect": [
            commit("Première ligne\nZweite\nZeile"),
            commit("Première ligne\nZweite\n|Zeile"),
        ],
    },
    {
        "name": "typing queued behind Enter lands on the new line",
        "text": "ab",
        "batches": [
            [CLICK_BODY] + TO_END,
            ["key enter", "text c", "key enter", "text d", "text e"],
        ],
        "expect": [
            commit("ab\n"),
            commit("ab\nc"),
            commit("ab\nc\n"),
            commit("ab\nc\nd"),
            commit("ab\nc\nde"),
        ],
    },
    {
        "name": "Backspace at the start of a line joins it to the one above",
        "text": "café\nnaïve",
        "batches": [[CLICK_BODY] + TO_END, ["key home"], ["key backspace"], ["text |"]],
        "expect": [commit("cafénaïve"), commit("café|naïve")],
    },
    {
        "name": "Delete at the end of a line joins the one below",
        "text": "café\nnaïve",
        "batches": [[CLICK_BODY] + TO_START, ["key end"], ["key delete"], ["text |"]],
        "expect": [commit("cafénaïve"), commit("café|naïve")],
    },
    {
        "name": "an empty line takes text and Backspace removes it",
        "text": "a\n\nb",
        "batches": [
            [CLICK_BODY] + TO_END,
            keys("left", 2),
            ["text x"],
            ["key backspace"],
            ["key backspace"],
            ["text y"],
        ],
        "expect": [commit("a\nx\nb"), commit("a\n\nb"), commit("a\nb"), commit("ay\nb")],
    },
    {
        "name": "Home and End stop at the ends of the caret's line",
        "text": "one\ntwo\nthree",
        "batches": [
            [CLICK_BODY] + TO_END,
            keys("left", 7),
            ["key home", "text <"],
            ["key end", "text >"],
            ["key shift+home", "text X"],
        ],
        "expect": [
            commit("one\n<two\nthree"),
            commit("one\n<two>\nthree"),
            commit("one\nX\nthree"),
        ],
    },
    {
        "name": "typing replaces a selection that spans lines",
        "text": "one\ntwo\nthree",
        "batches": [[CLICK_BODY] + TO_END, keys("shift+left", 8), ["text X"]],
        "expect": [commit("one\ntX")],
    },
    {
        "name": "cut and paste carry a selection that spans lines",
        "text": "one\ntwo\nthree",
        "batches": [
            [CLICK_BODY] + TO_END,
            keys("shift+left", 8),
            ["key ctrl+x"],
            ["key ctrl+v"],
            ["text !"],
        ],
        "expect": [commit("one\nt"), commit("one\ntwo\nthree"), commit("one\ntwo\nthree!")],
    },
    {
        "name": "Enter replaces a selection that spans lines",
        "text": "one\ntwo\nthree",
        "batches": [[CLICK_BODY] + TO_END, keys("shift+left", 8), ["key enter"], ["text Z"]],
        "expect": [commit("one\nt\n"), commit("one\nt\nZ")],
    },
    {
        "name": "select all covers every line",
        "text": "one\ntwo\nthree",
        "batches": [[CLICK_BODY], ["key ctrl+a", "text Z"]],
        "expect": [commit("Z")],
    },
    {
        "name": "Up and Down move between lines and keep the column",
        "text": "abcdef\nxy\nabcdef",
        "batches": [
            [CLICK_BODY] + TO_START,
            keys("right", 4),
            ["key down", "key down"],
            ["text |"],
        ],
        "expect": [commit("abcdef\nxy\nabcd|ef")],
    },
    {
        "name": "Shift+Up extends the selection across lines",
        "text": "abcdef\nxy\nabcdef",
        "batches": [
            [CLICK_BODY] + TO_START,
            keys("right", 4),
            ["key down", "key down"],
            ["key shift+up", "key shift+up"],
            ["text X"],
        ],
        "expect": [commit("abcdXef")],
    },
    {
        "name": "clicks above and below the text reach its two ends",
        "text": "ab\ncd",
        "batches": [
            [f"click {BODY_BOTTOM_RIGHT}"],
            ["text >"],
            [f"click {BODY_TOP_LEFT}"],
            ["text <"],
        ],
        "expect": [commit("ab\ncd>"), commit("<ab\ncd>")],
    },
    {
        "name": "a drag from corner to corner selects every line",
        "text": "ab\ncd",
        "batches": [
            [f"down {BODY_TOP_LEFT}", f"move {BODY_BOTTOM_RIGHT}", f"up {BODY_BOTTOM_RIGHT}"],
            ["text Z"],
        ],
        "expect": [commit("Z")],
    },
    {
        "name": "composition on a later line commits once, and Enter stays with the IME",
        "text": "一行目\n",
        "batches": [
            [CLICK_BODY] + TO_END,
            ["preedit にほ"],
            ["key enter", "key backspace"],
            ["text 日本"],
            ["preedit ご"],
            ["key escape"],
            ["text !"],
        ],
        "expect": [
            composing(True),
            commit("一行目\n日本"),
            composing(False),
            composing(True),
            composing(False),
            commit("一行目\n日本!"),
        ],
    },
    {
        "name": "composition queued behind Enter starts on the new line",
        "text": "一行目",
        "batches": [
            [CLICK_BODY] + TO_END,
            ["key enter", "preedit か", "text 蚊"],
        ],
        "expect": [
            commit("一行目\n"),
            composing(True),
            commit("一行目\n蚊"),
            composing(False),
        ],
    },
    {
        "name": "composition replaces a selection that spans lines",
        "text": "one\ntwo",
        "batches": [
            [CLICK_BODY] + TO_END,
            keys("shift+left", 5),
            ["preedit ぶん"],
            ["text 文"],
        ],
        "expect": [composing(True), commit("on文"), composing(False)],
    },
    {
        "name": "a line break the app refuses leaves the caret where it was",
        "text": "ab\ncd",
        "max_lines": 2,
        "batches": [[CLICK_BODY] + TO_END, ["key left"], ["key enter"], ["text X"]],
        "expect": [reject("ab\nc\nd"), commit("ab\ncXd")],
    },
    {
        "name": "Tab moves focus and inserts nothing",
        "text": "ab\ncd",
        "batches": [[CLICK_BODY] + TO_END, ["key tab"], ["text !"]],
        "expect": [commit("Title!", TITLE)],
    },
    {
        "name": "a driver replace_text with two lines reaches the app intact",
        "text": "ab",
        "batches": [
            driver("edits", "1", reply={"ok": True, "revision": 0, "edits": [{"name": "replace_text", "argument": "text"}]}),
            driver(
                "preview", "1", "replace_text", "0", "text", AGENT_TEXT,
                reply={"ok": True, "revision": 0, "argument": {"kind": "text", "text": AGENT_TEXT}},
            ),
            driver("inspect", "note.body", reply={"ok": True, "elements": [{"id": 1, "text": "ab"}]}),
            driver("commit", "1", "replace_text", "0", "text", AGENT_TEXT, reply={"ok": True, "id": 1, "revision": 1}),
            driver("inspect", "note.body", reply={"ok": True, "elements": [{"id": 1, "text": AGENT_TEXT}]}),
            driver("commit", "1", "replace_text", "0", "text", "late", reply={"ok": False, "error": "Stale_Revision", "revision": 1}),
            [CLICK_BODY] + TO_END,
            ["text !"],
            driver("edits", "1", reply={"ok": True, "revision": 2}),
        ],
        "expect": [edit(AGENT_TEXT), commit(AGENT_TEXT + "!")],
    },
    {
        "name": "a driver edit stands aside for a composition, then needs the new revision",
        "text": "一行目\n",
        "batches": [
            [CLICK_BODY] + TO_END,
            ["preedit か"],
            driver("commit", "1", "replace_text", "0", "text", "x\ny", reply={"ok": False, "error": "Busy_Composing"}),
            ["text 蚊"],
            driver("commit", "1", "replace_text", "0", "text", "x\ny", reply={"ok": False, "error": "Stale_Revision", "revision": 1}),
            driver("commit", "1", "replace_text", "1", "text", "x\ny", reply={"ok": True, "revision": 2}),
            driver("inspect", "note.body", reply={"ok": True, "elements": [{"text": "x\ny"}]}),
        ],
        "expect": [
            composing(True),
            commit("一行目\n蚊"),
            composing(False),
            edit("x\ny"),
        ],
    },
    {
        "name": "two text events queued in one write arrive once each, in order",
        "text": "",
        "batches": [[CLICK_TITLE] + TO_END, ["text a", "text b"]],
        "expect": [commit("Titlea", TITLE), commit("Titleab", TITLE)],
    },
    {
        "name": "the single-line field still refuses Enter and a two-line paste",
        "text": "",
        "batches": [
            [CLICK_TITLE] + TO_END,
            ["key enter"],
            ["clipboard x\\ny", "key ctrl+v"],
            ["text !"],
        ],
        "expect": [commit("Title!", TITLE)],
    },
]


class Window:
    def __init__(self, binary, client, text, max_lines):
        self.client = client
        self.socket = Path(tempfile.mkdtemp(prefix="dagda-multiline-sock-")) / "note.sock"
        args = [str(binary), "--size", "960x540", "--control-stdin", "--socket", str(self.socket)]
        args += ["--text", escape(text)]
        if max_lines:
            args += ["--max-lines", str(max_lines)]
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

    def drive(self, args, expected):
        """Runs dagda-client and records any part of the reply that differs."""
        done = subprocess.run([str(self.client), str(self.socket), *args], capture_output=True, text=True, timeout=10)
        try:
            reply = json.loads(done.stdout)
        except json.JSONDecodeError:
            reply = {"unreadable": done.stdout, "stderr": done.stderr}
        if not contains(reply, expected):
            self.errors.append(f"driver {' '.join(escape(a) for a in args)}: wanted {expected}, got {reply}")
        self.settle()

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
        """Keeps an app callback line; returns True for a control reply."""
        if line.startswith("CONTROL_"):
            if line.startswith("CONTROL_ERR"):
                self.errors.append(line)
            return True
        kind, _, rest = line.partition(" ")
        if kind == "COMPOSITION":
            field, flag = rest.split(" ")
            self.events.append((kind, int(field[3:]), flag == "composing=true"))
        elif kind in ("COMMIT", "REJECT", "UNDO", "EDIT"):
            head, _, text = rest.partition("text=")
            self.events.append((kind, int(head.split()[0][3:]), unescape(text)))
        return False

    def wait_ready(self):
        while not self.read_line().startswith("READY"):
            pass
        self.settle()

    def settle(self):
        """Returns once every event queued before this call has been handled.

        The host reads control lines after draining its event queue, so the
        reply to a line written now cannot come before that.
        """
        self.proc.stdin.write(b"window-info\n")
        self.proc.stdin.flush()
        while True:
            line = self.read_line()
            if self.note(line) and "window-info" in line:
                return

    def send(self, batch):
        data = "".join(line + "\n" for line in batch).encode("utf-8")
        assert len(data) < 1000, "keep a batch inside one host read"
        self.proc.stdin.write(data)
        self.proc.stdin.flush()
        replies = 0
        while replies < len(batch):
            if self.note(self.read_line()):
                replies += 1
        self.settle()


def contains(reply, expected):
    """True when reply holds everything expected does, lists matched by position."""
    if isinstance(expected, dict):
        return isinstance(reply, dict) and all(k in reply and contains(reply[k], v) for k, v in expected.items())
    if isinstance(expected, list):
        return isinstance(reply, list) and len(reply) == len(expected) and all(map(contains, reply, expected))
    return reply == expected and type(reply) is type(expected)


def show(event):
    kind, field, value = event
    if kind == "COMPOSITION":
        return f"COMPOSITION id={field} composing={'true' if value else 'false'}"
    return f"{kind} id={field} text={escape(value)}"


def run_scenario(binary, client, scenario):
    window = Window(binary, client, scenario["text"], scenario.get("max_lines", 0))
    problem = None
    try:
        window.wait_ready()
        for batch in scenario["batches"]:
            if isinstance(batch, tuple):
                window.drive(batch[1], batch[2])
            else:
                window.send(batch)
    except (TimeoutError, EOFError, subprocess.TimeoutExpired) as err:
        problem = str(err)
    finally:
        window.close()
    lines = []
    if problem:
        lines.append(f"stopped early: {problem}")
    lines += [err if err.startswith("driver") else f"host refused: {err}" for err in window.errors]
    if window.events != scenario["expect"]:
        lines.append("expected:")
        lines += [f"    {show(e)}" for e in scenario["expect"]] or ["    (no callbacks)"]
        lines.append("got:")
        lines += [f"    {show(e)}" for e in window.events] or ["    (no callbacks)"]
    return lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="run scenarios whose name contains this text")
    opts = parser.parse_args()

    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
    multiline = os.environ.get("MULTILINE") == "1"

    with tempfile.TemporaryDirectory(prefix="dagda-multiline-") as tmp:
        binary = Path(tmp) / "multiline-text"
        build = [ODIN, "build", str(EXAMPLE), f"-collection:dagda={ROOT}", f"-out:{binary}"]
        if multiline:
            build.append("-define:MULTILINE=true")
        if subprocess.call(build, cwd=ROOT) != 0:
            print("\nthe fixture did not build" + (" with its multiline opt-in" if multiline else ""))
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

    mode = "multiline opt-in" if multiline else "today's single-line host"
    driver = os.environ["SDL_VIDEODRIVER"]
    print(f"\n{len(chosen) - failed} of {len(chosen)} scenarios passed ({mode}, SDL {driver})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
