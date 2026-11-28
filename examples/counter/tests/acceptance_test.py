#!/usr/bin/env python3
"""Acceptance test for Dagda's native counter app (`examples/counter`).

Launches the real SDL3 counter window at 0 with `--socket` and `--control-stdin`,
discovers the label and button from a separate `dagda-client` process, clicks
inside the discovered button bounds through SDL's event queue (`SDL_PushEvent`
MOUSE_BUTTON_DOWN + MOUSE_BUTTON_UP), invokes `activate` through `dagda-client`
by discovered ID, exercises keyboard focus (Tab + Enter -> 1, external invoke -> 2,
Space -> 3), and retains real-window PNG captures.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
# The pinned compiler: scripts/odin.sh on Linux/macOS, or an explicit odin executable (odin.exe) via ODIN on Windows.
ODIN = os.environ.get("ODIN") or str(ROOT / "scripts" / "odin.sh")
EXE = ".exe" if os.name == "nt" else ""


class DeadlineLineReader:
    """Reads complete newline-terminated UTF-8 lines from a pipe with a hard deadline.

    A daemon thread does the blocking reads (select() on a pipe
    is unavailable on Windows) and hands chunks over under a
    condition; read_line only waits, with its deadline, for a
    full line to arrive.
    """

    def __init__(self, stream) -> None:
        self.fd = stream.fileno()
        self.buf = bytearray()
        self.eof = False
        self.cond = threading.Condition()
        self.worker = threading.Thread(target=self._pump, daemon=True)
        self.worker.start()

    def _pump(self) -> None:
        try:
            while True:
                chunk = os.read(self.fd, 4096)
                with self.cond:
                    if not chunk:
                        self.eof = True
                        self.cond.notify_all()
                        return
                    self.buf.extend(chunk)
                    self.cond.notify_all()
        except OSError:
            with self.cond:
                self.eof = True
                self.cond.notify_all()

    def read_line(self, stage: str, timeout: float = 5.0) -> str:
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                nl = self.buf.find(b"\n")
                if nl >= 0:
                    raw = bytes(self.buf[:nl])
                    del self.buf[: nl + 1]
                    return raw.decode("utf-8", errors="replace").rstrip("\r")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    partial = bytes(self.buf).decode("utf-8", errors="replace")
                    raise TimeoutError(
                        f"timed out after {timeout:.2f}s waiting for complete line during {stage} (partial={partial!r})"
                    )
                if self.eof:
                    partial = bytes(self.buf).decode("utf-8", errors="replace")
                    raise AssertionError(
                        f"unexpected EOF waiting for complete line during {stage} (partial={partial!r})"
                    )
                self.cond.wait(remaining)


def stop_process(proc: subprocess.Popen | None) -> None:
    if proc is None:
        return
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


def run_client(client_bin: Path, sock: Path, *args: str) -> tuple[int, dict]:
    proc = subprocess.run(
        [str(client_bin), str(sock), *args],
        capture_output=True,
        text=True,
        timeout=10,
    )
    line = proc.stdout.strip()
    assert line, f"empty stdout from dagda-client {args}: stderr={proc.stderr!r}"
    return proc.returncode, json.loads(line)


def send_control(
    win_proc: subprocess.Popen,
    reader: DeadlineLineReader,
    cmd: str,
    timeout: float = 5.0,
) -> str:
    assert win_proc.stdin is not None
    win_proc.stdin.write((cmd + "\n").encode("utf-8"))
    win_proc.stdin.flush()
    resp = reader.read_line(f"control {cmd!r}", timeout=timeout)
    assert resp.startswith("CONTROL_OK"), f"control {cmd!r} failed: {resp!r}"
    return resp


def wait_for_counter_value(client_bin: Path, sock: Path, expected: str, timeout: float = 3.0) -> dict:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        code, resp = run_client(client_bin, sock, "inspect", "counter.value")
        last = (code, resp)
        if code == 0 and resp.get("ok") is True and resp["elements"][0]["text"] == expected:
            return resp
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for counter.value == {expected!r}; last={last}")


def verify_timeout_harness() -> None:
    """Prove DeadlineLineReader times out on both a silent child and a partial-line child, and cleans up."""
    # 1. Silent child (never writes anything).
    silent = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(10)"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    try:
        assert silent.stdout is not None
        reader = DeadlineLineReader(silent.stdout)
        try:
            reader.read_line("silent-child startup", timeout=0.15)
            raise AssertionError("expected TimeoutError for silent child")
        except TimeoutError as exc:
            assert "silent-child startup" in str(exc), str(exc)
            print(f"[0a] Timeout check (silent child): PASS ({exc})")
    finally:
        stop_process(silent)
        assert silent.poll() is not None, "silent child was not cleaned up"

    # 2. Partial-line stalling child (writes half an ack without newline, then stalls).
    partial = subprocess.Popen(
        [sys.executable, "-c", "import sys, time; sys.stdout.write('CONTROL_'); sys.stdout.flush(); time.sleep(10)"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    try:
        assert partial.stdout is not None
        reader = DeadlineLineReader(partial.stdout)
        try:
            send_control(partial, reader, "key tab", timeout=0.15)
            raise AssertionError("expected TimeoutError for partial-line child")
        except TimeoutError as exc:
            msg = str(exc)
            assert "control 'key tab'" in msg and "CONTROL_" in msg, msg
            print(f"[0b] Timeout check (partial-line child): PASS ({msg})")
    finally:
        stop_process(partial)
        assert partial.poll() is not None, "partial-line child was not cleaned up"


def main() -> int:
    verify_timeout_harness()

    capture_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build" / "counter-capture"
    capture_dir.mkdir(parents=True, exist_ok=True)

    build_dir = ROOT / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    counter_bin = build_dir / f"counter{EXE}"
    client_bin = build_dir / f"dagda-client{EXE}"

    subprocess.check_call([ODIN, "build", "examples/counter", "-collection:dagda=.", f"-out:{counter_bin}"], cwd=ROOT)
    subprocess.check_call([ODIN, "build", "examples/dagda-client", "-collection:dagda=.", f"-out:{client_bin}"], cwd=ROOT)

    sock_dir = Path(tempfile.mkdtemp(prefix="dagda-counter."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "counter.sock"
    win_proc = None
    kb_proc = None

    try:
        win_proc = subprocess.Popen(
            [str(counter_bin), "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
        )
        assert win_proc.stdout is not None
        win_reader = DeadlineLineReader(win_proc.stdout)
        ready = win_reader.read_line("window startup", timeout=5.0)
        assert ready == f"Listening {sock}", f"unexpected startup line: {ready!r}"
        print(f"[1] Started native counter: {ready}")

        # Inspect label (starts at 0).
        code, val0 = run_client(client_bin, sock, "inspect", "counter.value")
        assert code == 0 and val0["ok"] is True and len(val0["elements"]) == 1, (code, val0)
        label = val0["elements"][0]
        assert label["text"] == "0" and label["kind"] == "label" and label["actions"] == [], label
        print("[2] Client inspect counter.value (initial):", label)

        # Discover button ID, resolved bounds, and advertised activate action.
        code, btn_resp = run_client(client_bin, sock, "inspect", "counter.increment")
        assert code == 0 and btn_resp["ok"] is True and len(btn_resp["elements"]) == 1, (code, btn_resp)
        button = btn_resp["elements"][0]
        btn_id = button["id"]
        bounds = button["bounds"]
        assert button["kind"] == "button" and "activate" in button["actions"], button
        assert bounds["width"] > 0 and bounds["height"] > 0, bounds
        print("[3] Client discovered counter.increment:", button)

        # Click inside the discovered button bounds through SDL's event queue (SDL_PushEvent).
        cx = bounds["x"] + bounds["width"] / 2.0
        cy = bounds["y"] + bounds["height"] / 2.0
        print("[4] Inject SDL mouse click:", send_control(win_proc, win_reader, f"click {cx:.2f} {cy:.2f}"))
        val1 = wait_for_counter_value(client_bin, sock, "1")
        send_control(win_proc, win_reader, f"screenshot {capture_dir / '01-after-sdl-click.png'}")
        print("[5] After SDL click, client inspect counter.value:", val1["elements"][0]["text"])

        # Invoke activate through dagda-client using the discovered button ID.
        code, inv = run_client(client_bin, sock, "invoke", str(btn_id), "activate")
        assert code == 0 and inv == {"ok": True, "id": btn_id, "action": "activate"}, (code, inv)
        val2 = wait_for_counter_value(client_bin, sock, "2")
        send_control(win_proc, win_reader, f"screenshot {capture_dir / '02-after-client-invoke.png'}")
        print("[6] After client invoke, client inspect counter.value:", val2["elements"][0]["text"])

        # Out-of-bounds click and unsupported action on label leave count at 2.
        send_control(win_proc, win_reader, "click 2.00 2.00")
        code, bad_act = run_client(client_bin, sock, "invoke", str(label["id"]), "activate")
        assert code == 1 and bad_act == {"ok": False, "error": "Unsupported_Action"}, (code, bad_act)
        val_still2 = wait_for_counter_value(client_bin, sock, "2")
        assert val_still2["elements"][0]["text"] == "2", val_still2
        print("[7] Out-of-bounds click & unsupported label action left count at 2.")

        send_control(win_proc, win_reader, "quit")
        win_proc.wait(timeout=5)
        assert win_proc.returncode == 0 and not sock.exists()
        win_proc = None
        print("[8] Clean shutdown & socket cleanup verified (pointer + invoke path).")

        # Keyboard focus & activation path in a fresh counter window:
        # 0 -> Tab to Increment -> Enter -> 1 -> client invoke -> 2 -> Space (no re-tab/click) -> 3.
        kb_proc = subprocess.Popen(
            [str(counter_bin), "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
        )
        assert kb_proc.stdout is not None
        kb_reader = DeadlineLineReader(kb_proc.stdout)
        kb_ready = kb_reader.read_line("keyboard window startup", timeout=5.0)
        assert kb_ready == f"Listening {sock}", f"unexpected kb startup line: {kb_ready!r}"

        code, kb0 = run_client(client_bin, sock, "inspect", "counter.value")
        assert code == 0 and kb0["elements"][0]["text"] == "0", (code, kb0)

        send_control(kb_proc, kb_reader, "key tab")
        send_control(kb_proc, kb_reader, "key enter")
        kb1 = wait_for_counter_value(client_bin, sock, "1")
        send_control(kb_proc, kb_reader, f"screenshot {capture_dir / '03-keyboard-focus-enter.png'}")
        print("[9] Keyboard Tab + Enter -> client inspect counter.value:", kb1["elements"][0]["text"])

        code, inv2 = run_client(client_bin, sock, "invoke", str(btn_id), "activate")
        assert code == 0 and inv2 == {"ok": True, "id": btn_id, "action": "activate"}, (code, inv2)
        kb2 = wait_for_counter_value(client_bin, sock, "2")
        print("[10] External client invoke -> client inspect counter.value:", kb2["elements"][0]["text"])

        send_control(kb_proc, kb_reader, "key space")
        kb3 = wait_for_counter_value(client_bin, sock, "3")
        send_control(kb_proc, kb_reader, f"screenshot {capture_dir / '04-keyboard-focus-space.png'}")
        print("[11] Keyboard Space (focus preserved) -> client inspect counter.value:", kb3["elements"][0]["text"])

        send_control(kb_proc, kb_reader, "quit")
        kb_proc.wait(timeout=5)
        assert kb_proc.returncode == 0 and not sock.exists()
        kb_proc = None
        print("[12] Keyboard focus path clean shutdown & socket cleanup verified.")
        return 0
    finally:
        stop_process(kb_proc)
        stop_process(win_proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
