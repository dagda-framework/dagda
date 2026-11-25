#!/usr/bin/env python3
"""VisiDeck acceptance: an agent preview must not disturb a live
headline composition, and its stale commit must not steal the
person's finished edit.

Sequence (one headline, one revision counter, one undo history,
shared by the window keyboard path and a real dagda-client):
select "Canvas" and start a visible preedit -> record title and
revision R -> client previews "Agent draft" at R -> inspection
still reads the original at R and the composing highlight/caret
stay -> finish the composition with "é" (no click or refocus) ->
both views read "Slide é" at R+1 with one undo entry -> the
agent commit at the original R is Stale_Revision at R+1 ->
Ctrl+Z once -> exact original bytes in both views at R+2, undo
entry consumed. The composing capture taken after the agent
preview is retained under build/agent-acceptance/.
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
import acceptance_test as base

ROOT = base.ROOT
ODIN = base.ODIN


def client(client_bin, sock, *args, expect_ok=True):
    code, resp = base.run_client(client_bin, sock, *args)
    if expect_ok:
        assert code == 0, (args, code, resp)
    return code, resp


def headline(client_bin, sock):
    _, resp = client(client_bin, sock, "inspect", "slide.headline")
    return resp["elements"][0]


def status(client_bin, sock):
    _, resp = client(client_bin, sock, "inspect", "slide.status")
    return resp["elements"][0]["text"]


def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-agent-acceptance."))
    capture_dir = ROOT / "build" / "agent-acceptance"
    capture_dir.mkdir(parents=True, exist_ok=True)
    composing_capture = capture_dir / "composing-after-agent-preview.png"
    sock_dir = tmp / "sock"
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "canvas.sock"
    proc = None
    try:
        canvas_bin, client_bin = tmp / "canvas-slide", tmp / "dagda-client"
        for src, out in [("examples/canvas-slide", canvas_bin), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
        proc = subprocess.Popen(
            [str(canvas_bin), "--size", "800x540", "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, cwd=ROOT)
        reader = base.DeadlineLineReader(proc.stdout)
        assert reader.read_line("canvas startup", timeout=5.0) == f"Listening {sock}"
        base.send_control(proc, reader, f"screenshot {tmp}/init.png")

        # Discover the headline ID and revision through the client.
        first = headline(client_bin, sock)
        headline_id = first["id"]
        _, edits = client(client_bin, sock, "edits", str(headline_id))
        assert edits["edits"] == [{"name": "replace_text", "argument": "text"}], edits
        R = edits["revision"]
        assert first["text"] == "Slide Canvas" and status(client_bin, sock).endswith(f"rev={R}, undo=0")
        hb = first["bounds"]
        hy = hb["y"] + hb["height"] * 0.5
        print(f"[1] discovered headline id={headline_id} revision R={R}: 'Slide Canvas'")

        # Select "Canvas" and start a visible preedit.
        base.send_control(proc, reader, f"click {hb['x'] + hb['width'] - 10.0:.2f} {hy:.2f}")
        for _ in range(6):
            base.send_control(proc, reader, "key shift+left")
        base.send_control(proc, reader, "preedit e")
        base.wait_for_headline_composing(proc, reader, client_bin, sock, tmp / "composing-before.png",
                                         "Slide Canvas", f"selected=false, clicks=0, rev={R}, undo=0")
        print("[2] visible preedit over selected 'Canvas'")

        # The agent previews its replacement at R.
        _, preview = client(client_bin, sock, "preview", str(headline_id), "replace_text", str(R), "text", "Agent draft")
        assert preview["ok"] and preview["argument"] == {"kind": "text", "text": "Agent draft"}, preview
        assert headline(client_bin, sock)["text"] == "Slide Canvas"
        _, edits_after = client(client_bin, sock, "edits", str(headline_id))
        assert edits_after["revision"] == R, edits_after
        # Composing highlight and caret are still in place; retain
        # this capture after the agent preview.
        base.wait_for_headline_composing(proc, reader, client_bin, sock, composing_capture,
                                         "Slide Canvas", f"selected=false, clicks=0, rev={R}, undo=0")
        print(f"[3] agent preview received; inspection unchanged at R={R}; composing retained ({composing_capture})")

        # Finish the composition with é, without clicking or
        # refocusing: the original selection survived the preview.
        base.send_control(proc, reader, "key enter")
        base.send_control(proc, reader, "text é")
        base.wait_for_role_text(client_bin, sock, "slide.headline", "Slide é")
        base.wait_for_role_text(client_bin, sock, "slide.status", f"selected=false, clicks=0, rev={R + 1}, undo=1")
        _, edits_now = client(client_bin, sock, "edits", str(headline_id))
        assert edits_now["revision"] == R + 1, edits_now
        print(f"[4] composition finished: 'Slide é' at R+1={R + 1}, exactly one undo entry")

        # The agent commit at the original R is now stale.
        code, stale = client(client_bin, sock, "commit", str(headline_id), "replace_text", str(R), "text", "Agent draft", expect_ok=False)
        assert code == 1 and stale == {"ok": False, "error": "Stale_Revision", "revision": R + 1}, stale
        assert headline(client_bin, sock)["text"] == "Slide é"
        print(f"[5] agent commit stale at R+1={R + 1}; person's edit preserved")

        # One Ctrl+Z in the window restores the exact original
        # bytes in both views, at R+2, consuming the undo entry.
        base.send_control(proc, reader, "key ctrl+z")
        restored = base.wait_for_role_text(client_bin, sock, "slide.headline", "Slide Canvas")
        assert restored["elements"][0]["text"].encode("utf-8") == b"Slide Canvas"
        base.wait_for_role_text(client_bin, sock, "slide.status", f"selected=false, clicks=0, rev={R + 2}, undo=0")
        print(f"[6] Ctrl+Z: exact 'Slide Canvas' bytes in both views at R+2={R + 2}, undo consumed")

        base.send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        proc = None
        print("agent preview acceptance: all checks passed")
        return 0
    finally:
        base.stop_process(proc)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
