#!/usr/bin/env python3
"""Acceptance test for Dagda's native counter app (`examples/counter`).

Launches the real SDL3 counter window at 0 with `--socket` and `--control-stdin`,
discovers the label and button from a separate `dagda-client` process, clicks
inside the discovered button bounds through SDL's event queue (`SDL_PushEvent`
MOUSE_BUTTON_DOWN + MOUSE_BUTTON_UP), invokes `activate` through `dagda-client`
by discovered ID, and retains real-window PNG captures.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
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
    assert line, f"empty stdout from dagda-client {args}: stderr={proc.stderr!r}"
    return proc.returncode, json.loads(line)


def send_control(win_proc: subprocess.Popen, cmd: str) -> str:
    assert win_proc.stdin is not None and win_proc.stdout is not None
    win_proc.stdin.write(cmd + "\n")
    win_proc.stdin.flush()
    resp = win_proc.stdout.readline().strip()
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


def main() -> int:
    capture_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build" / "counter-capture"
    capture_dir.mkdir(parents=True, exist_ok=True)

    build_dir = ROOT / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    counter_bin = build_dir / "counter"
    client_bin = build_dir / "dagda-client"

    subprocess.check_call([str(ODIN), "build", "examples/counter", "-collection:dagda=.", f"-out:{counter_bin}"], cwd=ROOT)
    subprocess.check_call([str(ODIN), "build", "examples/dagda-client", "-collection:dagda=.", f"-out:{client_bin}"], cwd=ROOT)

    sock_dir = Path(tempfile.mkdtemp(prefix="dagda-counter."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "counter.sock"
    win_proc = None

    try:
        win_proc = subprocess.Popen(
            [str(counter_bin), "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=ROOT,
        )
        assert win_proc.stdout is not None
        ready = win_proc.stdout.readline().strip()
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
        print("[4] Inject SDL mouse click:", send_control(win_proc, f"click {cx:.2f} {cy:.2f}"))
        val1 = wait_for_counter_value(client_bin, sock, "1")
        send_control(win_proc, f"screenshot {capture_dir / '01-after-sdl-click.png'}")
        print("[5] After SDL click, client inspect counter.value:", val1["elements"][0]["text"])

        # Invoke activate through dagda-client using the discovered button ID.
        code, inv = run_client(client_bin, sock, "invoke", str(btn_id), "activate")
        assert code == 0 and inv == {"ok": True, "id": btn_id, "action": "activate"}, (code, inv)
        val2 = wait_for_counter_value(client_bin, sock, "2")
        send_control(win_proc, f"screenshot {capture_dir / '02-after-client-invoke.png'}")
        print("[6] After client invoke, client inspect counter.value:", val2["elements"][0]["text"])

        # Out-of-bounds click and unsupported action on label leave count at 2.
        send_control(win_proc, "click 2.00 2.00")
        code, bad_act = run_client(client_bin, sock, "invoke", str(label["id"]), "activate")
        assert code == 1 and bad_act == {"ok": False, "error": "Unsupported_Action"}, (code, bad_act)
        val_still2 = wait_for_counter_value(client_bin, sock, "2")
        assert val_still2["elements"][0]["text"] == "2", val_still2
        print("[7] Out-of-bounds click & unsupported label action left count at 2.")

        send_control(win_proc, "quit")
        win_proc.wait(timeout=5)
        assert win_proc.returncode == 0 and not sock.exists()
        print("[8] Clean shutdown & socket cleanup verified.")
        return 0
    finally:
        if win_proc is not None and win_proc.poll() is None:
            win_proc.terminate()
            win_proc.wait(timeout=5)
        shutil.rmtree(sock_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
