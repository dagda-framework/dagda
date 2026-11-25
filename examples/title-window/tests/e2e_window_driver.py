#!/usr/bin/env python3
"""End-to-end verification of examples/title-window over --socket using the real
examples/title-driver-client binary (both one-shot editing commands and `watch`)
on a live Linux display.

Window-side typing, composition, cancellation, and Ctrl+Z undo are injected via
SDL3 events on the window thread (--control-stdin); client requests and watch
subscriptions come from real title-client subprocesses over a private Unix socket.
"""

import json
import os
import select
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


def read_watch_line(proc: subprocess.Popen, timeout: float = 5.0) -> dict:
    assert proc.stdout is not None
    r, _, _ = select.select([proc.stdout], [], [], timeout)
    assert r, "timed out waiting for watch event line"
    line = proc.stdout.readline().strip()
    assert line, "watcher reached unexpected EOF"
    return json.loads(line)


def assert_no_watch_event(proc: subprocess.Popen, wait_sec: float = 0.15) -> None:
    assert proc.stdout is not None
    r, _, _ = select.select([proc.stdout], [], [], wait_sec)
    if r:
        line = proc.stdout.readline().strip()
        raise AssertionError(f"unexpected watch event emitted: {line!r}")


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
    watch_proc = None
    watch2_proc = None
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

        # Start real watching client (`title-client <sock> watch slide.title`).
        watch_proc = subprocess.Popen(
            [str(client_bin), str(sock), "watch", "slide.title"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        initial_snap = read_watch_line(watch_proc)
        assert initial_snap == {
            "ok": True,
            "id": 1,
            "revision": 0,
            "text": "Quarterly results",
            "role": "slide.title",
        }, f"unexpected initial watch snapshot: {initial_snap}"
        print("[2] Watch initial snapshot:", initial_snap)

        # Open an idle, partially written client connection to verify window stays responsive.
        partial_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        partial_sock.connect(str(sock))
        partial_sock.sendall(b'{"op":"insp')

        # Preview, no-op commit, and stale commit must emit NO watch events.
        code, resp = run_client(client_bin, sock, "preview", "1", "0", "Preview draft")
        assert code == 0 and resp["text"] == "Preview draft", (code, resp)
        code, resp = run_client(client_bin, sock, "commit", "1", "0", "Quarterly results")
        assert code == 0 and resp["revision"] == 0, (code, resp)
        code, resp = run_client(client_bin, sock, "commit", "1", "99", "Stale draft")
        assert code == 1 and resp["error"] == "Stale_Revision", (code, resp)
        assert_no_watch_event(watch_proc)
        print("[3] Verified preview, no-op, and stale commit emitted no watch events.")

        # Type in the window while watcher and partial client are connected.
        print("[4] Window type:", send_control(win_proc, "type  — Q4"))
        ev1 = read_watch_line(watch_proc)
        assert ev1 == {
            "event": "commit",
            "id": 1,
            "revision": 1,
            "text": "Quarterly results — Q4",
        }, f"unexpected human-edit watch event: {ev1}"
        print("[5] Watch event (human commit):", ev1)

        # Inspect and preview from real second editing client.
        code, resp = run_client(client_bin, sock, "inspect", "slide.title")
        assert code == 0 and resp == {
            "ok": True,
            "id": 1,
            "revision": 1,
            "text": "Quarterly results — Q4",
            "role": "slide.title",
        }, f"unexpected inspect: {code} {resp}"
        code, resp = run_client(client_bin, sock, "preview", "1", "1", "Revenue grew 12%")
        assert code == 0 and resp == {
            "ok": True,
            "id": 1,
            "revision": 1,
            "text": "Revenue grew 12%",
        }, f"unexpected preview: {code} {resp}"
        assert_no_watch_event(watch_proc)

        # Enter active non-ASCII composition in the window.
        print("[6] Window preedit:", send_control(win_proc, "preedit 2 0 café"))

        # Inspect & preview succeed during composition; valid commit & undo return Busy_Composing and emit no events.
        code, resp = run_client(client_bin, sock, "inspect", "slide.title")
        assert code == 0 and resp["revision"] == 1 and resp["text"] == "Quarterly results — Q4", resp
        code, resp = run_client(client_bin, sock, "commit", "1", "1", "Revenue grew 12%")
        assert code == 1 and resp == {"ok": False, "error": "Busy_Composing"}, (code, resp)
        code, resp = run_client(client_bin, sock, "undo", "1", "1")
        assert code == 1 and resp == {"ok": False, "error": "Busy_Composing"}, (code, resp)
        assert_no_watch_event(watch_proc)

        status_during = send_control(win_proc, "status")
        assert 'preedit="café"' in status_during and "focused=true" in status_during and "composing=true" in status_during, status_during
        send_control(win_proc, f"screenshot {capture_dir / '01-driver-busy-composing.png'}")
        print("[7] Busy commit/undo rejected during preedit with no watch events.")

        # Cancel composition cleanly.
        print("[8] Window escape:", send_control(win_proc, "escape"))

        # Commit externally against inspected revision 1 -> watcher receives commit event at rev 2.
        code, resp = run_client(client_bin, sock, "commit", "1", "1", "Revenue grew 12%")
        assert code == 0 and resp == {
            "ok": True,
            "id": 1,
            "revision": 2,
            "text": "Revenue grew 12%",
        }, f"unexpected external commit: {code} {resp}"
        ev2 = read_watch_line(watch_proc)
        assert ev2 == {
            "event": "commit",
            "id": 1,
            "revision": 2,
            "text": "Revenue grew 12%",
        }, f"unexpected external-commit watch event: {ev2}"
        print("[9] Watch event (external commit):", ev2)
        send_control(win_proc, f"screenshot {capture_dir / '02-driver-external-commit.png'}")

        # Stale request rejected with current revision 2 and no watch event.
        code, resp = run_client(client_bin, sock, "commit", "1", "1", "Stale rename")
        assert code == 1 and resp == {"ok": False, "error": "Stale_Revision", "revision": 2}, (code, resp)
        assert_no_watch_event(watch_proc)

        # Undo from the keyboard in the window -> watcher receives undo event at rev 3.
        print("[10] Window Ctrl+Z undo:", send_control(win_proc, "undo"))
        ev3 = read_watch_line(watch_proc)
        assert ev3 == {
            "event": "undo",
            "id": 1,
            "revision": 3,
            "text": "Quarterly results — Q4",
        }, f"unexpected undo watch event: {ev3}"
        print("[11] Watch event (keyboard undo):", ev3)
        send_control(win_proc, f"screenshot {capture_dir / '03-driver-after-undo.png'}")

        # Disconnect first watcher and reconnect a fresh watcher at latest revision 3.
        watch_proc.terminate()
        watch_proc.wait(timeout=5)
        watch_proc = None

        watch2_proc = subprocess.Popen(
            [str(client_bin), str(sock), "watch", "slide.title"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        reconn_snap = read_watch_line(watch2_proc)
        assert reconn_snap == {
            "ok": True,
            "id": 1,
            "revision": 3,
            "text": "Quarterly results — Q4",
            "role": "slide.title",
        }, f"unexpected reconnect watch snapshot: {reconn_snap}"
        print("[12] Watch reconnect snapshot at latest rev:", reconn_snap)

        # Complete the partial client request to confirm it still receives a reply.
        partial_sock.sendall(b'ect","role":"slide.title"}\n')
        partial_reply = partial_sock.recv(4096).decode("utf-8").strip()
        assert json.loads(partial_reply) == reconn_snap, f"unexpected partial-client reply: {partial_reply!r}"
        print("[13] Partial client completed:", partial_reply)

        send_control(win_proc, "quit")
        win_proc.wait(timeout=5)
        assert win_proc.returncode == 0, f"window exited {win_proc.returncode}"
        watch2_proc.wait(timeout=5)
        assert watch2_proc.returncode == 0, f"reconnected watcher exited {watch2_proc.returncode}"
        assert not sock.exists(), "socket file was not cleaned up on shutdown"
        print("[14] Clean shutdown, watcher EOF exit 0, & socket cleanup verified.")

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
        for proc in (watch_proc, watch2_proc, win_proc):
            if proc is not None and proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)
        shutil.rmtree(sock_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
