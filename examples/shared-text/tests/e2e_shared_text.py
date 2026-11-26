#!/usr/bin/env python3
"""End-to-end test for two distinct single-line elements editing one shared string."""

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


def rect_crop_bytes(w: int, h: int, rgb: bytearray, bounds: dict) -> bytes:
    x0 = max(0, int(math.floor(bounds["x"])))
    y0 = max(0, int(math.floor(bounds["y"])))
    x1 = min(w, int(math.ceil(bounds["x"] + bounds["width"])))
    y1 = min(h, int(math.ceil(bounds["y"] + bounds["height"])))
    out = bytearray()
    for y in range(y0, y1):
        off = y * w * 3
        out.extend(rgb[off + x0 * 3 : off + x1 * 3])
    return bytes(out)


def glyph_mask(w: int, h: int, rgb: bytearray, bounds: dict) -> tuple[frozenset[tuple[int, int]], int]:
    """Extract relative (dx, dy) coordinates of rendered white/light text glyph pixels
    inside bounds (inset by 4px to exclude focus borders and excluding amber caret pixels).
    Returns (mask_set, max_dx).
    """
    x0 = max(0, int(math.floor(bounds["x"])) + 4)
    y0 = max(0, int(math.floor(bounds["y"])) + 4)
    x1 = min(w, int(math.ceil(bounds["x"] + bounds["width"])) - 4)
    y1 = min(h, int(math.ceil(bounds["y"] + bounds["height"])) - 4)
    pts: set[tuple[int, int]] = set()
    max_dx = -1
    for y in range(y0, y1):
        row_off = y * w * 3
        dy = y - y0
        for x in range(x0, x1):
            r, g, b = rgb[row_off + x * 3], rgb[row_off + x * 3 + 1], rgb[row_off + x * 3 + 2]
            # Text glyphs are near-white RGB(240,244,250) (high r,g,b; b >= 160 excludes amber caret RGB(255,206,84)).
            if r >= 160 and g >= 160 and b >= 160:
                dx = x - x0
                pts.add((dx, dy))
                if dx > max_dx:
                    max_dx = dx
    return frozenset(pts), max_dx


def glyph_x_span(w: int, h: int, rgb: bytearray, bounds: dict) -> tuple[float, float]:
    """Return (min_x, max_x) window-pixel X coordinates of rendered white text glyphs inside bounds."""
    x0 = max(0, int(math.floor(bounds["x"])) + 4)
    y0 = max(0, int(math.floor(bounds["y"])) + 4)
    x1 = min(w, int(math.ceil(bounds["x"] + bounds["width"])) - 4)
    y1 = min(h, int(math.ceil(bounds["y"] + bounds["height"])) - 4)
    min_x = x1
    max_x = -1
    for y in range(y0, y1):
        row_off = y * w * 3
        for x in range(x0, x1):
            r, g, b = rgb[row_off + x * 3], rgb[row_off + x * 3 + 1], rgb[row_off + x * 3 + 2]
            if r >= 160 and g >= 160 and b >= 160:
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
    assert max_x > min_x, f"no glyphs found inside {bounds}"
    return float(min_x), float(max_x + 1)


def inspect_visual_state(w: int, h: int, rgb: bytearray, bounds: dict) -> tuple[int, int, int]:
    """Return (preedit_bg_hits, sel_bg_hits, max_amber_row_width) inside bounds."""
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


