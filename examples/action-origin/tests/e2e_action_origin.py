#!/usr/bin/env python3
"""End-to-end test proving sdlhost.current_action_origin() distinguishes local
pointer/keyboard activation from external driver invoke through one Add button.
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


class DeadlineLineReader:
    def __init__(self, stream) -> None:
        self.fd = stream.fileno()
        self.buf = bytearray()

    def read_line(self, stage: str, timeout: float = 5.0) -> str:
        deadline = time.monotonic() + timeout
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                raw = bytes(self.buf[:nl])
                del self.buf[: nl + 1]
                return raw.decode("utf-8").rstrip("\r")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"timed out after {timeout:.2f}s during {stage} (partial={bytes(self.buf)!r})")
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                continue
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise AssertionError(f"unexpected EOF during {stage} (partial={bytes(self.buf)!r})")
            self.buf.extend(chunk)


def stop_process(proc: subprocess.Popen | None) -> None:
    if proc is None:
        return
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
    for stream in (proc.stdin, proc.stdout, proc.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass


def run_client(client_bin: Path, sock: Path, *args: str) -> tuple[int, dict]:
    proc = subprocess.run([str(client_bin), str(sock), *args], capture_output=True, text=True, timeout=10)
    line = proc.stdout.strip()
    assert line, f"empty stdout from dagda-client {args}: stderr={proc.stderr!r}"
    return proc.returncode, json.loads(line)


def send_control(win_proc: subprocess.Popen, reader: DeadlineLineReader, cmd: str) -> str:
    assert win_proc.stdin is not None
    win_proc.stdin.write((cmd + "\n").encode("utf-8"))
    win_proc.stdin.flush()
    resp = reader.read_line(f"control {cmd!r}", timeout=5.0)
    assert resp.startswith("CONTROL_OK"), f"control {cmd!r} failed: {resp!r}"
    return resp


def wait_for_role_text(client_bin: Path, sock: Path, role: str, expected: str, timeout: float = 3.0) -> dict:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        code, resp = run_client(client_bin, sock, "inspect", role)
        last = (code, resp)
        if code == 0 and resp.get("ok") is True and resp["elements"][0]["text"] == expected:
            return resp
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {role} == {expected!r}; last={last}")


def run_mode(app_bin: Path, client_bin: Path, with_edits: bool, treat_driver_as_local: bool) -> None:
    mode_name = "edits" if with_edits else "plain"
    sock_dir = Path(tempfile.mkdtemp(prefix=f"dagda-action-origin-{mode_name}."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "origin.sock"
    proc = None
    try:
        cmd = [str(app_bin), "--size", "800x540", "--socket", str(sock), "--control-stdin"]
        if with_edits:
            cmd.append("--with-edits")
        if treat_driver_as_local:
            cmd.append("--treat-driver-as-local")
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
        )
        assert proc.stdout is not None
        reader = DeadlineLineReader(proc.stdout)
        ready = reader.read_line(f"action-origin ({mode_name}) startup", timeout=5.0)
        assert ready == f"Listening {sock}", f"unexpected startup: {ready!r}"

        # Discover editable current item and Add button.
        c_cur, r_cur = run_client(client_bin, sock, "inspect", "item.current")
        c_add, r_add = run_client(client_bin, sock, "inspect", "item.add")
        assert c_cur == 0 and c_add == 0
        cur_el = r_cur["elements"][0]
        add_el = r_add["elements"][0]
        assert cur_el["text"] == "abcd"
        add_id = add_el["id"]
        b_cur = cur_el["bounds"]
        b_add = add_el["bounds"]

        # 1. Driver path: focus editable title, put collapsed caret between 'b' and 'c' in "abcd",
        #    invoke Add via separate dagda-client process.
        send_control(proc, reader, f"click {b_cur['x'] + b_cur['width'] - 10.0:.2f} {b_cur['y'] + b_cur['height'] * 0.5:.2f}")
        send_control(proc, reader, "key left")
        send_control(proc, reader, "key left")

        c_inv, r_inv = run_client(client_bin, sock, "invoke", str(add_id), "activate")
        assert c_inv == 0 and r_inv.get("ok") is True, (c_inv, r_inv)
        wait_for_role_text(
            client_bin, sock, "origin.status",
            "count=2 selected=0 last_origin=Driver local=0 driver=1 frame_origin=None",
        )
        wait_for_role_text(client_bin, sock, "item.current", "abcd")
        wait_for_role_text(client_bin, sock, "item.1", "Item 2")

        # Without clicking or tabbing again, type "X": original item becomes "abXcd", appended stays "Item 2".
        send_control(proc, reader, "text X")
        wait_for_role_text(client_bin, sock, "item.current", "abXcd")
        wait_for_role_text(client_bin, sock, "item.0", "abXcd")
        wait_for_role_text(client_bin, sock, "item.1", "Item 2")

        # 2. Local pointer path: click the same Add button -> appends & selects newly added item 2.
        send_control(proc, reader, f"click {b_add['x'] + b_add['width'] * 0.5:.2f} {b_add['y'] + b_add['height'] * 0.5:.2f}")
        wait_for_role_text(
            client_bin, sock, "origin.status",
            "count=3 selected=2 last_origin=Local local=1 driver=1 frame_origin=None",
        )
        wait_for_role_text(client_bin, sock, "item.current", "Item 3")
        wait_for_role_text(client_bin, sock, "item.2", "Item 3")

        # 3. Local keyboard activation paths (Tab -> Enter, then Space) & normal Tab wrap back to field.
        send_control(proc, reader, f"click {b_cur['x'] + 4.0:.2f} {b_cur['y'] + b_cur['height'] * 0.5:.2f}")
        send_control(proc, reader, "key tab")
        send_control(proc, reader, "key enter")
        wait_for_role_text(
            client_bin, sock, "origin.status",
            "count=4 selected=3 last_origin=Local local=2 driver=1 frame_origin=None",
        )
        wait_for_role_text(client_bin, sock, "item.current", "Item 4")

        send_control(proc, reader, "key space")
        wait_for_role_text(
            client_bin, sock, "origin.status",
            "count=5 selected=4 last_origin=Local local=3 driver=1 frame_origin=None",
        )
        wait_for_role_text(client_bin, sock, "item.current", "Item 5")

        # Normal keyboard focus traversal wraps back to editable current item.
        send_control(proc, reader, "key tab")
        send_control(proc, reader, "text !")
        wait_for_role_text(client_bin, sock, "item.current", "Item 5!")

        print(
            f"[action-origin:{mode_name}] driver(add_id={add_id} -> count=2,sel=0,origin=Driver,type 'X'->'abXcd',item1='Item 2') -> "
            "local_click(count=3,sel=2,origin=Local) -> local_enter(count=4,sel=3,origin=Local) -> "
            "local_space(count=5,sel=4,origin=Local) -> tab_wrap('Item 5!')"
        )

        send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        assert proc.returncode == 0 and not sock.exists()
        proc = None
    finally:
        stop_process(proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


def main() -> int:
    treat_driver_as_local = "--treat-driver-as-local" in sys.argv[1:]
    build_dir = ROOT / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    app_bin = build_dir / "action-origin"
    client_bin = build_dir / "dagda-client"

    subprocess.check_call([str(ODIN), "build", "examples/action-origin", "-collection:dagda=.", f"-out:{app_bin}"], cwd=ROOT)
    subprocess.check_call([str(ODIN), "build", "examples/dagda-client", "-collection:dagda=.", f"-out:{client_bin}"], cwd=ROOT)

    for with_edits in (False, True):
        run_mode(app_bin, client_bin, with_edits, treat_driver_as_local)
    print("All action-origin checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
