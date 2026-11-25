#!/usr/bin/env python3
"""End-to-end verification of examples/title-window over --socket using the real
examples/title-driver-client binary on a live Linux display.

Window-side typing, composition, cancellation, and Ctrl+Z undo are injected via
SDL3 events on the window thread (--control-stdin); client requests come from
real title-client subprocesses over a private-directory Unix socket.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ODIN = ROOT / "scripts" / "odin.sh"


def run_client(client_bin: Path, sock: Path, *args: str) -> tuple[int, dict]:
    proc = subprocess.run(
        [str(client_bin), str(sock), *args],
        capture_output=True,
        text=True,
        timeout=10,
    )
    line = proc.stdout.strip()
    assert line, f"empty stdout from title-client {args}: stderr={proc.stderr!r}"
    return proc.returncode, json.loads(line)


def send_control(win_proc: subprocess.Popen, cmd: str) -> str:
    assert win_proc.stdin is not None and win_proc.stdout is not None
    win_proc.stdin.write(cmd + "\n")
    win_proc.stdin.flush()
    resp = win_proc.stdout.readline().strip()
    assert resp.startswith("CONTROL_OK"), f"control {cmd!r} failed: {resp!r}"
    return resp


def main() -> int:
    capture_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build" / "window-driver-capture"
    capture_dir.mkdir(parents=True, exist_ok=True)

    build_dir = ROOT / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    win_bin = build_dir / "title-window"
    client_bin = build_dir / "title-client"

    subprocess.check_call([str(ODIN), "build", "examples/title-window", "-collection:dagda=.", f"-out:{win_bin}"], cwd=ROOT)
    subprocess.check_call([str(ODIN), "build", "examples/title-driver-client", "-collection:dagda=.", f"-out:{client_bin}"], cwd=ROOT)

    sock_dir = Path(tempfile.mkdtemp(prefix="dagda-win-driver."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "title.sock"
    win_proc = None
    partial_sock = None

    try:
        win_proc = subprocess.Popen(
            [str(win_bin), "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        assert win_proc.stdout is not None
        ready_line = win_proc.stdout.readline().strip()
        assert ready_line == f"Listening {sock}", f"unexpected startup line: {ready_line!r}"
        print(f"[1] Started window: {ready_line}")

        # Open an idle, partially written client connection to verify window stays responsive.
        partial_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        partial_sock.connect(str(sock))
        partial_sock.sendall(b'{"op":"insp')

        # Type in the window while partial client is connected.
        print("[2] Window type:", send_control(win_proc, "type  — Q4"))

        # Inspect and preview from real title-client process.
        code, resp = run_client(client_bin, sock, "inspect", "slide.title")
        assert code == 0 and resp == {
            "ok": True,
            "id": 1,
            "revision": 1,
            "text": "Quarterly results — Q4",
            "role": "slide.title",
        }, f"unexpected inspect: {code} {resp}"
        print("[3] Client inspect:", resp)

        code, resp = run_client(client_bin, sock, "preview", "1", "1", "Revenue grew 12%")
        assert code == 0 and resp == {
            "ok": True,
            "id": 1,
            "revision": 1,
            "text": "Revenue grew 12%",
        }, f"unexpected preview: {code} {resp}"
        print("[4] Client preview:", resp)

        # Enter active non-ASCII composition in the window.
        print("[5] Window preedit:", send_control(win_proc, "preedit 2 0 café"))

        # Inspect & preview succeed during composition.
        code, resp = run_client(client_bin, sock, "inspect", "slide.title")
        assert code == 0 and resp["revision"] == 1 and resp["text"] == "Quarterly results — Q4", resp
        code, resp = run_client(client_bin, sock, "preview", "1", "1", "Revenue grew 12%")
        assert code == 0 and resp["revision"] == 1 and resp["text"] == "Revenue grew 12%", resp

        # Valid commit and undo during composition must return Busy_Composing.
        code, resp = run_client(client_bin, sock, "commit", "1", "1", "Revenue grew 12%")
        assert code == 1 and resp == {"ok": False, "error": "Busy_Composing"}, f"expected Busy_Composing commit: {code} {resp}"
        print("[6] Busy commit during preedit:", resp)

        code, resp = run_client(client_bin, sock, "undo", "1", "1")
        assert code == 1 and resp == {"ok": False, "error": "Busy_Composing"}, f"expected Busy_Composing undo: {code} {resp}"
        print("[7] Busy undo during preedit:", resp)

        status_during = send_control(win_proc, "status")
        assert 'preedit="café"' in status_during and "focused=true" in status_during and "composing=true" in status_during, status_during
        send_control(win_proc, f"screenshot {capture_dir / '01-driver-busy-composing.png'}")

        # Cancel composition cleanly.
        print("[8] Window escape:", send_control(win_proc, "escape"))

        # Commit externally against inspected revision 1.
        code, resp = run_client(client_bin, sock, "commit", "1", "1", "Revenue grew 12%")
        assert code == 0 and resp == {
            "ok": True,
            "id": 1,
            "revision": 2,
            "text": "Revenue grew 12%",
        }, f"unexpected external commit: {code} {resp}"
        print("[9] Client external commit:", resp)
        send_control(win_proc, f"screenshot {capture_dir / '02-driver-external-commit.png'}")

        # Stale request rejected with current revision 2.
        code, resp = run_client(client_bin, sock, "commit", "1", "1", "Stale rename")
        assert code == 1 and resp == {
            "ok": False,
            "error": "Stale_Revision",
            "revision": 2,
        }, f"unexpected stale reply: {code} {resp}"
        print("[10] Client stale commit:", resp)

        # Undo from the keyboard in the window.
        print("[11] Window Ctrl+Z undo:", send_control(win_proc, "undo"))
        send_control(win_proc, f"screenshot {capture_dir / '03-driver-after-undo.png'}")

        # Re-inspect from the client: restored title and advanced revision 3.
        code, resp = run_client(client_bin, sock, "inspect", "slide.title")
        assert code == 0 and resp == {
            "ok": True,
            "id": 1,
            "revision": 3,
            "text": "Quarterly results — Q4",
            "role": "slide.title",
        }, f"unexpected post-undo inspect: {code} {resp}"
        print("[12] Client post-undo inspect:", resp)

        # Complete the partial client request to confirm it still receives a reply.
        partial_sock.sendall(b'ect","role":"slide.title"}\n')
        partial_reply = partial_sock.recv(4096).decode("utf-8").strip()
        assert json.loads(partial_reply) == resp, f"unexpected partial-client reply: {partial_reply!r}"
        print("[13] Partial client completed:", partial_reply)

        send_control(win_proc, "quit")
        win_proc.wait(timeout=5)
        assert win_proc.returncode == 0, f"window exited {win_proc.returncode}"
        assert not sock.exists(), "socket file was not cleaned up on shutdown"
        print("[14] Clean shutdown & socket cleanup verified.")

        # Failed screenshot must exit nonzero AND clean up its owned socket so
        # a new window can immediately bind the same socket path.
        win_fail = subprocess.Popen(
            [str(win_bin), "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        try:
            assert win_fail.stdout is not None and win_fail.stdin is not None
            ready2 = win_fail.stdout.readline().strip()
            assert ready2 == f"Listening {sock}", f"unexpected restart line: {ready2!r}"
            missing_shot = sock_dir / "missing-subdir" / "fail.png"
            win_fail.stdin.write(f"screenshot {missing_shot}\n")
            win_fail.stdin.flush()
            err_line = win_fail.stdout.readline().strip()
            assert err_line.startswith("CONTROL_ERR"), f"expected CONTROL_ERR, got {err_line!r}"
            win_fail.wait(timeout=5)
            assert win_fail.returncode != 0, f"expected nonzero exit on screenshot failure, got {win_fail.returncode}"
            assert not sock.exists(), "socket file was NOT removed after failed screenshot"
            print(f"[15] Failed screenshot exited {win_fail.returncode} and removed socket.")
        finally:
            if win_fail.poll() is None:
                win_fail.terminate()
                win_fail.wait(timeout=5)

        # Start a fresh window on the exact same socket path to prove cleanup succeeded.
        win_reuse = subprocess.Popen(
            [str(win_bin), "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        try:
            assert win_reuse.stdout is not None
            ready3 = win_reuse.stdout.readline().strip()
            assert ready3 == f"Listening {sock}", f"could not reuse socket path: {ready3!r}"
            code, resp = run_client(client_bin, sock, "inspect", "slide.title")
            assert code == 0 and resp["revision"] == 0 and resp["text"] == "Quarterly results", (code, resp)
            send_control(win_reuse, "quit")
            win_reuse.wait(timeout=5)
            assert win_reuse.returncode == 0 and not sock.exists()
            print("[16] Reused same socket path on fresh window and cleaned up.")
        finally:
            if win_reuse.poll() is None:
                win_reuse.terminate()
                win_reuse.wait(timeout=5)

        return 0
    finally:
        if partial_sock is not None:
            partial_sock.close()
        if win_proc is not None and win_proc.poll() is None:
            win_proc.terminate()
            win_proc.wait(timeout=5)
        shutil.rmtree(sock_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