def main() -> int:
    capture_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build" / "shared-text-capture"
    capture_dir.mkdir(parents=True, exist_ok=True)

    build_dir = ROOT / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    app_bin = build_dir / "shared-text"
    client_bin = build_dir / "dagda-client"

    subprocess.check_call([str(ODIN), "build", "examples/shared-text", "-collection:dagda=.", f"-out:{app_bin}"], cwd=ROOT)
    subprocess.check_call([str(ODIN), "build", "examples/dagda-client", "-collection:dagda=.", f"-out:{client_bin}"], cwd=ROOT)

    sock_dir = Path(tempfile.mkdtemp(prefix="dagda-shared-text."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "shared.sock"
    proc = None
    try:
        proc = subprocess.Popen(
            [str(app_bin), "--size", "800x540", "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
        )
        assert proc.stdout is not None
        reader = DeadlineLineReader(proc.stdout)
        ready = reader.read_line("shared-text startup", timeout=5.0)
        assert ready == f"Listening {sock}", f"unexpected startup: {ready!r}"

        # Initial capture to let any compositor map/resize settle.
        init_png = capture_dir / "00-init.png"
        send_control(proc, reader, f"screenshot {init_png}")
        png_w, png_h, rgb0 = decode_png_rgb(init_png)

        code1, el1_resp = run_client(client_bin, sock, "inspect", "outline.title")
        code2, el2_resp = run_client(client_bin, sock, "inspect", "canvas.title")
        assert code1 == 0 and code2 == 0
        el1 = el1_resp["elements"][0]
        el2 = el2_resp["elements"][0]
        assert el1["id"] == 1 and el2["id"] == 2 and el1["text"] == "Slide Title" and el2["text"] == "Slide Title"
        b1, b2 = el1["bounds"], el2["bounds"]
        el1_before = rect_crop_bytes(png_w, png_h, rgb0, b1)
        el2_before = rect_crop_bytes(png_w, png_h, rgb0, b2)

        # 1. Click inside first element (before text origin -> grapheme boundary 0) and insert "A".
        y1 = b1["y"] + b1["height"] * 0.5
        send_control(proc, reader, f"click {b1['x'] + 2.0:.2f} {y1:.2f}")
        send_control(proc, reader, "text A")
        wait_for_role_text(client_bin, sock, "outline.title", "ASlide Title")
        wait_for_role_text(client_bin, sock, "canvas.title", "ASlide Title")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=1, undo=1, last_id=1, actions=0")

        # Verify BOTH elements redrew visually with the edit ("ASlide Title") and record glyph masks.
        after_first_png = capture_dir / "01-after-first-edit.png"
        send_control(proc, reader, f"screenshot {after_first_png}")
        w1, h1, rgb1 = decode_png_rgb(after_first_png)
        assert (w1, h1) == (png_w, png_h)
        assert rect_crop_bytes(w1, h1, rgb1, b1) != el1_before, "outline.title did not redraw"
        assert rect_crop_bytes(w1, h1, rgb1, b2) != el2_before, "canvas.title did not redraw"
        g1_v1, g1_v1_max = glyph_mask(w1, h1, rgb1, b1)
        g2_v1, g2_v1_max = glyph_mask(w1, h1, rgb1, b2)
        assert len(g1_v1) > 100 and len(g2_v1) > 100, (len(g1_v1), len(g2_v1))
        assert abs(g1_v1_max - g2_v1_max) <= 2, (g1_v1_max, g2_v1_max)

        # 2. Re-inspect settled bounds, click at a different position in element 2 (near end),
        # select "Title", start preedit "e".
        code1, el1_resp = run_client(client_bin, sock, "inspect", "outline.title")
        code2, el2_resp = run_client(client_bin, sock, "inspect", "canvas.title")
        assert code1 == 0 and code2 == 0
        b1, b2 = el1_resp["elements"][0]["bounds"], el2_resp["elements"][0]["bounds"]
        y2 = b2["y"] + b2["height"] * 0.5
        send_control(proc, reader, f"click {b2['x'] + b2['width'] - 10.0:.2f} {y2:.2f}")
        for _ in range(5):
            send_control(proc, reader, "key shift+left")
        send_control(proc, reader, "preedit e")

        preedit_png = capture_dir / "02-second-preedit.png"
        deadline = time.monotonic() + 2.0
        pre2_bg = uline2_w = 0
        while True:
            send_control(proc, reader, f"screenshot {preedit_png}")
            wp, hp, rgbp = decode_png_rgb(preedit_png)
            pre1_bg, sel1_bg, amber1_w = inspect_visual_state(wp, hp, rgbp, b1)
            pre2_bg, sel2_bg, amber2_w = inspect_visual_state(wp, hp, rgbp, b2)
            if (
                pre2_bg >= 50
                and amber2_w >= 6
                and sel2_bg == 0
                and pre1_bg == 0
                and sel1_bg == 0
                and amber1_w == 0
            ):
                uline2_w = amber2_w
                break
            if time.monotonic() >= deadline:
                raise AssertionError(
                    f"preedit isolation check failed in {preedit_png}: "
                    f"el1=(pre={pre1_bg},sel={sel1_bg},amber_w={amber1_w}) "
                    f"el2=(pre={pre2_bg},sel={sel2_bg},amber_w={amber2_w})"
                )
            time.sleep(0.02)

        # Revision and committed text are still untouched during preedit.
        wait_for_role_text(client_bin, sock, "outline.title", "ASlide Title")
        wait_for_role_text(client_bin, sock, "canvas.title", "ASlide Title")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=1, undo=1, last_id=1, actions=0")

        # 3. Commit once (Enter swallowed + TEXT_INPUT "é") -> both elements show "ASlide é", last_id=2.
        send_control(proc, reader, "key enter")
        send_control(proc, reader, "text é")
        wait_for_role_text(client_bin, sock, "outline.title", "ASlide é")
        wait_for_role_text(client_bin, sock, "canvas.title", "ASlide é")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=2, undo=2, last_id=2, actions=0")

        # Verify BOTH fields actually painted the shorter "ASlide é" glyphs (not stale "ASlide Title").
        after_commit_png = capture_dir / "03-after-commit.png"
        deadline = time.monotonic() + 2.0
        g1_v2_max = g2_v2_max = 0
        while True:
            send_control(proc, reader, f"screenshot {after_commit_png}")
            wc, hc, rgbc = decode_png_rgb(after_commit_png)
            g1_v2, g1_v2_max = glyph_mask(wc, hc, rgbc, b1)
            g2_v2, g2_v2_max = glyph_mask(wc, hc, rgbc, b2)
            if (
                g1_v2 != g1_v1
                and g2_v2 != g2_v1
                and g1_v2_max < g1_v1_max - 15
                and g2_v2_max < g2_v1_max - 15
                and abs(g1_v2_max - g2_v2_max) <= 2
            ):
                break
            if time.monotonic() >= deadline:
                raise AssertionError(
                    f"painted title glyphs did not update to 'ASlide é' in {after_commit_png}: "
                    f"el1_max=({g1_v1_max}->{g1_v2_max}), el2_max=({g2_v1_max}->{g2_v2_max})"
                )
            time.sleep(0.02)

        # 4. Undo once (Ctrl+Z) -> both elements restore "ASlide Title", rev=3, undo=1, last_id=2.
        send_control(proc, reader, "key ctrl+z")
        wait_for_role_text(client_bin, sock, "outline.title", "ASlide Title")
        wait_for_role_text(client_bin, sock, "canvas.title", "ASlide Title")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=3, undo=1, last_id=2, actions=0")

        # Verify BOTH fields repainted the restored "ASlide Title" glyphs matching 01-after-first-edit.
        after_undo_png = capture_dir / "04-after-undo.png"
        deadline = time.monotonic() + 2.0
        g1_u_max = g2_u_max = 0
        while True:
            send_control(proc, reader, f"screenshot {after_undo_png}")
            wu, hu, rgbu = decode_png_rgb(after_undo_png)
            g1_u, g1_u_max = glyph_mask(wu, hu, rgbu, b1)
            g2_u, g2_u_max = glyph_mask(wu, hu, rgbu, b2)
            if (
                abs(g1_u_max - g1_v1_max) <= 2
                and abs(g2_u_max - g2_v1_max) <= 2
                and g1_u_max > g1_v2_max + 15
                and g2_u_max > g2_v2_max + 15
            ):
                break
            if time.monotonic() >= deadline:
                raise AssertionError(
                    f"painted title glyphs did not restore 'ASlide Title' after undo in {after_undo_png}: "
                    f"el1_max=({g1_v2_max}->{g1_u_max}, want ~{g1_v1_max}), "
                    f"el2_max=({g2_v2_max}->{g2_u_max}, want ~{g2_v1_max})"
                )
            time.sleep(0.02)

        print(
            f"[shared-text] requested=800x540 captured={png_w}x{png_h}: "
            f"el1_insert('ASlide Title',rev=1,id=1,glyph_x={g1_v1_max}/{g2_v1_max}) -> "
            f"el2_preedit(bg={pre2_bg},uline_w={uline2_w},el1_isolated=true) -> "
            f"commit('ASlide é',rev=2,id=2,glyph_x={g1_v2_max}/{g2_v2_max}) -> "
            f"undo('ASlide Title',rev=3,undo=1,id=2,glyph_x={g1_u_max}/{g2_u_max})"
        )

        send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        assert proc.returncode == 0 and not sock.exists()
        proc = None

        verify_keyboard_tab_traversal(app_bin, client_bin, capture_dir)
        verify_clipboard_copy_paste(app_bin, client_bin, capture_dir)
        drag_sizes = ("800x540", "640x480") if os.environ.get("SDL_VIDEODRIVER") == "dummy" else ("800x540",)
        for sz in drag_sizes:
            verify_mouse_drag_selection(app_bin, client_bin, capture_dir, sz)
        print("All shared-text checks passed.")
        return 0
    finally:
        stop_process(proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


def verify_keyboard_tab_traversal(app_bin: Path, client_bin: Path, capture_dir: Path) -> None:
    """Keyboard-only traversal with two editable fields, a passive label, and a button
    (starting without any mouse click).
    """
    sock_dir = Path(tempfile.mkdtemp(prefix="dagda-shared-tab."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "shared-tab.sock"
    proc = None
    try:
        proc = subprocess.Popen(
            [str(app_bin), "--size", "800x540", "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
        )
        assert proc.stdout is not None
        reader = DeadlineLineReader(proc.stdout)
        ready = reader.read_line("shared-text tab startup", timeout=5.0)
        assert ready == f"Listening {sock}", f"unexpected startup: {ready!r}"

        # No mouse click: Tab -> field A (id=1), type "A".
        send_control(proc, reader, "key tab")
        send_control(proc, reader, "text A")
        wait_for_role_text(client_bin, sock, "outline.title", "Slide TitleA")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=1, undo=1, last_id=1, actions=0")

        # Tab -> field B (id=2), type "B".
        send_control(proc, reader, "key tab")
        send_control(proc, reader, "text B")
        wait_for_role_text(client_bin, sock, "canvas.title", "Slide TitleAB")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=2, undo=2, last_id=2, actions=0")

        # Tab skips passive status label (id=3) -> button (id=4), Enter activates once.
        send_control(proc, reader, "key tab")
        send_control(proc, reader, "key enter")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=2, undo=2, last_id=2, actions=1")

        # Reverse traversal: Shift+Tab -> field B (id=2) -> type "C", Shift+Tab -> field A (id=1) -> type "D".
        send_control(proc, reader, "key shift+tab")
        send_control(proc, reader, "text C")
        wait_for_role_text(client_bin, sock, "outline.title", "Slide TitleABC")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=3, undo=3, last_id=2, actions=1")

        send_control(proc, reader, "key shift+tab")
        send_control(proc, reader, "text D")
        wait_for_role_text(client_bin, sock, "outline.title", "Slide TitleABCD")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=4, undo=4, last_id=1, actions=1")

        # Shift+Tab wraps backward from field A (id=1) -> button (id=4), Enter activates once.
        send_control(proc, reader, "key shift+tab")
        send_control(proc, reader, "key enter")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=4, undo=4, last_id=1, actions=2")

        # Tab wraps forward to field A (id=1); during preedit, Tab and Shift+Tab leave composition in A.
        send_control(proc, reader, "key tab")
        send_control(proc, reader, "preedit e")
        send_control(proc, reader, "key tab")
        send_control(proc, reader, "key shift+tab")
        wait_for_role_text(client_bin, sock, "outline.title", "Slide TitleABCD")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=4, undo=4, last_id=1, actions=2")

        # Escape cancels preedit -> Tab moves to field B (id=2), text "Z" commits under id=2.
        send_control(proc, reader, "key escape")
        send_control(proc, reader, "key tab")
        send_control(proc, reader, "text Z")
        wait_for_role_text(client_bin, sock, "canvas.title", "Slide TitleABCDZ")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=5, undo=5, last_id=2, actions=2")

        tab_png = capture_dir / "05-tab-traversal-final.png"
        send_control(proc, reader, f"screenshot {tab_png}")
        tw, th, _ = decode_png_rgb(tab_png)
        print(
            f"[shared-tab] requested=800x540 captured={tw}x{th}: "
            f"Tab(A->B->btn:actions=1) -> Shift+Tab(B->A->wrap_btn:actions=2) -> "
            f"preedit_blocks_tab -> Escape+Tab->B('Slide TitleABCDZ',rev=5,id=2)"
        )

        send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        assert proc.returncode == 0 and not sock.exists()
        proc = None
    finally:
        stop_process(proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


def verify_clipboard_copy_paste(app_bin: Path, client_bin: Path, capture_dir: Path) -> None:
    """Two-view plain-text Ctrl+C / Ctrl+V sequence using the isolated host clipboard:
    copy combining sequence, paste over selection in other view, undo once,
    reject multiline paste preserving selection/history, and keep IME preedit intact on Ctrl+V.
    """
    sock_dir = Path(tempfile.mkdtemp(prefix="dagda-shared-clip."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "shared-clip.sock"
    proc = None
    try:
        proc = subprocess.Popen(
            [str(app_bin), "--size", "800x540", "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
        )
        assert proc.stdout is not None
        reader = DeadlineLineReader(proc.stdout)
        ready = reader.read_line("shared-text clip startup", timeout=5.0)
        assert ready == f"Listening {sock}", f"unexpected startup: {ready!r}"

        # Settle initial map and inspect bounds of both views.
        send_control(proc, reader, f"screenshot {capture_dir / '06-clip-init.png'}")
        c1, el1_resp = run_client(client_bin, sock, "inspect", "outline.title")
        c2, el2_resp = run_client(client_bin, sock, "inspect", "canvas.title")
        assert c1 == 0 and c2 == 0
        b1, b2 = el1_resp["elements"][0]["bounds"], el2_resp["elements"][0]["bounds"]

        # 1. Replace title in view 1 (id=1) with combining-character text "Cafe\u0301 Title".
        combining_title = "Cafe\u0301 Title"
        assert combining_title.encode("utf-8") == b"Cafe\xcc\x81 Title"
        y1 = b1["y"] + b1["height"] * 0.5
        send_control(proc, reader, f"click {b1['x'] + 2.0:.2f} {y1:.2f}")
        send_control(proc, reader, "key ctrl+a")
        send_control(proc, reader, f"text {combining_title}")
        wait_for_role_text(client_bin, sock, "outline.title", combining_title)
        wait_for_role_text(client_bin, sock, "canvas.title", combining_title)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=1, undo=1, last_id=1, actions=0")

        # 2. Select "fe\u0301" (2 graphemes, 4 UTF-8 bytes) in view 1 and Ctrl+C -> revision untouched.
        send_control(proc, reader, "key home")
        send_control(proc, reader, "key right")
        send_control(proc, reader, "key right")
        send_control(proc, reader, "key shift+right")
        send_control(proc, reader, "key shift+right")
        send_control(proc, reader, "key ctrl+c")
        wait_for_role_text(client_bin, sock, "outline.title", combining_title)
        wait_for_role_text(client_bin, sock, "canvas.title", combining_title)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=1, undo=1, last_id=1, actions=0")

        # 3. Click view 2 (id=2), select "Title", Ctrl+V -> both views show exact UTF-8 bytes "Cafe\u0301 fe\u0301".
        expected_pasted = "Cafe\u0301 fe\u0301"
        assert expected_pasted.encode("utf-8") == b"Cafe\xcc\x81 fe\xcc\x81"
        y2 = b2["y"] + b2["height"] * 0.5
        send_control(proc, reader, f"click {b2['x'] + b2['width'] - 10.0:.2f} {y2:.2f}")
        for _ in range(5):
            send_control(proc, reader, "key shift+left")
        send_control(proc, reader, "key ctrl+v")
        r_out = wait_for_role_text(client_bin, sock, "outline.title", expected_pasted)
        r_can = wait_for_role_text(client_bin, sock, "canvas.title", expected_pasted)
        assert r_out["elements"][0]["text"].encode("utf-8") == b"Cafe\xcc\x81 fe\xcc\x81"
        assert r_can["elements"][0]["text"].encode("utf-8") == b"Cafe\xcc\x81 fe\xcc\x81"
        wait_for_role_text(client_bin, sock, "shared.status", "rev=2, undo=2, last_id=2, actions=0")

        # 4. One Ctrl+Z restores "Cafe\u0301 Title" in both views.
        send_control(proc, reader, "key ctrl+z")
        wait_for_role_text(client_bin, sock, "outline.title", combining_title)
        wait_for_role_text(client_bin, sock, "canvas.title", combining_title)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=3, undo=1, last_id=2, actions=0")

        # 5. Multiline paste over selected "Title" preserves text, selection, and history.
        send_control(proc, reader, "key end")
        for _ in range(5):
            send_control(proc, reader, "key shift+left")
        send_control(proc, reader, r"clipboard Line1\nLine2")
        send_control(proc, reader, "key ctrl+v")
        wait_for_role_text(client_bin, sock, "outline.title", combining_title)
        wait_for_role_text(client_bin, sock, "canvas.title", combining_title)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=3, undo=1, last_id=2, actions=0")

        # Prove selection ("Title") survived the rejected multiline paste by typing "X" -> replaces "Title".
        send_control(proc, reader, "text X")
        wait_for_role_text(client_bin, sock, "outline.title", "Cafe\u0301 X")
        wait_for_role_text(client_bin, sock, "canvas.title", "Cafe\u0301 X")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=4, undo=2, last_id=2, actions=0")
        send_control(proc, reader, "key ctrl+z")
        wait_for_role_text(client_bin, sock, "outline.title", combining_title)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=5, undo=1, last_id=2, actions=0")

        # 6. During active IME composition in view 2, Ctrl+V leaves preedit intact.
        send_control(proc, reader, "key end")
        send_control(proc, reader, "preedit e")
        send_control(proc, reader, "clipboard PASTE")
        send_control(proc, reader, "key ctrl+v")

        clip_preedit_png = capture_dir / "07-clip-preedit-intact.png"
        deadline = time.monotonic() + 2.0
        pre2_bg = uline2_w = 0
        while True:
            send_control(proc, reader, f"screenshot {clip_preedit_png}")
            wp, hp, rgbp = decode_png_rgb(clip_preedit_png)
            pre1_bg, sel1_bg, amber1_w = inspect_visual_state(wp, hp, rgbp, b1)
            pre2_bg, sel2_bg, amber2_w = inspect_visual_state(wp, hp, rgbp, b2)
            if pre2_bg >= 50 and amber2_w >= 6 and pre1_bg == 0 and amber1_w == 0:
                uline2_w = amber2_w
                break
            if time.monotonic() >= deadline:
                raise AssertionError(
                    f"preedit did not survive Ctrl+V in {clip_preedit_png}: "
                    f"el1=(pre={pre1_bg},sel={sel1_bg},amber_w={amber1_w}) "
                    f"el2=(pre={pre2_bg},sel={sel2_bg},amber_w={amber2_w})"
                )
            time.sleep(0.02)

        wait_for_role_text(client_bin, sock, "outline.title", combining_title)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=5, undo=1, last_id=2, actions=0")

        # Finish composition -> commits once without any pasted text.
        send_control(proc, reader, "key enter")
        send_control(proc, reader, "text é")
        wait_for_role_text(client_bin, sock, "outline.title", f"{combining_title}é")
        wait_for_role_text(client_bin, sock, "canvas.title", f"{combining_title}é")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=6, undo=2, last_id=2, actions=0")

        print(
            f"[shared-clip] copy('fe\\u0301',rev=1) -> paste_v2('Cafe\\u0301 fe\\u0301',rev=2,id=2) -> "
            f"undo('Cafe\\u0301 Title',rev=3) -> multiline_reject(sel_kept->'Cafe\\u0301 X',rev=4->undo rev=5) -> "
            f"preedit_ctrl_v_intact(bg={pre2_bg},uline_w={uline2_w}->'Cafe\\u0301 Titleé',rev=6)"
        )

        send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        assert proc.returncode == 0 and not sock.exists()
        proc = None
    finally:
        stop_process(proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


def verify_mouse_drag_selection(app_bin: Path, client_bin: Path, capture_dir: Path, req_size: str) -> None:
    """Mouse drag selection in both directions across a decomposed é (U+0065 + U+0301):
    copy and verify exact UTF-8 bytes, type over selection, undo once, verify revision
    is unchanged by selection alone, and verify clamping past both ends.
    """
    sock_dir = Path(tempfile.mkdtemp(prefix=f"dagda-shared-drag-{req_size}."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "shared-drag.sock"
    proc = None
    try:
        proc = subprocess.Popen(
            [str(app_bin), "--size", req_size, "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
        )
        assert proc.stdout is not None
        reader = DeadlineLineReader(proc.stdout)
        ready = reader.read_line(f"shared-text drag ({req_size}) startup", timeout=5.0)
        assert ready == f"Listening {sock}", f"unexpected startup: {ready!r}"

        # Settle initial window map, set title to "Ae\u0301B" (decomposed é = U+0065 + U+0301).
        init_png = capture_dir / f"08-drag-{req_size}-init.png"
        send_control(proc, reader, f"screenshot {init_png}")
        c1, el1_resp = run_client(client_bin, sock, "inspect", "outline.title")
        c2, el2_resp = run_client(client_bin, sock, "inspect", "canvas.title")
        assert c1 == 0 and c2 == 0
        b1, b2 = el1_resp["elements"][0]["bounds"], el2_resp["elements"][0]["bounds"]

        decomposed = "Ae\u0301B"
        assert decomposed.encode("utf-8") == b"Ae\xcc\x81B"
        y1 = b1["y"] + b1["height"] * 0.5
        y2 = b2["y"] + b2["height"] * 0.5
        send_control(proc, reader, f"click {b1['x'] + 2.0:.2f} {y1:.2f}")
        send_control(proc, reader, "key ctrl+a")
        send_control(proc, reader, f"text {decomposed}")
        wait_for_role_text(client_bin, sock, "outline.title", decomposed)
        wait_for_role_text(client_bin, sock, "canvas.title", decomposed)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=1, undo=1, last_id=1, actions=0")

        # Click outside to measure unfocused glyph span without caret/selection interference.
        send_control(proc, reader, "click 4.00 4.00")
        span_png = capture_dir / f"09-drag-{req_size}-span.png"
        send_control(proc, reader, f"screenshot {span_png}")
        png_w, png_h, rgb = decode_png_rgb(span_png)
        g_min_x, g_max_x = glyph_x_span(png_w, png_h, rgb, b1)
        span = g_max_x - g_min_x
        x_before_e = g_min_x + span * 0.35
        x_after_e = g_min_x + span * 0.65

        # 1. Left-to-right drag across decomposed é -> selection alone leaves revision unchanged.
        send_control(proc, reader, f"down {x_before_e:.2f} {y1:.2f}")
        send_control(proc, reader, f"move {x_after_e:.2f} {y1:.2f}")
        send_control(proc, reader, f"up {x_after_e:.2f} {y1:.2f}")
        wait_for_role_text(client_bin, sock, "outline.title", decomposed)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=1, undo=1, last_id=1, actions=0")

        # Copy LTR selection, paste at end of view 2 to verify exact bytes b"e\xcc\x81".
        send_control(proc, reader, "key ctrl+c")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=1, undo=1, last_id=1, actions=0")
        send_control(proc, reader, f"click {b2['x'] + b2['width'] - 10.0:.2f} {y2:.2f}")
        send_control(proc, reader, "key ctrl+v")
        r_ltr = wait_for_role_text(client_bin, sock, "outline.title", "Ae\u0301Be\u0301")
        assert r_ltr["elements"][0]["text"].encode("utf-8") == b"Ae\xcc\x81Be\xcc\x81"
        wait_for_role_text(client_bin, sock, "shared.status", "rev=2, undo=2, last_id=2, actions=0")
        send_control(proc, reader, "key ctrl+z")
        wait_for_role_text(client_bin, sock, "outline.title", decomposed)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=3, undo=1, last_id=2, actions=0")

        # 2. Right-to-left drag across decomposed é -> copy, type over it, and undo once.
        send_control(proc, reader, f"down {x_after_e:.2f} {y1:.2f}")
        send_control(proc, reader, f"move {x_before_e:.2f} {y1:.2f}")
        send_control(proc, reader, f"up {x_before_e:.2f} {y1:.2f}")
        wait_for_role_text(client_bin, sock, "outline.title", decomposed)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=3, undo=1, last_id=2, actions=0")

        send_control(proc, reader, "clipboard cleared")
        send_control(proc, reader, "key ctrl+c")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=3, undo=1, last_id=2, actions=0")

        # Type "X" over the RTL selection -> replaces exact "e\u0301" -> "AXB"; undo restores "Ae\u0301B".
        send_control(proc, reader, "text X")
        wait_for_role_text(client_bin, sock, "outline.title", "AXB")
        wait_for_role_text(client_bin, sock, "canvas.title", "AXB")
        wait_for_role_text(client_bin, sock, "shared.status", "rev=4, undo=2, last_id=1, actions=0")
        send_control(proc, reader, "key ctrl+z")
        wait_for_role_text(client_bin, sock, "outline.title", decomposed)
        wait_for_role_text(client_bin, sock, "canvas.title", decomposed)
        wait_for_role_text(client_bin, sock, "shared.status", "rev=5, undo=1, last_id=1, actions=0")

        # Verify RTL copy also placed exact bytes b"e\xcc\x81" on the clipboard.
        send_control(proc, reader, f"click {b2['x'] + b2['width'] - 10.0:.2f} {y2:.2f}")
        send_control(proc, reader, "key ctrl+v")
        r_rtl = wait_for_role_text(client_bin, sock, "canvas.title", "Ae\u0301Be\u0301")
        assert r_rtl["elements"][0]["text"].encode("utf-8") == b"Ae\xcc\x81Be\xcc\x81"
        send_control(proc, reader, "key ctrl+z")
        wait_for_role_text(client_bin, sock, "outline.title", decomposed)

        # 3. Drag past both ends clamps to [0, len(text)] -> typing "Z" replaces entire title.
        send_control(proc, reader, f"down {b1['x'] + b1['width'] - 4.0:.2f} {y1:.2f}")
        send_control(proc, reader, f"move {b1['x'] - 40.0:.2f} {y1:.2f}")
        send_control(proc, reader, f"up {b1['x'] - 40.0:.2f} {y1:.2f}")
        send_control(proc, reader, "text Z")
        wait_for_role_text(client_bin, sock, "outline.title", "Z")
        wait_for_role_text(client_bin, sock, "canvas.title", "Z")
        send_control(proc, reader, "key ctrl+z")
        wait_for_role_text(client_bin, sock, "outline.title", decomposed)

        print(
            f"[shared-drag] requested={req_size} captured={png_w}x{png_h}: "
            f"ltr_copy('e\\u0301',rev_kept=1) -> rtl_copy+overwrite('AXB'->undo 'Ae\\u0301B') -> "
            f"clamp_ends('Z'->undo 'Ae\\u0301B')"
        )

        send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        assert proc.returncode == 0 and not sock.exists()
        proc = None
    finally:
        stop_process(proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
