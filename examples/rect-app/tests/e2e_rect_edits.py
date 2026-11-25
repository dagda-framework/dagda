#!/usr/bin/env python3
"""Real-process proof: advertised set_rect on a native canvas window.

Discovers set_rect from a separate dagda-client, previews
fractional bounds, verifies inspection and the rendered rectangle
are unchanged, commits at the discovered revision, checks the
next frame paints the inspected geometry, retries the old
revision, then undoes once (Ctrl+Z through the host) and confirms
the original bounds return.
"""
import json
import os
import select
import shutil
import struct
import subprocess
import tempfile
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ODIN = ROOT / "scripts" / "odin.sh"
FILLS = {(52, 108, 194), (64, 124, 214)}  # idle and hovered button fill


def read_png_bbox(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, w, h, color = 8, b"", 0, 0, 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", chunk[:10])
            assert depth == 8 and color in (2, 6)
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    bpp = 4 if color == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * bpp
    px = bytearray(w * h * bpp)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        filt = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if filt == 1:
                line[i] = (line[i] + a) & 0xFF
            elif filt == 2:
                line[i] = (line[i] + b) & 0xFF
            elif filt == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filt == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        px[y * stride:(y + 1) * stride] = line
        prev = line
    pts = [(i % w, i // w) for i in range(w * h)
           if tuple(px[i * bpp:i * bpp + 3]) in FILLS]
    assert pts, f"no button-fill pixels in {path}"
    xs = [q[0] for q in pts]
    ys = [q[1] for q in pts]
    return (min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1), (w, h)


class Reader:
    def __init__(self, proc):
        self.fd, self.buf = proc.stdout.fileno(), b""

    def line(self, timeout=15):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buf:
            left = deadline - time.monotonic()
            if left <= 0:
                raise AssertionError("timed out waiting for host acknowledgement")
            ready, _, _ = select.select([self.fd], [], [], left)
            if not ready:
                raise AssertionError("timed out waiting for host acknowledgement")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise AssertionError("host closed stdout")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode().strip()


def client(client_bin, sock, *args, expect_ok=True):
    r = subprocess.run([str(client_bin), str(sock), *args], capture_output=True, text=True, timeout=15)
    line = r.stdout.strip()
    assert line, f"empty client reply for {args}: {r.stderr!r}"
    if expect_ok:
        assert r.returncode == 0, (args, line)
    return r.returncode, json.loads(line)


def inspect_rect(client_bin, sock):
    _, resp = client(client_bin, sock, "inspect", "slide.rect")
    el = resp["elements"][0]
    assert el["canvas_bounds"] is not None, el
    return el


def assert_bbox(path, el, tol=3):
    # Expected painted pixels come from the inspected window
    # bounds, scaled from logical window size to screenshot
    # pixels (the compositor may grant a different size or
    # scale than requested). canvas_bounds are asserted
    # separately in logical canvas coordinates by the caller.
    got, (pw, ph) = read_png_bbox(path)
    b, cb = el["bounds"], el["canvas_bounds"]
    scale = b["width"] / cb["width"]
    offset_x = b["x"] - cb["x"] * scale
    offset_y = b["y"] - cb["y"] * scale
    logical_w = 960 * scale + 2 * offset_x
    logical_h = 540 * scale + 2 * offset_y
    px = pw / logical_w
    expected = (b["x"] * px, b["y"] * px, b["width"] * px, b["height"] * px)
    assert all(abs(g - e) <= tol for g, e in zip(got, expected)), f"{path}: painted {got} (png {pw}x{ph}) != inspected window bounds {expected}"


def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-rect-edits."))
    sock_dir = tmp / "sock"
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "rect.sock"
    shots = tmp / "shots"
    shots.mkdir()
    win = None
    try:
        app_bin, client_bin = tmp / "rect-app", tmp / "dagda-client"
        for src, out in [("examples/rect-app", app_bin), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
        win = subprocess.Popen([str(app_bin), "--socket", str(sock), "--control-stdin"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, cwd=ROOT)
        reader = Reader(win)

        def control(cmd):
            win.stdin.write(cmd + "\n")
            win.stdin.flush()
            line = reader.line()
            assert line.startswith("CONTROL_OK"), (cmd, line)
            return line

        assert reader.line() == f"Listening {sock}"

        _, edits = client(client_bin, sock, "edits", "7")
        assert edits == {"ok": True, "id": 7, "revision": 0, "edits": [{"name": "set_rect", "argument": "rect"}]}, edits
        before = inspect_rect(client_bin, sock)
        assert before["canvas_bounds"] == {"x": 72, "y": 240, "width": 360, "height": 180}, before
        control(f"screenshot {shots}/01-before.png")
        assert_bbox(shots / "01-before.png", before)

        # Preview fractional bounds: inspection and rendering stay.
        frac = ("120.5", "180.25", "300.75", "150.5")
        _, prev = client(client_bin, sock, "preview", "7", "set_rect", "0", "rect", *frac)
        assert prev["argument"]["rect"] == {"x": 120.5, "y": 180.25, "width": 300.75, "height": 150.5}, prev
        assert inspect_rect(client_bin, sock)["canvas_bounds"] == before["canvas_bounds"]
        control(f"screenshot {shots}/02-after-preview.png")
        assert_bbox(shots / "02-after-preview.png", before)

        # Commit at the discovered revision: the next frame paints
        # exactly the geometry inspection reports.
        _, done = client(client_bin, sock, "commit", "7", "set_rect", "0", "rect", *frac)
        assert done == {"ok": True, "id": 7, "edit": "set_rect", "revision": 1}, done
        after = inspect_rect(client_bin, sock)
        assert after["canvas_bounds"] == {"x": 120.5, "y": 180.25, "width": 300.75, "height": 150.5}, after
        control(f"screenshot {shots}/03-after-commit.png")
        assert_bbox(shots / "03-after-commit.png", after)

        # Retrying the old revision is stale and changes nothing.
        code, stale = client(client_bin, sock, "commit", "7", "set_rect", "0", "rect", "0", "0", "10", "10", expect_ok=False)
        assert code == 1 and stale == {"ok": False, "error": "Stale_Revision", "revision": 1}, stale
        assert inspect_rect(client_bin, sock)["canvas_bounds"] == after["canvas_bounds"]

        # Ctrl+Shift+Z and a repeat-only Ctrl+Z must not undo:
        # geometry, revision, and undo history all survive.
        control("key ctrl+shift+z")
        control("key ctrl+z+repeat")
        control("key ctrl+super+z")
        kept = inspect_rect(client_bin, sock)
        assert kept["canvas_bounds"] == after["canvas_bounds"], kept
        _, edits_kept = client(client_bin, sock, "edits", "7")
        assert edits_kept["revision"] == 1, edits_kept
        control(f"screenshot {shots}/03b-after-bogus-undo.png")
        assert_bbox(shots / "03b-after-bogus-undo.png", kept)

        # Existing activate behavior still answers through invoke.
        code, inv = client(client_bin, sock, "invoke", "7", "activate", expect_ok=False)
        assert inv["ok"] is False, inv  # app handler declines; protocol preserved

        # One undo restores the original bounds.
        control("key ctrl+z")
        restored = inspect_rect(client_bin, sock)
        assert restored["canvas_bounds"] == before["canvas_bounds"], restored
        _, edits_after = client(client_bin, sock, "edits", "7")
        assert edits_after["revision"] == 2, edits_after
        control(f"screenshot {shots}/04-after-undo.png")
        assert_bbox(shots / "04-after-undo.png", restored)

        control("quit")
        win.wait(timeout=10)
        win = None
        print("e2e rect edits: all checks passed")
        return 0
    finally:
        if win is not None and win.poll() is None:
            win.terminate()
            win.wait(timeout=10)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
