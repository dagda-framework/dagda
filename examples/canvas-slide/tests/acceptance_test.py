#!/usr/bin/env python3
"""Acceptance test for Dagda's native fixed-aspect canvas host (`examples/canvas-slide`).

Verifies:
1. Two viewport sizes (800x540 and 640x480):
   - Separate `dagda-client` discovers `slide.card` by role (window `bounds` + `canvas_bounds`).
   - Actual PNG pixels match inspected window `bounds` in BOTH idle RGB(52,108,194) and
     hovered RGB(64,124,214) states, reporting actual captured dimensions separately from requested.
   - Letterbox click leaves application state unchanged; card click updates headline.
2. Fractional edge clipping & f32 canvas_bounds round-trip (801x542, --overflow-card):
   - Card extends above and below the 960x540 canvas with x=93.125 and width=200.0625.
   - Real `dagda-client` round-trips exact `x=93.125` and `width=200.0625`.
   - At 801x542 (fitted vertical range [45.71875, 496.28125)), pixel rows 45 and 496 retain
     the letterbox background RGB(14,16,22), adjacent interior rows 46 and 495 show the card,
     and clicks at those exact pixel centers agree with the drawing.
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

LETTERBOX_RGB = (14, 16, 22)
SHEET_RGB = (26, 31, 42)
IDLE_CARD_RGB = (52, 108, 194)
HOVER_CARD_RGB = (64, 124, 214)


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
                return raw.decode("utf-8", errors="replace").rstrip("\r")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"timed out waiting for line during {stage} (partial={bytes(self.buf)!r})")
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                raise TimeoutError(f"timed out waiting for line during {stage} (partial={bytes(self.buf)!r})")
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
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


def decode_png_rgb(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"not a PNG: {path}"
    pos = 8
    width = height = bit_depth = color_type = 0
    idat = bytearray()
    while pos < len(data):
        length, ctype = struct.unpack(">I4s", data[pos : pos + 8])
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            assert bit_depth == 8 and color_type in (2, 6) and interlace == 0, (bit_depth, color_type, interlace)
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break

    bpp = 3 if color_type == 2 else 4
    stride = width * bpp
    raw = zlib.decompress(bytes(idat))
    out = bytearray(width * height * 3)
    prev = bytearray(stride)
    idx = 0
    for y in range(height):
        filt = raw[idx]
        idx += 1
        row = bytearray(raw[idx : idx + stride])
        idx += stride
        if filt == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif filt == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif filt == 3:
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filt == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                row[i] = (row[i] + pr) & 0xFF
        elif filt != 0:
            raise AssertionError(f"unsupported PNG filter {filt}")
        prev = row
        dst_row = y * width * 3
        for x in range(width):
            out[dst_row + x * 3 : dst_row + x * 3 + 3] = row[x * bpp : x * bpp + 3]
    return width, height, bytes(out)


def rgb_close(a: tuple[int, int, int], b: tuple[int, int, int], tol: int = 4) -> bool:
    return abs(a[0] - b[0]) <= tol and abs(a[1] - b[1]) <= tol and abs(a[2] - b[2]) <= tol


def pixel_at(w: int, rgb: bytes, x: int, y: int) -> tuple[int, int, int]:
    off = (y * w + x) * 3
    return rgb[off], rgb[off + 1], rgb[off + 2]


def find_card_pixel_bbox(
    png_path: Path,
    expected_state: str = "any",
    exclude_rect: dict | None = None,
) -> tuple[int, int, int, int, int, int, str]:
    """Find bounding box of card fill pixels in idle or hovered state.
    Returns (png_w, png_h, min_x, min_y, max_x_excl, max_y_excl, detected_state).
    """
    w, h, rgb = decode_png_rgb(png_path)
    ex0 = ex1 = ey0 = ey1 = -1
    if exclude_rect is not None:
        ex0 = int(math.floor(exclude_rect["x"])) - 4
        ey0 = int(math.floor(exclude_rect["y"])) - 4
        ex1 = int(math.ceil(exclude_rect["x"] + exclude_rect["width"])) + 4
        ey1 = int(math.ceil(exclude_rect["y"] + exclude_rect["height"])) + 4
    min_x, min_y = w, h
    max_x, max_y = -1, -1
    idle_hits = 0
    hover_hits = 0
    for y in range(h):
        row_off = y * w * 3
        in_ey = exclude_rect is not None and ey0 <= y < ey1
        for x in range(w):
            if in_ey and ex0 <= x < ex1:
                continue
            px = (rgb[row_off + x * 3], rgb[row_off + x * 3 + 1], rgb[row_off + x * 3 + 2])
            is_idle = rgb_close(px, IDLE_CARD_RGB)
            is_hover = rgb_close(px, HOVER_CARD_RGB)
            if is_idle:
                idle_hits += 1
            if is_hover:
                hover_hits += 1
            if is_idle or is_hover:
                if x < min_x:
                    min_x = x
                if y < min_y:
                    min_y = y
                if x > max_x:
                    max_x = x
                if y > max_y:
                    max_y = y
    assert max_x >= min_x and max_y >= min_y, f"card fill pixels not found in {png_path}"
    detected = "hovered" if hover_hits > idle_hits else "idle"
    if expected_state != "any":
        assert detected == expected_state, (
            f"expected {expected_state} card fill in {png_path}, got {detected} "
            f"(idle_hits={idle_hits}, hover_hits={hover_hits})"
        )
    return w, h, min_x, min_y, max_x + 1, max_y + 1, detected


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


def wait_for_headline(client_bin: Path, sock: Path, expected: str, timeout: float = 3.0) -> dict:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        code, resp = run_client(client_bin, sock, "inspect", "slide.headline")
        last = (code, resp)
        if code == 0 and resp.get("ok") is True and resp["elements"][0]["text"] == expected:
            return resp
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for slide.headline == {expected!r}; last={last}")


def assert_bbox_matches(bounds: dict, px0: int, py0: int, px1: int, py1: int) -> None:
    pw, ph = px1 - px0, py1 - py0
    assert abs(px0 - bounds["x"]) <= 2.5 and abs(py0 - bounds["y"]) <= 2.5, (
        f"origin mismatch: png=({px0},{py0}) inspected=({bounds['x']},{bounds['y']})"
    )
    assert abs(pw - bounds["width"]) <= 4.0 and abs(ph - bounds["height"]) <= 4.0, (
        f"size mismatch: png=({pw}x{ph}) inspected=({bounds['width']}x{bounds['height']})"
    )


def capture_card_state(
    proc: subprocess.Popen,
    reader: DeadlineLineReader,
    png_path: Path,
    expected_state: str,
    exclude_rect: dict | None = None,
    timeout: float = 2.0,
) -> tuple[int, int, int, int, int, int, str]:
    deadline = time.monotonic() + timeout
    while True:
        send_control(proc, reader, f"screenshot {png_path}")
        try:
            return find_card_pixel_bbox(png_path, expected_state=expected_state, exclude_rect=exclude_rect)
        except AssertionError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.02)


def canvas_bounds_close(actual: dict, expected: dict, tol: float = 1.5) -> bool:
    return (
        abs(actual["x"] - expected["x"]) <= tol
        and abs(actual["y"] - expected["y"]) <= tol
        and abs(actual["width"] - expected["width"]) <= tol
        and abs(actual["height"] - expected["height"]) <= tol
    )


def wait_for_card_canvas_bounds(
    client_bin: Path,
    sock: Path,
    expected: dict,
    tol: float = 1.5,
    timeout: float = 3.0,
) -> dict:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        code, resp = run_client(client_bin, sock, "inspect", "slide.card")
        last = (code, resp)
        if code == 0 and resp.get("ok") is True and len(resp["elements"]) == 1:
            el = resp["elements"][0]
            if canvas_bounds_close(el["canvas_bounds"], expected, tol=tol):
                return el
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for slide.card canvas_bounds≈{expected}; last={last}")


def verify_viewport(
    canvas_bin: Path,
    client_bin: Path,
    capture_dir: Path,
    size_arg: str,
    tag: str,
    start_over_card: bool = False,
) -> None:
    sock_dir = Path(tempfile.mkdtemp(prefix=f"dagda-canvas-{tag}."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "canvas.sock"
    proc = None
    try:
        proc = subprocess.Popen(
            [str(canvas_bin), "--size", size_arg, "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
        )
        assert proc.stdout is not None
        reader = DeadlineLineReader(proc.stdout)
        ready = reader.read_line(f"canvas startup ({size_arg})", timeout=5.0)
        assert ready == f"Listening {sock}", f"unexpected startup: {ready!r}"

        code, card_resp = run_client(client_bin, sock, "inspect", "slide.card")
        assert code == 0 and card_resp["ok"] is True and len(card_resp["elements"]) == 1, (code, card_resp)
        card = card_resp["elements"][0]
        assert card["id"] == 2 and card["kind"] == "button" and "activate" in card["actions"], card
        assert card["canvas_bounds"] == {"x": 220, "y": 200, "width": 520, "height": 220}, card
        bounds = card["bounds"]
        cx = bounds["x"] + bounds["width"] / 2.0
        cy = bounds["y"] + bounds["height"] / 2.0

        code, undo_resp = run_client(client_bin, sock, "inspect", "slide.undo")
        assert code == 0 and undo_resp["ok"] is True and len(undo_resp["elements"]) == 1, (code, undo_resp)
        undo_btn = undo_resp["elements"][0]
        undo_bounds = undo_btn["bounds"]

        # Optionally pre-position the pointer over the card to prove the sequence
        # recovers cleanly when the pointer starts inside the card.
        if start_over_card:
            send_control(proc, reader, f"hover {cx:.2f} {cy:.2f}")
            pre_png = capture_dir / f"{tag}-{size_arg}-pre-hover.png"
            _, _, ppx0, ppy0, ppx1, ppy1, st_pre = capture_card_state(
                proc, reader, pre_png, "hovered", exclude_rect=undo_bounds
            )
            assert st_pre == "hovered"
            assert_bbox_matches(bounds, ppx0, ppy0, ppx1, ppy1)

        # 1. Explicitly move pointer outside the card and wait with a deadline for idle capture.
        send_control(proc, reader, "hover 2.00 2.00")
        idle_png = capture_dir / f"{tag}-{size_arg}-idle.png"
        png_w, png_h, px0, py0, px1, py1, st_idle = capture_card_state(
            proc, reader, idle_png, "idle", exclude_rect=undo_bounds
        )
        # Re-inspect after capture so tiled Wayland compositors that resize on map
        # are compared against the settled viewport's bounds.
        code, card_resp = run_client(client_bin, sock, "inspect", "slide.card")
        assert code == 0 and card_resp["ok"] is True and len(card_resp["elements"]) == 1, (code, card_resp)
        bounds = card_resp["elements"][0]["bounds"]
        cx = bounds["x"] + bounds["width"] / 2.0
        cy = bounds["y"] + bounds["height"] / 2.0
        code, undo_resp = run_client(client_bin, sock, "inspect", "slide.undo")
        assert code == 0 and undo_resp["ok"] is True and len(undo_resp["elements"]) == 1, (code, undo_resp)
        undo_bounds = undo_resp["elements"][0]["bounds"]
        assert_bbox_matches(bounds, px0, py0, px1, py1)

        # 2. Move pointer inside the card and wait with a deadline for hovered capture.
        send_control(proc, reader, f"hover {cx:.2f} {cy:.2f}")
        hover_png = capture_dir / f"{tag}-{size_arg}-hover.png"
        hw, hh, hpx0, hpy0, hpx1, hpy1, st_hover = capture_card_state(
            proc, reader, hover_png, "hovered", exclude_rect=undo_bounds
        )
        assert (hw, hh) == (png_w, png_h)
        assert_bbox_matches(bounds, hpx0, hpy0, hpx1, hpy1)

        start_note = " start_over_card=true" if start_over_card else ""
        print(
            f"[{tag}] requested={size_arg} captured={png_w}x{png_h}{start_note}: "
            f"inspected=({bounds['x']:.1f},{bounds['y']:.1f},{bounds['width']:.1f}x{bounds['height']:.1f}) "
            f"idle_png=({px0},{py0},{px1-px0}x{py1-py0},{st_idle}) "
            f"hover_png=({hpx0},{hpy0},{hpx1-hpx0}x{hpy1-hpy0},{st_hover})"
        )

        # 3. Letterbox click leaves state unchanged.
        send_control(proc, reader, "click 2.00 2.00")
        code, h0 = run_client(client_bin, sock, "inspect", "slide.headline")
        assert code == 0 and h0["elements"][0]["text"] == "Slide Canvas (selected=false, clicks=0, undo=0)", (code, h0)

        # 4. Card click preserves button activation.
        send_control(proc, reader, f"click {cx:.2f} {cy:.2f}")
        h1 = wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=1, undo=0)")
        print(f"[{tag}] letterbox click no-op; card click ({cx:.1f},{cy:.1f}) -> {h1['elements'][0]['text']}")

        # 5. Drag card with 3 separate motion events -> updates document bounds, produces 1 undo step.
        scale = min(png_w / 960.0, png_h / 540.0)
        send_control(proc, reader, f"down {cx:.2f} {cy:.2f}")
        send_control(proc, reader, f"move {cx + 20.0 * scale:.2f} {cy - 10.0 * scale:.2f}")
        send_control(proc, reader, f"move {cx + 40.0 * scale:.2f} {cy - 20.0 * scale:.2f}")
        send_control(proc, reader, f"move {cx + 60.0 * scale:.2f} {cy - 30.0 * scale:.2f}")
        send_control(proc, reader, f"up {cx + 60.0 * scale:.2f} {cy - 30.0 * scale:.2f}")

        expected_drag = {"x": 280.0, "y": 170.0, "width": 520.0, "height": 220.0}
        dragged = wait_for_card_canvas_bounds(client_bin, sock, expected_drag)
        dragged_cb = dragged["canvas_bounds"]
        wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=1, undo=1)")

        # 6. Resize card from bottom-right corner -> updates document width/height, produces 1 undo step.
        db = dragged["bounds"]
        rx = db["x"] + db["width"] - 8.0 * scale
        ry = db["y"] + db["height"] - 8.0 * scale
        send_control(proc, reader, f"down {rx:.2f} {ry:.2f}")
        send_control(proc, reader, f"move {rx + 20.0 * scale:.2f} {ry + 12.5 * scale:.2f}")
        send_control(proc, reader, f"move {rx + 40.0 * scale:.2f} {ry + 25.0 * scale:.2f}")
        send_control(proc, reader, f"up {rx + 40.0 * scale:.2f} {ry + 25.0 * scale:.2f}")

        expected_resize = {
            "x": dragged_cb["x"],
            "y": dragged_cb["y"],
            "width": 560.0,
            "height": 245.0,
        }
        resized = wait_for_card_canvas_bounds(client_bin, sock, expected_resize)
        resized_cb = resized["canvas_bounds"]
        wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=1, undo=2)")

        # 7. Cancelled drag (Escape) restores geometry and consumes no undo step.
        rb = resized["bounds"]
        rcx = rb["x"] + rb["width"] / 2.0
        rcy = rb["y"] + rb["height"] / 2.0
        send_control(proc, reader, f"down {rcx:.2f} {rcy:.2f}")
        send_control(proc, reader, f"move {rcx - 25.0 * scale:.2f} {rcy + 20.0 * scale:.2f}")
        send_control(proc, reader, f"move {rcx - 50.0 * scale:.2f} {rcy + 40.0 * scale:.2f}")
        wait_for_card_canvas_bounds(
            client_bin,
            sock,
            {
                "x": resized_cb["x"] - 50.0,
                "y": resized_cb["y"] + 40.0,
                "width": resized_cb["width"],
                "height": resized_cb["height"],
            },
        )
        send_control(proc, reader, "key escape")
        restored = wait_for_card_canvas_bounds(client_bin, sock, resized_cb, tol=0.001)
        assert restored["canvas_bounds"] == resized_cb, (restored["canvas_bounds"], resized_cb)
        wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=1, undo=2)")

        # 8. Undo twice via slide.undo button: resize -> dragged -> original (proves 1 undo step per gesture).
        code, u1 = run_client(client_bin, sock, "invoke", str(undo_btn["id"]), "activate")
        assert code == 0 and u1["ok"] is True, (code, u1)
        after_u1 = wait_for_card_canvas_bounds(client_bin, sock, dragged_cb, tol=0.001)
        assert after_u1["canvas_bounds"] == dragged_cb
        wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=1, undo=1)")

        code, u2 = run_client(client_bin, sock, "invoke", str(undo_btn["id"]), "activate")
        assert code == 0 and u2["ok"] is True, (code, u2)
        orig = {"x": 220, "y": 200, "width": 520, "height": 220}
        after_u2 = wait_for_card_canvas_bounds(client_bin, sock, orig, tol=0.001)
        assert after_u2["canvas_bounds"] == orig
        wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=1, undo=0)")

        print(
            f"[{tag}] gestures: drag=({dragged_cb['x']:.1f},{dragged_cb['y']:.1f},{dragged_cb['width']:.1f}x{dragged_cb['height']:.1f}) "
            f"resize=({resized_cb['x']:.1f},{resized_cb['y']:.1f},{resized_cb['width']:.1f}x{resized_cb['height']:.1f}) "
            f"cancel->restored(undo=2) undo->dragged->orig(undo=0)"
        )

        send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        assert proc.returncode == 0 and not sock.exists()
        proc = None
    finally:
        stop_process(proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


def verify_fractional_edge_and_precision(canvas_bin: Path, client_bin: Path, capture_dir: Path) -> None:
    """Verify 960x540 canvas in 801x542 viewport with card extending above/below canvas
    and fractional f32 canvas_bounds (x=93.125, width=200.0625).
    """
    sock_dir = Path(tempfile.mkdtemp(prefix="dagda-canvas-edge."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "canvas.sock"
    proc = None
    try:
        proc = subprocess.Popen(
            [str(canvas_bin), "--size", "801x542", "--overflow-card", "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
        )
        assert proc.stdout is not None
        reader = DeadlineLineReader(proc.stdout)
        ready = reader.read_line("overflow canvas startup (801x542)", timeout=5.0)
        assert ready == f"Listening {sock}", f"unexpected startup: {ready!r}"

        # 1. Verify exact f32 canvas_bounds round-trip through real dagda-client.
        code, card_resp = run_client(client_bin, sock, "inspect", "slide.card")
        assert code == 0 and card_resp["ok"] is True, (code, card_resp)
        card = card_resp["elements"][0]
        cb = card["canvas_bounds"]
        assert cb["x"] == 93.125 and cb["width"] == 200.0625, f"f32 precision lost: {cb}"
        assert cb["y"] == -40 and cb["height"] == 620, cb
        bounds = card["bounds"]

        # 2. Capture PNG and compute exact fitted vertical range for actual captured viewport.
        png_path = capture_dir / "edge-801x542-overflow.png"
        send_control(proc, reader, f"screenshot {png_path}")
        png_w, png_h, rgb = decode_png_rgb(png_path)

        scale = min(png_w / 960.0, png_h / 540.0)
        y_top = (png_h - 540.0 * scale) / 2.0
        y_bot = y_top + 540.0 * scale
        in_top = math.ceil(y_top - 0.5)
        out_top = in_top - 1
        out_bot = math.ceil(y_bot - 0.5)
        in_bot = out_bot - 1

        if (png_w, png_h) == (801, 542):
            assert (out_top, in_top, in_bot, out_bot) == (45, 46, 495, 496), (
                out_top, in_top, in_bot, out_bot, y_top, y_bot
            )

        # Sample horizontally near the middle of the card (avoiding text center).
        sample_x = int(bounds["x"] + bounds["width"] * 0.25)
        px_out_top = pixel_at(png_w, rgb, sample_x, out_top)
        px_in_top = pixel_at(png_w, rgb, sample_x, in_top)
        px_in_bot = pixel_at(png_w, rgb, sample_x, in_bot)
        px_out_bot = pixel_at(png_w, rgb, sample_x, out_bot)

        assert rgb_close(px_out_top, LETTERBOX_RGB), f"row {out_top} expected letterbox, got {px_out_top}"
        assert rgb_close(px_out_bot, LETTERBOX_RGB), f"row {out_bot} expected letterbox, got {px_out_bot}"
        assert rgb_close(px_in_top, IDLE_CARD_RGB) or rgb_close(px_in_top, HOVER_CARD_RGB), (
            f"row {in_top} expected card fill, got {px_in_top}"
        )
        assert rgb_close(px_in_bot, IDLE_CARD_RGB) or rgb_close(px_in_bot, HOVER_CARD_RGB), (
            f"row {in_bot} expected card fill, got {px_in_bot}"
        )

        # Sample blank sheet to the right of all elements (x=771 at 801x542).
        x_left = (png_w - 960.0 * scale) / 2.0
        sheet_x = 771 if (png_w, png_h) == (801, 542) else int(x_left + 924.0 * scale)
        sh_out_top = pixel_at(png_w, rgb, sheet_x, out_top)
        sh_in_top = pixel_at(png_w, rgb, sheet_x, in_top)
        sh_in_bot = pixel_at(png_w, rgb, sheet_x, in_bot)
        sh_out_bot = pixel_at(png_w, rgb, sheet_x, out_bot)

        assert rgb_close(sh_out_top, LETTERBOX_RGB), f"blank sheet x={sheet_x} row {out_top} expected letterbox, got {sh_out_top}"
        assert rgb_close(sh_out_bot, LETTERBOX_RGB), f"blank sheet x={sheet_x} row {out_bot} expected letterbox, got {sh_out_bot}"
        assert rgb_close(sh_in_top, SHEET_RGB), f"blank sheet x={sheet_x} row {in_top} expected sheet {SHEET_RGB}, got {sh_in_top}"
        assert rgb_close(sh_in_bot, SHEET_RGB), f"blank sheet x={sheet_x} row {in_bot} expected sheet {SHEET_RGB}, got {sh_in_bot}"

        # 3. Clicks at outer row pixel centers must miss; clicks at adjacent interior centers must hit.
        click_x = sample_x + 0.5
        send_control(proc, reader, f"click {click_x:.2f} {out_top + 0.5:.2f}")
        send_control(proc, reader, f"click {click_x:.2f} {out_bot + 0.5:.2f}")
        code, h0 = run_client(client_bin, sock, "inspect", "slide.headline")
        assert code == 0 and h0["elements"][0]["text"] == "Slide Canvas (selected=false, clicks=0, undo=0)", (code, h0)

        send_control(proc, reader, f"click {click_x:.2f} {in_top + 0.5:.2f}")
        wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=1, undo=0)")

        send_control(proc, reader, f"click {click_x:.2f} {in_bot + 0.5:.2f}")
        wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=2, undo=0)")

        print(
            f"[edge] requested=801x542 captured={png_w}x{png_h} fitted_y=[{y_top:.5f},{y_bot:.5f}): "
            f"canvas_bounds=(x={cb['x']}, width={cb['width']}) "
            f"card_x={sample_x} sheet_x={sheet_x} "
            f"rows out=({out_top},{out_bot}) letterbox+miss, in=({in_top},{in_bot}) card+sheet+hit (clicks=2)"
        )

        send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        assert proc.returncode == 0 and not sock.exists()
        proc = None
    finally:
        stop_process(proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


def main() -> int:
    capture_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build" / "canvas-capture"
    capture_dir.mkdir(parents=True, exist_ok=True)

    build_dir = ROOT / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    canvas_bin = build_dir / "canvas-slide"
    client_bin = build_dir / "dagda-client"

    subprocess.check_call([str(ODIN), "build", "examples/canvas-slide", "-collection:dagda=.", f"-out:{canvas_bin}"], cwd=ROOT)
    subprocess.check_call([str(ODIN), "build", "examples/dagda-client", "-collection:dagda=.", f"-out:{client_bin}"], cwd=ROOT)

    verify_viewport(canvas_bin, client_bin, capture_dir, "800x540", "vp1")
    verify_viewport(canvas_bin, client_bin, capture_dir, "640x480", "vp2", start_over_card=True)
    verify_fractional_edge_and_precision(canvas_bin, client_bin, capture_dir)
    print("All canvas acceptance checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
