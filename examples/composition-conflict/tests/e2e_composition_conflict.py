#!/usr/bin/env python3
"""Process test for cross-field IME composition conflict detection (Busy_Composing).

Title A has two distinct visual fields: a.outline (id=0) and a.canvas (id=1).
Title B is an independently editable field: b.canvas (id=2).

Sequence under active visible preedit in A's canvas headline:
1. Preview through A's outline row succeeds and preserves the preedit.
2. Stale commit through A's outline row returns Stale_Revision with current revision.
3. Current-revision commit through A's outline row returns Busy_Composing; committed
   text, revision, undo depth, selection, and visible preedit all survive.
4. Current-revision edit to B succeeds while A is still composing; finishing A's
   composition then commits the person's intended text exactly once.
5. Re-read A's revision and retry the agent rename of A -> succeeds.
"""

import json
import math
import os
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ODIN = ROOT / "scripts" / "odin.sh"

CARET_AMBER_RGB = (255, 206, 84)
PREEDIT_BG_RGB = (62, 78, 118)
SEL_BG_RGB = (58, 108, 190)


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
                raise TimeoutError(
                    f"timed out after {timeout:.2f}s waiting for complete line during {stage} "
                    f"(partial={bytes(self.buf)!r})"
                )
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


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def decode_png_rgb(path: Path) -> tuple[int, int, bytearray]:
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"invalid PNG signature in {path}"
    pos = 8
    w = h = bit_depth = color_type = 0
    idat = bytearray()
    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            w, h, bit_depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", chunk)
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break
    assert bit_depth == 8 and color_type in (2, 6), (bit_depth, color_type)
    bpp = 3 if color_type == 2 else 4
    raw = zlib.decompress(bytes(idat))
    stride = w * bpp
    recon = bytearray(h * stride)
    for y in range(h):
        ftype = raw[y * (stride + 1)]
        row_in = raw[y * (stride + 1) + 1 : (y + 1) * (stride + 1)]
        row_out = y * stride
        prev_out = (y - 1) * stride
        for i in range(stride):
            x = row_in[i]
            a = recon[row_out + i - bpp] if i >= bpp else 0
            b = recon[prev_out + i] if y > 0 else 0
            c = recon[prev_out + i - bpp] if (y > 0 and i >= bpp) else 0
            if ftype == 0:
                v = x
            elif ftype == 1:
                v = (x + a) & 0xFF
            elif ftype == 2:
                v = (x + b) & 0xFF
            elif ftype == 3:
                v = (x + ((a + b) >> 1)) & 0xFF
            elif ftype == 4:
                v = (x + paeth(a, b, c)) & 0xFF
            else:
                raise AssertionError(f"unsupported PNG filter {ftype}")
            recon[row_out + i] = v
    rgb = bytearray(w * h * 3)
    if bpp == 3:
        rgb[:] = recon
    else:
        for i in range(w * h):
            rgb[i * 3 : i * 3 + 3] = recon[i * 4 : i * 4 + 3]
    return w, h, rgb


def rgb_close(p: tuple[int, int, int], target: tuple[int, int, int], tol: int = 8) -> bool:
    return abs(p[0] - target[0]) <= tol and abs(p[1] - target[1]) <= tol and abs(p[2] - target[2]) <= tol


def inspect_visual_state(w: int, h: int, rgb: bytearray, bounds: dict) -> tuple[int, int, int]:
    x0 = max(0, int(math.floor(bounds["x"])))
    y0 = max(0, int(math.floor(bounds["y"])))
    x1 = min(w, int(math.ceil(bounds["x"] + bounds["width"])))
    y1 = min(h, int(math.ceil(bounds["y"] + bounds["height"])))
    preedit_bg_hits = 0
    sel_bg_hits = 0
    max_amber_row_width = 0
    for y in range(y0, y1):
        row_off = y * w * 3
        row_amber = 0
        for x in range(x0, x1):
            px = (rgb[row_off + x * 3], rgb[row_off + x * 3 + 1], rgb[row_off + x * 3 + 2])
            if rgb_close(px, PREEDIT_BG_RGB):
                preedit_bg_hits += 1
            elif rgb_close(px, SEL_BG_RGB):
                sel_bg_hits += 1
            elif rgb_close(px, CARET_AMBER_RGB):
                row_amber += 1
        if row_amber > max_amber_row_width:
            max_amber_row_width = row_amber
    return preedit_bg_hits, sel_bg_hits, max_amber_row_width


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


