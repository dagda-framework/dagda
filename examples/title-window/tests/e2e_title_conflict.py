#!/usr/bin/env python3
"""Process test: a person's window edit wins over a stale agent proposal.

Uses the real SDL title window (input injected as SDL events through
--control-stdin, acknowledged on stdout) and the real title-client
over a private Unix socket. The object ID and revision always come
from inspect replies; waits and acknowledgements are bounded.

Sequence: preview "Agent draft" -> person types "!" in the window ->
the original revision-0 proposal is stale at revision 1 -> keyboard
undo restores the title at revision 2 and the proposal stays stale
-> client commits "Q4" at revision 2 -> without any click or focus
command the person types "!" ("Q4!" at revision 4) -> one undo
verifies "Q4" at revision 5.
"""
import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ODIN = ROOT / "scripts" / "odin.sh"
TIMEOUT = 15


class LineSource:
    """Bounded line reader over a process pipe."""

    def __init__(self, proc):
        self.fd = proc.stdout.fileno()
        self.buf = b""

    def line(self, timeout=TIMEOUT):
        while b"\n" not in self.buf:
            ready, _, _ = select.select([self.fd], [], [], timeout)
            if not ready:
                raise AssertionError("timed out waiting for window acknowledgement")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise AssertionError("window closed its output before acknowledging")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode().strip()


def run_client(client_bin, sock, *args):
    proc = subprocess.run([str(client_bin), str(sock), *args],
                          capture_output=True, text=True, timeout=TIMEOUT)
    line = proc.stdout.strip()
    assert line, f"empty stdout from title-client {args}: {proc.stderr!r}"
    return proc.returncode, json.loads(line)


def inspect(client_bin, sock):
    code, resp = run_client(client_bin, sock, "inspect", "slide.title")
    assert code == 0 and resp["ok"], resp
    return resp


def control(source, proc, cmd, expect_rev, expect_text):
    proc.stdin.write(cmd + "\n")
    proc.stdin.flush()
    ack = source.line()
    assert ack.startswith("CONTROL_OK"), f"control {cmd!r} failed: {ack!r}"
    m = re.search(r"rev=(\d+) text=\"([^\"]*)\" focused=(\w+)", ack)
    assert m, f"unparsable acknowledgement: {ack!r}"
    rev, text, focused = int(m.group(1)), m.group(2), m.group(3)
    assert rev == expect_rev, f"{cmd}: revision {rev} != {expect_rev} ({ack})"
    assert text == expect_text, f"{cmd}: text {text!r} != {expect_text!r} ({ack})"
    assert focused == "true", f"{cmd}: window lost keyboard focus ({ack})"
    return ack


def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-title-conflict."))
    sock_dir = tmp / "sock"
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "title.sock"
    win = None
    try:
        win_bin, client_bin = tmp / "title-window", tmp / "title-client"
        for src, out in [("examples/title-window", win_bin),
                         ("examples/title-driver-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.",
                                   f"-out:{out}"], cwd=ROOT)

        win = subprocess.Popen(
            [str(win_bin), "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, cwd=ROOT)
        source = LineSource(win)
        ready = source.line()
        assert ready == f"Listening {sock}", ready
        print("[1] window listening on private socket")

        # Discover the title; every later target uses these values.
        first = inspect(client_bin, sock)
        obj_id, rev0 = first["id"], first["revision"]
        assert (first["text"], rev0) == ("Quarterly results", 0), first
        print(f"[2] inspect: id={obj_id} revision={rev0} text={first['text']!r}")

        # Preview the agent proposal; the document must not change.
        code, resp = run_client(client_bin, sock, "preview", str(obj_id), str(rev0), "Agent draft")
        assert code == 0 and resp == {"ok": True, "id": obj_id, "revision": rev0, "text": "Agent draft"}, resp
        assert inspect(client_bin, sock)["text"] == "Quarterly results"
        print("[3] client preview 'Agent draft': no mutation")

        # The person types first, in the window.
        control(source, win, "type !", 1, "Quarterly results!")
        print("[4] window typed '!': revision 1")

        # The original revision-0 proposal is now stale at revision 1.
        code, resp = run_client(client_bin, sock, "commit", str(obj_id), str(rev0), "Agent draft")
        assert code == 1 and resp == {"ok": False, "error": "Stale_Revision", "revision": 1}, resp
        after = inspect(client_bin, sock)
        assert (after["revision"], after["text"]) == (1, "Quarterly results!"), after
        print("[5] stale proposal rejected; person's text preserved")

        # Keyboard undo in the window restores the title at revision 2,
        # and the rejected proposal stays stale: the person's undo
        # history survived the rejected edit.
        control(source, win, "undo", 2, "Quarterly results")
        code, resp = run_client(client_bin, sock, "commit", str(obj_id), str(rev0), "Agent draft")
        assert code == 1 and resp == {"ok": False, "error": "Stale_Revision", "revision": 2}, resp
        print("[6] keyboard undo to revision 2; proposal still stale")

        # The client commits Q4 at the current revision 2.
        code, resp = run_client(client_bin, sock, "commit", str(obj_id), "2", "Q4")
        assert code == 0 and resp == {"ok": True, "id": obj_id, "revision": 3, "text": "Q4"}, resp
        print("[7] client commit 'Q4': revision 3")

        # No click and no focus command: the window kept keyboard
        # focus across the external commit, so typing lands in it.
        control(source, win, "type !", 4, "Q4!")
        print("[8] window typed '!' without refocusing: 'Q4!' at revision 4")

        # One undo restores Q4 at revision 5.
        control(source, win, "undo", 5, "Q4")
        final = inspect(client_bin, sock)
        assert (final["revision"], final["text"]) == (5, "Q4"), final
        print("[9] undo verified: 'Q4' at revision 5")

        win.stdin.write("quit\n")
        win.stdin.flush()
        assert source.line().startswith("CONTROL_OK")
        win.wait(timeout=TIMEOUT)
        assert win.returncode == 0, win.returncode
        assert not sock.exists(), "window left its socket behind"
        win = None
        print("e2e title conflict: all checks passed")
        return 0
    finally:
        if win is not None and win.poll() is None:
            win.terminate()
            win.wait(timeout=TIMEOUT)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
