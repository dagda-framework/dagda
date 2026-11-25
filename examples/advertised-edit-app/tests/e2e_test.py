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
import shutil
import subprocess
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


def control(app, cmd):
    app.stdin.write(cmd + "\n")
    app.stdin.flush()
    line = app.stdout.readline().strip()
    assert line.startswith("CONTROL_OK"), (cmd, line)
    return line


def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-edit-wire."))
    sock_dir = tmp / "sock"
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "app.sock"
    app = None
    transcript = []
    try:
        app_bin, client_bin = tmp / "edit-test-app", tmp / "dagda-client"
        for src, out in [("examples/advertised-edit-app", app_bin), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
        app = subprocess.Popen([str(app_bin), str(sock)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, cwd=ROOT)
        assert app.stdout.readline().strip() == f"Listening {sock}"

        def run(*args, **kw):
            code, resp = client(client_bin, sock, *args, **kw)
            transcript.append(f"$ dagda-client {' '.join(args)}\n  -> {json.dumps(resp)}")
            return code, resp

        # Discover a text edit and a rectangle edit, with revisions.
        _, edits1 = run("edits", "1")
        assert edits1 == {"ok": True, "id": 1, "revision": 0, "edits": [{"name": "replace_text", "argument": "text"}]}, edits1
        _, edits2 = run("edits", "2")
        assert edits2 == {"ok": True, "id": 2, "revision": 0, "edits": [{"name": "set_rect", "argument": "rect"}]}, edits2
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

        # The preserved undo history still restores the prior text.
        line = control(app, "undo 1")
        transcript.append(f"control: undo 1 -> {line}")
        assert "undone=true" in line, line
        assert inspect(client_bin, sock, "doc.title")["text"] == "Quarterly results"
        _, undone = run("edits", "1")
        assert undone["revision"] == 2, undone

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