def assert_a_canvas_composing(
    proc: subprocess.Popen,
    reader: DeadlineLineReader,
    client_bin: Path,
    sock: Path,
    png_path: Path,
    timeout: float = 2.0,
) -> tuple[int, int, int, int]:
    deadline = time.monotonic() + timeout
    while True:
        send_control(proc, reader, f"screenshot {png_path}")
        code, resp = run_client(client_bin, sock, "inspect", "a.canvas")
        assert code == 0 and resp.get("ok") is True, (code, resp)
        b = resp["elements"][0]["bounds"]
        w, h, rgb = decode_png_rgb(png_path)
        pre_bg, sel_bg, amber_w = inspect_visual_state(w, h, rgb, b)
        if pre_bg >= 50 and amber_w >= 6 and sel_bg == 0:
            return w, h, pre_bg, amber_w
        if time.monotonic() >= deadline:
            raise AssertionError(
                f"a.canvas not visibly composing in {png_path}: "
                f"preedit_bg={pre_bg}, amber_w={amber_w}, sel_bg={sel_bg}"
            )
        time.sleep(0.02)


def main() -> int:
    args = sys.argv[1:]
    disable_check = False
    if "--disable-conflict-check" in args:
        disable_check = True
        args = [a for a in args if a != "--disable-conflict-check"]

    capture_dir = Path(args[0]) if len(args) > 0 else ROOT / "build" / "conflict-capture"
    capture_dir.mkdir(parents=True, exist_ok=True)

    build_dir = ROOT / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    app_bin = build_dir / "composition-conflict"
    client_bin = build_dir / "dagda-client"

    subprocess.check_call(
        [str(ODIN), "build", "examples/composition-conflict", "-collection:dagda=.", f"-out:{app_bin}"],
        cwd=ROOT,
    )
    subprocess.check_call(
        [str(ODIN), "build", "examples/dagda-client", "-collection:dagda=.", f"-out:{client_bin}"],
        cwd=ROOT,
    )

    sock_dir = Path(tempfile.mkdtemp(prefix="dagda-conflict."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "conflict.sock"
    proc = None
    try:
        cmd = [str(app_bin), "--size", "960x540", "--socket", str(sock), "--control-stdin"]
        if disable_check:
            cmd.append("--disable-conflict-check")
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
        ready = reader.read_line("composition-conflict startup", timeout=5.0)
        assert ready == f"Listening {sock}", f"unexpected startup: {ready!r}"

        # Settle initial window map, then discover A's outline row (id=0), A's canvas headline (id=1), and B (id=2).
        send_control(proc, reader, f"screenshot {capture_dir / '00-init.png'}")
        code_ao, ao_resp = run_client(client_bin, sock, "inspect", "a.outline")
        code_ac, ac_resp = run_client(client_bin, sock, "inspect", "a.canvas")
        code_bc, bc_resp = run_client(client_bin, sock, "inspect", "b.canvas")
        assert code_ao == 0 and code_ac == 0 and code_bc == 0
        a_out_id = ao_resp["elements"][0]["id"]
        a_can_id = ac_resp["elements"][0]["id"]
        b_can_id = bc_resp["elements"][0]["id"]
        assert a_out_id == 0 and a_can_id == 1 and b_can_id == 2
        ac_bounds = ac_resp["elements"][0]["bounds"]

        # Start visible preedit "e" over selected "Title" in A's canvas headline (id=1).
        cy = ac_bounds["y"] + ac_bounds["height"] * 0.5
        send_control(proc, reader, f"click {ac_bounds['x'] + ac_bounds['width'] - 10.0:.2f} {cy:.2f}")
        for _ in range(5):
            send_control(proc, reader, "key shift+left")
        send_control(proc, reader, "preedit e")
        png_w, png_h, pre_bg0, uline0 = assert_a_canvas_composing(
            proc, reader, client_bin, sock, capture_dir / "01-a-preedit.png"
        )

        # Step 1: Preview through A's outline row (id=0) succeeds and preserves preedit.
        c1, r1 = run_client(client_bin, sock, "preview", str(a_out_id), "rename", "1", "text", "Agent Alpha")
        assert c1 == 0 and r1["ok"] is True and r1["id"] == 0 and r1["revision"] == 1, (c1, r1)
        assert_a_canvas_composing(proc, reader, client_bin, sock, capture_dir / "02-after-preview.png")

        # Step 2: Stale commit through A's outline row returns Stale_Revision with current revision (1).
        c2, r2 = run_client(client_bin, sock, "commit", str(a_out_id), "rename", "0", "text", "Agent Alpha")
        assert c2 != 0 and r2 == {"ok": False, "error": "Stale_Revision", "revision": 1}, (c2, r2)

        # Step 3: Current-revision commit through A's outline row returns Busy_Composing;
        # committed text, revision, undo depth, selection, and visible preedit all survive.
        c3, r3 = run_client(client_bin, sock, "commit", str(a_out_id), "rename", "1", "text", "Agent Alpha")
        assert c3 != 0 and r3 == {"ok": False, "error": "Busy_Composing"}, (c3, r3)
        wait_for_role_text(client_bin, sock, "a.outline", "Alpha Title")
        wait_for_role_text(client_bin, sock, "a.canvas", "Alpha Title")
        wait_for_role_text(client_bin, sock, "conflict.status", "a_rev=1, a_undo=0, b_rev=1, b_undo=0")
        assert_a_canvas_composing(proc, reader, client_bin, sock, capture_dir / "03-after-busy.png")

        # Step 4: Current-revision edit to B (id=2) succeeds while A is still composing.
        c4, r4 = run_client(client_bin, sock, "commit", str(b_can_id), "rename", "1", "text", "Agent Beta")
        assert c4 == 0 and r4 == {"ok": True, "id": 2, "edit": "rename", "revision": 2}, (c4, r4)
        wait_for_role_text(client_bin, sock, "b.canvas", "Agent Beta")
        wait_for_role_text(client_bin, sock, "conflict.status", "a_rev=1, a_undo=0, b_rev=2, b_undo=1")
        assert_a_canvas_composing(proc, reader, client_bin, sock, capture_dir / "04-after-b-edit.png")

        # Finishing A's composition then commits the person's intended text ("Alpha é") exactly once
        # (proving A's selection of "Title" also survived steps 1-4!).
        send_control(proc, reader, "key enter")
        send_control(proc, reader, "text é")
        wait_for_role_text(client_bin, sock, "a.outline", "Alpha é")
        wait_for_role_text(client_bin, sock, "a.canvas", "Alpha é")
        wait_for_role_text(client_bin, sock, "conflict.status", "a_rev=2, a_undo=1, b_rev=2, b_undo=1")

        # Step 5: Re-read A's revision and retry the agent rename of A -> now succeeds.
        c5_ed, r5_ed = run_client(client_bin, sock, "edits", str(a_out_id))
        assert c5_ed == 0 and r5_ed["ok"] is True and r5_ed["revision"] == 2, (c5_ed, r5_ed)
        c5, r5 = run_client(
            client_bin, sock, "commit", str(a_out_id), "rename", str(r5_ed["revision"]), "text", "Agent Alpha"
        )
        assert c5 == 0 and r5 == {"ok": True, "id": 0, "edit": "rename", "revision": 3}, (c5, r5)
        wait_for_role_text(client_bin, sock, "a.outline", "Agent Alpha")
        wait_for_role_text(client_bin, sock, "a.canvas", "Agent Alpha")
        wait_for_role_text(client_bin, sock, "conflict.status", "a_rev=3, a_undo=2, b_rev=2, b_undo=1")

        # Step 6: Newline rename "A\nB" is rejected with text, revision, and undo depth intact;
        # subsequent keyboard "Q" commits once.
        c6, r6 = run_client(client_bin, sock, "commit", str(a_out_id), "rename", "3", "text", "A\nB")
        assert c6 != 0 and r6 == {"ok": False, "error": "Not_Handled"}, (c6, r6)
        wait_for_role_text(client_bin, sock, "a.outline", "Agent Alpha")
        wait_for_role_text(client_bin, sock, "a.canvas", "Agent Alpha")
        wait_for_role_text(client_bin, sock, "conflict.status", "a_rev=3, a_undo=2, b_rev=2, b_undo=1")

        send_control(proc, reader, "key end")
        send_control(proc, reader, "text Q")
        wait_for_role_text(client_bin, sock, "a.outline", "Agent AlphaQ")
        wait_for_role_text(client_bin, sock, "a.canvas", "Agent AlphaQ")
        wait_for_role_text(client_bin, sock, "conflict.status", "a_rev=4, a_undo=3, b_rev=2, b_undo=1")

        print(
            f"[conflict] requested=960x540 captured={png_w}x{png_h} preedit=(bg={pre_bg0},uline_w={uline0}):\n"
            f"  step1 preview:  {json.dumps(r1)}\n"
            f"  step2 stale:    {json.dumps(r2)}\n"
            f"  step3 busy:     {json.dumps(r3)}\n"
            f"  step4 b_edit:   {json.dumps(r4)} -> a_finish='Alpha é' (a_rev=2,a_undo=1)\n"
            f"  step5 retry:    {json.dumps(r5)} -> 'Agent Alpha' (a_rev=3,a_undo=2)\n"
            f"  step6 newline:  {json.dumps(r6)} -> key 'Q' -> 'Agent AlphaQ' (a_rev=4,a_undo=3)"
        )

        send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        assert proc.returncode == 0 and not sock.exists()
        proc = None
        print("All composition-conflict checks passed.")
        return 0
    finally:
        stop_process(proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
