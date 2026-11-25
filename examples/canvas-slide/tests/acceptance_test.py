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
    png_path: Path, expected_state: str = "any"
) -> tuple[int, int, int, int, int, int, str]:
    """Find bounding box of card fill pixels in idle or hovered state.
    Returns (png_w, png_h, min_x, min_y, max_x_excl, max_y_excl, detected_state).
    """
    w, h, rgb = decode_png_rgb(png_path)
    min_x, min_y = w, h
    max_x, max_y = -1, -1
    idle_hits = 0
    hover_hits = 0
    for y in range(h):
        row_off = y * w * 3
        for x in range(w):
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


def verify_viewport(canvas_bin: Path, client_bin: Path, capture_dir: Path, size_arg: str, tag: str) -> None:
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

        # 1. Idle state PNG check.
        idle_png = capture_dir / f"{tag}-{size_arg}-idle.png"
        send_control(proc, reader, f"screenshot {idle_png}")
        png_w, png_h, px0, py0, px1, py1, st_idle = find_card_pixel_bbox(idle_png, expected_state="idle")
        assert_bbox_matches(bounds, px0, py0, px1, py1)

        # 2. Hovered state PNG check (move pointer into card via SDL_PushEvent MOUSE_MOTION).
        cx = bounds["x"] + bounds["width"] / 2.0
        cy = bounds["y"] + bounds["height"] / 2.0
        send_control(proc, reader, f"hover {cx:.2f} {cy:.2f}")
        hover_png = capture_dir / f"{tag}-{size_arg}-hover.png"
        deadline = time.monotonic() + 2.0
        while True:
            send_control(proc, reader, f"screenshot {hover_png}")
            try:
                hw, hh, hpx0, hpy0, hpx1, hpy1, st_hover = find_card_pixel_bbox(hover_png, expected_state="hovered")
                break
            except AssertionError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.02)
        assert (hw, hh) == (png_w, png_h)
        assert_bbox_matches(bounds, hpx0, hpy0, hpx1, hpy1)

        print(
            f"[{tag}] requested={size_arg} captured={png_w}x{png_h}: "
            f"inspected=({bounds['x']:.1f},{bounds['y']:.1f},{bounds['width']:.1f}x{bounds['height']:.1f}) "
            f"idle_png=({px0},{py0},{px1-px0}x{py1-py0},{st_idle}) "
            f"hover_png=({hpx0},{hpy0},{hpx1-hpx0}x{hpy1-hpy0},{st_hover})"
        )

        # 3. Letterbox click leaves state unchanged.
        send_control(proc, reader, "click 2.00 2.00")
        code, h0 = run_client(client_bin, sock, "inspect", "slide.headline")
        assert code == 0 and h0["elements"][0]["text"] == "Slide Canvas (selected=false, clicks=0)", (code, h0)

        # 4. Card click triggers handler.
        send_control(proc, reader, f"click {cx:.2f} {cy:.2f}")
        h1 = wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=1)")
        print(f"[{tag}] letterbox click no-op; card click ({cx:.1f},{cy:.1f}) -> {h1['elements'][0]['text']}")

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

        # 3. Clicks at outer row pixel centers must miss; clicks at adjacent interior centers must hit.
        click_x = sample_x + 0.5
        send_control(proc, reader, f"click {click_x:.2f} {out_top + 0.5:.2f}")
        send_control(proc, reader, f"click {click_x:.2f} {out_bot + 0.5:.2f}")
        code, h0 = run_client(client_bin, sock, "inspect", "slide.headline")
        assert code == 0 and h0["elements"][0]["text"] == "Slide Canvas (selected=false, clicks=0)", (code, h0)

        send_control(proc, reader, f"click {click_x:.2f} {in_top + 0.5:.2f}")
        wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=1)")

        send_control(proc, reader, f"click {click_x:.2f} {in_bot + 0.5:.2f}")
        wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=2)")

        print(
            f"[edge] requested=801x542 captured={png_w}x{png_h} fitted_y=[{y_top:.5f},{y_bot:.5f}): "
            f"canvas_bounds=(x={cb['x']}, width={cb['width']}) "
            f"rows out=({out_top},{out_bot}) letterbox+miss, in=({in_top},{in_bot}) card+hit (clicks=2)"
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
    verify_viewport(canvas_bin, client_bin, capture_dir, "640x480", "vp2")
    verify_fractional_edge_and_precision(canvas_bin, client_bin, capture_dir)
    print("All canvas acceptance checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
