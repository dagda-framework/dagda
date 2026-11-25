#!/usr/bin/env python3
"""Acceptance test for Dagda's native fixed-aspect canvas host (`examples/canvas-slide`).

Verifies at two viewport sizes (800x540 and 640x480):
1. Separate `dagda-client` discovers `slide.card` by role and reads both window `bounds`
   and original `canvas_bounds` (220, 200, 520, 220).
2. Captures a real PNG of the rendered window and compares the actual blue filled-rectangle
   pixel bounding box directly against the inspected window `bounds`.
3. Clicks in the letterbox outside the fitted canvas via `SDL_PushEvent` and verifies
   application state stays unchanged (`selected=false, clicks=0`).
4. Clicks inside the inspected rectangle bounds via `SDL_PushEvent` and verifies
   `selected=true, clicks=1`.
"""

import json
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
    """Minimal stdlib PNG decoder (8-bit RGB or RGBA, non-interlaced)."""
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
        if filt == 1:  # Sub
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif filt == 2:  # Up
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif filt == 3:  # Average
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filt == 4:  # Paeth
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


def find_card_pixel_bbox(png_path: Path) -> tuple[int, int, int, int]:
    """Find bounding box (min_x, min_y, max_x_excl, max_y_excl) of the blue card fill RGB(52,108,194)."""
    w, h, rgb = decode_png_rgb(png_path)
    min_x, min_y = w, h
    max_x, max_y = -1, -1
    for y in range(h):
        row_off = y * w * 3
        for x in range(w):
            r = rgb[row_off + x * 3]
            g = rgb[row_off + x * 3 + 1]
            b = rgb[row_off + x * 3 + 2]
            if abs(r - 52) <= 4 and abs(g - 108) <= 4 and abs(b - 194) <= 4:
                if x < min_x:
                    min_x = x
                if y < min_y:
                    min_y = y
                if x > max_x:
                    max_x = x
                if y > max_y:
                    max_y = y
    assert max_x >= min_x and max_y >= min_y, f"card fill pixels not found in {png_path}"
    return min_x, min_y, max_x + 1, max_y + 1


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

        # Discover slide.card by role: check both window bounds and original canvas_bounds.
        code, card_resp = run_client(client_bin, sock, "inspect", "slide.card")
        assert code == 0 and card_resp["ok"] is True and len(card_resp["elements"]) == 1, (code, card_resp)
        card = card_resp["elements"][0]
        assert card["id"] == 2 and card["kind"] == "button" and "activate" in card["actions"], card
        assert card["canvas_bounds"] == {"x": 220.0, "y": 200.0, "width": 520.0, "height": 220.0}, card
        bounds = card["bounds"]
        assert bounds["width"] > 0 and bounds["height"] > 0, bounds

        # Capture PNG and compare actual rendered card pixels against inspected window bounds.
        png_path = capture_dir / f"{tag}-{size_arg}.png"
        send_control(proc, reader, f"screenshot {png_path}")
        px0, py0, px1, py1 = find_card_pixel_bbox(png_path)
        pw, ph = px1 - px0, py1 - py0
        assert abs(px0 - bounds["x"]) <= 2.5 and abs(py0 - bounds["y"]) <= 2.5, (
            f"origin mismatch: png=({px0},{py0}) inspected=({bounds['x']},{bounds['y']})"
        )
        assert abs(pw - bounds["width"]) <= 4.0 and abs(ph - bounds["height"]) <= 4.0, (
            f"size mismatch: png=({pw}x{ph}) inspected=({bounds['width']}x{bounds['height']})"
        )
        print(
            f"[{tag}] {size_arg}: inspected bounds=({bounds['x']:.1f},{bounds['y']:.1f},{bounds['width']:.1f}x{bounds['height']:.1f}) "
            f"matches PNG pixels=({px0},{py0},{pw}x{ph}), canvas_bounds={card['canvas_bounds']}"
        )

        # Click in letterbox (2, 2 is outside the 16:9 fitted canvas for non-16:9 viewports).
        send_control(proc, reader, "click 2.00 2.00")
        # Confirm state is still unchanged.
        code, h0 = run_client(client_bin, sock, "inspect", "slide.headline")
        assert code == 0 and h0["elements"][0]["text"] == "Slide Canvas (selected=false, clicks=0)", (code, h0)

        # Click inside the inspected card bounds via SDL_PushEvent -> selected=true, clicks=1.
        cx = bounds["x"] + bounds["width"] / 2.0
        cy = bounds["y"] + bounds["height"] / 2.0
        send_control(proc, reader, f"click {cx:.2f} {cy:.2f}")
        h1 = wait_for_headline(client_bin, sock, "Slide Canvas (selected=true, clicks=1)")
        print(f"[{tag}] {size_arg}: letterbox click no-op; card click ({cx:.1f},{cy:.1f}) -> {h1['elements'][0]['text']}")

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
    print("All two-viewport canvas acceptance checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
