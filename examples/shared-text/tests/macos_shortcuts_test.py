#!/usr/bin/env python3
"""macOS primary-shortcut process check (dummy video driver).

Drives the shared-text window through the normal host event
path with Command chords (control-stdin injects SDL key events
carrying the GUI modifier; no physical IME is involved):
select and cut decomposed text, verify the exact UTF-8 on
paste, undo to the original bytes with the app-owned revision
and history, then exercise app-level undo in the worker app
after focus moves away. Isolated SDL dummy clipboard only.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_shared_text as base

ROOT = base.ROOT
ODIN = base.ODIN
DECOMPOSED = "Cafe\u0301"


def start(app_bin, client_bin, tmp, name, size="800x540", env_extra=None):
    sock_dir = tmp / name
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "app.sock"
    env = {**os.environ, "SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy", **(env_extra or {})}
    proc = subprocess.Popen([str(app_bin), "--size", size, "--socket", str(sock), "--control-stdin"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            bufsize=0, env=env, cwd=ROOT)
    reader = base.DeadlineLineReader(proc.stdout)
    assert reader.read_line("startup", timeout=10.0) == f"Listening {sock}"
    return proc, reader, sock


def inspect(client_bin, sock, role):
    _, resp = base.run_client(client_bin, sock, "inspect", role)
    return resp["elements"][0]


def status(client_bin, sock):
    return inspect(client_bin, sock, "shared.status")["text"]


def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-macos-shortcuts."))
    proc = None
    try:
        shared_bin, worker_bin, client_bin = tmp / "shared-text", tmp / "worker-rebuild", tmp / "dagda-client"
        for src, out in [("examples/shared-text", shared_bin), ("examples/worker-rebuild", worker_bin), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)

        proc, reader, sock = start(shared_bin, client_bin, tmp, "shared")
        b1 = inspect(client_bin, sock, "outline.title")["bounds"]
        y1 = b1["y"] + b1["height"] / 2
        base.send_control(proc, reader, f"click {b1['x'] + b1['width'] - 10:.2f} {y1:.2f}")
        base.send_control(proc, reader, "key cmd+a")
        base.send_control(proc, reader, f"text {DECOMPOSED}")
        base.wait_for_role_text(client_bin, sock, "outline.title", DECOMPOSED)
        assert status(client_bin, sock).endswith("rev=1, undo=1, last_id=1, actions=0"), status(client_bin, sock)

        # Select f + e-with-acute, copy and cut with Command.
        for cmd in ["key home", "key right", "key right", "key shift+right", "key shift+right"]:
            base.send_control(proc, reader, cmd)
        base.send_control(proc, reader, "key cmd+c")
        base.send_control(proc, reader, "key cmd+x")
        base.wait_for_role_text(client_bin, sock, "outline.title", "Ca")
        assert status(client_bin, sock).endswith("rev=2, undo=2, last_id=1, actions=0"), status(client_bin, sock)
        # Paste the exact decomposed bytes back at the caret,
        # then a focused Command+Z undoes exactly that paste.
        base.send_control(proc, reader, "key cmd+v")
        pasted = base.wait_for_role_text(client_bin, sock, "outline.title", DECOMPOSED)
        assert pasted["elements"][0]["text"].encode("utf-8") == DECOMPOSED.encode("utf-8")
        assert status(client_bin, sock).endswith("rev=3, undo=3, last_id=1, actions=0"), status(client_bin, sock)
        base.send_control(proc, reader, "key cmd+z")
        base.wait_for_role_text(client_bin, sock, "outline.title", "Ca")
        assert status(client_bin, sock).endswith("rev=4, undo=2, last_id=1, actions=0"), status(client_bin, sock)
        base.send_control(proc, reader, "quit")
        proc.wait(timeout=10)
        proc = None
        print("[mac] Command select/cut/paste/undo with decomposed text passed")

        # App-level undo after focus moves away (worker fixture).
        proc, reader, sock = start(worker_bin, client_bin, tmp, "worker")
        field = inspect(client_bin, sock, "worker.field")
        fb = field["bounds"]
        base.send_control(proc, reader, f"click {fb['x'] + fb['width'] - 5:.2f} {fb['y'] + fb['height'] / 2:.2f}")
        base.send_control(proc, reader, "text X")
        assert inspect(client_bin, sock, "worker.field")["text"] == "FieldX"
        label = inspect(client_bin, sock, "worker.label")
        lb = label["bounds"]
        base.send_control(proc, reader, f"click {lb['x'] + 20:.2f} {lb['y'] + lb['height'] / 2:.2f}")
        base.send_control(proc, reader, "key cmd+z")
        deadline = time.monotonic() + 5
        text = None
        while time.monotonic() < deadline:
            text = inspect(client_bin, sock, "worker.field")["text"]
            if text == "Field":
                break
            time.sleep(0.02)
        assert text == "Field", text
        base.send_control(proc, reader, "quit")
        proc.wait(timeout=10)
        proc = None
        print("[mac] app-level Command+Z after focus moved away passed")
        print("macos shortcuts process check passed (SDL dummy driver, injected SDL events, no physical IME)")
        return 0
    finally:
        base.stop_process(proc)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
