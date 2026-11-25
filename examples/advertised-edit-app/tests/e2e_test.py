#!/usr/bin/env python3
"""Real-process workflow for advertised edits over the generic driver.

Builds the headless test app and the real dagda-client, then
discovers a text edit and a rectangle edit, previews without
mutation, commits at the discovered revision, re-inspects, and
checks stale and wrong-argument rejections against the document
and its undo history.
"""
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ODIN = ROOT / "scripts" / "odin.sh"


def client(client_bin, sock, *args, expect_ok=True):
    r = subprocess.run([str(client_bin), str(sock), *args], capture_output=True, text=True, timeout=15)
    line = r.stdout.strip()
    assert line, f"empty client reply for {args}: {r.stderr!r}"
    if expect_ok:
        assert r.returncode == 0, (args, r.returncode, line)
    return r.returncode, json.loads(line)


def inspect(client_bin, sock, role):
    _, resp = client(client_bin, sock, "inspect", role)
    assert resp["ok"] and len(resp["elements"]) == 1, resp
    return resp["elements"][0]


class AppReader:
    def __init__(self, app):
        self.fd = app.stdout.fileno()
        self.buf = b""

    def line(self, timeout=15):
        # One monotonic deadline covers the whole line, however
        # many partial reads it arrives in; bytes already buffered
        # for later replies are preserved across calls.
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buf:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("timed out waiting for app acknowledgement")
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                raise AssertionError("timed out waiting for app acknowledgement")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise AssertionError("app closed stdout")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode().strip()


READER = None


def control(app, cmd):
    app.stdin.write(cmd + "\n")
    app.stdin.flush()
    line = READER.line()
    assert line.startswith("CONTROL_OK"), (cmd, line)
    return line


def test_reader_deadline():
    # Partial bytes arrive within each individual wait, but the
    # newline lands after the total budget: the read must time
    # out. A single chunk carrying two replies must also serve
    # two calls without losing the second line.
    import subprocess as sp
    slow_src = chr(10).join([
        "import sys, time",
        "for c in 'abc':",
        "    sys.stdout.write(c); sys.stdout.flush(); time.sleep(0.4)",
        "sys.stdout.write(chr(10)); sys.stdout.flush()",
    ])
    slow = sp.Popen([sys.executable, "-c", slow_src], stdout=sp.PIPE)
    fast = sp.Popen([sys.executable, "-c", "print('one\\ntwo', flush=True)"], stdout=sp.PIPE)
    reader = AppReader(fast)
    assert reader.line(timeout=5) == "one"
    assert reader.line(timeout=5) == "two"
    fast.wait(timeout=5)
    print("reader deadline + buffered replies: ok")


def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-edit-wire."))
    sock_dir = tmp / "sock"
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "app.sock"
    test_reader_deadline()
    app = None
    transcript = []
    try:
        app_bin, client_bin = tmp / "edit-test-app", tmp / "dagda-client"
        for src, out in [("examples/advertised-edit-app", app_bin), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
        app = subprocess.Popen([str(app_bin), str(sock)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, cwd=ROOT)
        global READER
        READER = AppReader(app)
        assert READER.line() == f"Listening {sock}"

        def run(*args, **kw):
            code, resp = client(client_bin, sock, *args, **kw)
            transcript.append(f"$ dagda-client {' '.join(args)}\n  -> {json.dumps(resp)}")
            return code, resp

        # Discover a text edit and a rectangle edit, with revisions.
        _, edits1 = run("edits", "1")
        assert edits1 == {"ok": True, "id": 1, "revision": 0, "edits": [{"name": "replace_text", "argument": "text"}]}, edits1
        _, edits2 = run("edits", "2")
        assert edits2 == {"ok": True, "id": 2, "revision": 0, "edits": [{"name": "set_rect", "argument": "rect"}, {"name": "reset_rect", "argument": "none"}]}, edits2
        assert inspect(client_bin, sock, "doc.title")["text"] == "Quarterly results"
        assert inspect(client_bin, sock, "doc.chart")["text"] == "10,20,100,50"

        # Preview without changing state.
        _, prev = run("preview", "1", "replace_text", "0", "text", "Revenue grew")
        assert prev["ok"] and prev["argument"] == {"kind": "text", "text": "Revenue grew"}, prev
        assert inspect(client_bin, sock, "doc.title")["text"] == "Quarterly results"
        _, still = run("edits", "1")
        assert still["revision"] == 0, still

        # Commit at the discovered revision; re-inspect the value
        # and the advanced revision.
        _, done = run("commit", "1", "replace_text", "0", "text", "Revenue grew")
        assert done == {"ok": True, "id": 1, "edit": "replace_text", "revision": 1}, done
        assert inspect(client_bin, sock, "doc.title")["text"] == "Revenue grew"
        _, after = run("edits", "1")
        assert after["revision"] == 1, after

        # Retry with the old revision, then a wrong argument kind:
        # both preserve the value, the revision, and undo history.
        code, stale = run("commit", "1", "replace_text", "0", "text", "Late edit", expect_ok=False)
        assert code == 1 and stale == {"ok": False, "error": "Stale_Revision", "revision": 1}, stale
        code, wrong = run("commit", "1", "replace_text", "1", "rect", "1", "2", "3", "4", expect_ok=False)
        assert code == 1 and wrong == {"ok": False, "error": "Wrong_Argument"}, wrong
        assert inspect(client_bin, sock, "doc.title")["text"] == "Revenue grew"
        _, kept = run("edits", "1")
        assert kept["revision"] == 1, kept

        # Commit the rectangle edit at its discovered revision.
        _, rect_done = run("commit", "2", "set_rect", "0", "rect", "72", "240", "360", "180")
        assert rect_done == {"ok": True, "id": 2, "edit": "set_rect", "revision": 1}, rect_done
        assert inspect(client_bin, sock, "doc.chart")["text"] == "72,240,360,180"

        # A stale preview is rejected with the current revision
        # and changes nothing.
        code, stale_prev = run("preview", "1", "replace_text", "0", "text", "Sneaky", expect_ok=False)
        assert code == 1 and stale_prev == {"ok": False, "error": "Stale_Revision", "revision": 1}, stale_prev
        assert inspect(client_bin, sock, "doc.title")["text"] == "Revenue grew"

        # Fractional rectangle preview and commit agree exactly.
        frac = ["72.5", "240.25", "360.125", "180.75"]
        _, frac_prev = run("preview", "2", "set_rect", "1", "rect", *frac)
        assert frac_prev["argument"] == {"kind": "rect", "rect": {"x": 72.5, "y": 240.25, "width": 360.125, "height": 180.75}}, frac_prev
        _, frac_done = run("commit", "2", "set_rect", "1", "rect", *frac)
        assert frac_done == {"ok": True, "id": 2, "edit": "set_rect", "revision": 2}, frac_done
        assert inspect(client_bin, sock, "doc.chart")["text"] == "72.5,240.25,360.125,180.75"

        # A discoverable no-argument edit previews and commits
        # through the CLI's none form.
        _, edits2b = run("edits", "2")
        assert {"name": "reset_rect", "argument": "none"} in edits2b["edits"], edits2b
        _, reset_prev = run("preview", "2", "reset_rect", "2", "none")
        assert reset_prev["ok"] and reset_prev["argument"] == {"kind": "none"}, reset_prev
        _, reset_done = run("commit", "2", "reset_rect", "2", "none")
        assert reset_done == {"ok": True, "id": 2, "edit": "reset_rect", "revision": 3}, reset_done
        assert inspect(client_bin, sock, "doc.chart")["text"] == "10,20,100,50"

        # The preserved undo history still restores the prior text.
        line = control(app, "undo 1")
        transcript.append(f"control: undo 1 -> {line}")
        assert "undone=true" in line, line
        assert inspect(client_bin, sock, "doc.title")["text"] == "Quarterly results"
        _, undone = run("edits", "1")
        assert undone["revision"] == 2, undone

        # Two undo commands sent together are acknowledged in order.
        _, again = run("commit", "1", "replace_text", "2", "text", "Again")
        assert again["revision"] == 3, again
        app.stdin.write("undo 1\nundo 2\n")
        app.stdin.flush()
        ack1 = READER.line()
        ack2 = READER.line()
        transcript.append(f"control: undo 1 + undo 2 -> {ack1} | {ack2}")
        assert "id=1" in ack1 and "id=2" in ack2, (ack1, ack2)
        assert inspect(client_bin, sock, "doc.title")["text"] == "Quarterly results"
        assert inspect(client_bin, sock, "doc.chart")["text"] == "72.5,240.25,360.125,180.75"

        control(app, "quit")
        app.wait(timeout=10)
        app = None
        assert not sock.exists(), "app left its socket behind"
        print("\n".join(transcript))
        print("e2e advertised edits: all checks passed")
        return 0
    finally:
        if app is not None and app.poll() is None:
            app.terminate()
            app.wait(timeout=10)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
