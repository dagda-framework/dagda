#!/usr/bin/env python3
"""Reproducible native-window caret and grapheme hit-test probe.

Exercises examples/shared-text in a real OS window (Cocoa on macOS, Wayland/X11
on Linux, or dummy if explicitly set in SDL_VIDEODRIVER) using ONLY plain text
and pointer input (no platform-specific keyboard shortcuts):

1. Confirms SDL's active video driver, logical window size (points), renderer
   output size (pixels), pixel density, and display scale.
2. Inspects the translated editable field (canvas.title) via a separate
   dagda-client process and queries exact text widths from the running host's
   loaded FreeType font.
3. Inserts decomposed "Cafe\\u0301 " using plain pointer click + TEXT_INPUT.
4. Clicks left and right of the decomposed e + U+0301 grapheme midpoint,
   verifies the painted amber caret location against the measured grapheme
   boundaries, and types markers ('[', ']') to prove exact UTF-8 byte offsets.
5. Resizes the window (640x480), verifies updated window/output/field bounds,
   and repeats the left/right midpoint clicks with markers ('<', '>').

Input paths (reported separately):
- Pointer clicks:
  - --input-mode sdl (default): injected via --control-stdin into SDL3's event
    queue (SDL_PushEvent of SDL_EVENT_MOUSE_BUTTON_DOWN/UP in logical window
    points). Works even on backends that cannot report global window coordinates.
  - --input-mode native: posted through macOS CoreGraphics CGEventPost in global
    screen logical points converted from SDL_GetWindowPosition. Requires a valid
    current content origin and a focused target window before posting any click,
    and never falls back to SDL injection.
- Marker text commits: always injected via --control-stdin `text`
  (SDL_PushEvent of SDL_EVENT_TEXT_INPUT) so marker insertion stays independent
  of platform keyboard shortcuts and input-source state.
- Element discovery and committed text/bounds assertions run in a separate
  dagda-client process over the Unix domain socket.
"""

from __future__ import annotations

import argparse
import ctypes
import io
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
E_ACUTE_DECOMPOSED = "e\u0301"  # U+0065 + U+0301 -> UTF-8 bytes 65 CC 81
WINDOW_TITLE = "Dagda — Shared Text Fixture"


class DeadlineLineReader:
    def __init__(self, stream) -> None:
        self.fd = stream.fileno()
        self.buf = bytearray()

    def read_line(self, stage: str, timeout: float = 10.0) -> str:
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
                    f"timed out after {timeout:.2f}s waiting for line during {stage} "
                    f"(partial={bytes(self.buf)!r})"
                )
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                continue
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise AssertionError(f"unexpected EOF during {stage} (partial={bytes(self.buf)!r})")
            self.buf.extend(chunk)


def drain_stderr_nonblocking(stream) -> str:
    """Read any bytes immediately available on stream without blocking for EOF."""
    if stream is None:
        return ""
    try:
        fd = stream.fileno()
    except (OSError, ValueError):
        return ""
    buf = bytearray()
    while True:
        ready, _, _ = select.select([fd], [], [], 0.0)
        if not ready:
            break
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf.extend(chunk)
    return buf.decode("utf-8", errors="replace")


def stop_process(proc: subprocess.Popen | None) -> str:
    """Terminate and reap proc, draining any buffered stderr without blocking."""
    if proc is None:
        return ""
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
    stderr_out = drain_stderr_nonblocking(proc.stderr)
    for stream in (proc.stdin, proc.stdout, proc.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass
    return stderr_out


def wait_for_startup(
    proc: subprocess.Popen,
    reader: DeadlineLineReader,
    sock: Path,
    timeout: float = 10.0,
    err_stream=None,
) -> str:
    """Wait for the host's startup readiness line; on failure, terminate and reap
    the child immediately and drain stderr non-blockingly before re-raising.
    """
    try:
        ready = reader.read_line("shared-text startup", timeout=timeout)
    except Exception:
        stderr_out = stop_process(proc)
        if stderr_out:
            target = sys.stderr if err_stream is None else err_stream
            print(f"STARTUP_STDERR:\n{stderr_out}", file=target)
        raise
    assert ready == f"Listening {sock}", f"unexpected startup: {ready!r}"
    return ready


def verify_startup_timeout_bounded() -> None:
    """Regression: a child that writes a partial stdout line and stderr then
    stays alive past the readiness deadline must fail promptly, preserve the
    stage and partial-line diagnostic, and be terminated and reaped.
    """
    child_code = (
        "import sys, time\n"
        "sys.stdout.write('Listen'); sys.stdout.flush()\n"
        "sys.stderr.write('startup stalled\\n'); sys.stderr.flush()\n"
        "time.sleep(15)\n"
    )
    proc = subprocess.Popen(
        [sys.executable, "-c", child_code],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    pid = proc.pid
    assert proc.stdout is not None
    reader = DeadlineLineReader(proc.stdout)
    diag = io.StringIO()
    start = time.monotonic()
    err: TimeoutError | None = None
    try:
        try:
            wait_for_startup(proc, reader, Path("/tmp/unused.sock"), timeout=0.3, err_stream=diag)
        except TimeoutError as exc:
            err = exc
    finally:
        stop_process(proc)
    elapsed = time.monotonic() - start
    assert err is not None, "expected TimeoutError for stalled startup child"
    msg = str(err)
    assert "shared-text startup" in msg, f"missing stage in error: {msg!r}"
    assert "b'Listen'" in msg, f"missing partial-line diagnostic in error: {msg!r}"
    assert "startup stalled" in diag.getvalue(), f"missing stderr diagnostic: {diag.getvalue()!r}"
    assert elapsed < 2.0, f"startup timeout was not bounded (elapsed={elapsed:.2f}s)"
    assert proc.poll() is not None, f"child pid {pid} was not reaped"
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError(f"child pid {pid} is still alive after startup timeout")
    print(f"[startup-timeout] bounded failure in {elapsed:.2f}s, child pid {pid} reaped, diagnostics preserved")


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


def rgb_close(p: tuple[int, int, int], target: tuple[int, int, int], tol: int = 10) -> bool:
    return abs(p[0] - target[0]) <= tol and abs(p[1] - target[1]) <= tol and abs(p[2] - target[2]) <= tol


def find_caret_x_pixels(
    w: int,
    h: int,
    rgb: bytearray,
    bounds: dict,
    scale_x: float,
    scale_y: float,
) -> tuple[float, list[int]]:
    """Find the painted vertical amber caret X in output pixels inside the
    scaled field bounds. Returns (caret_x_px, caret_cols_px).
    """
    x0 = max(0, int(math.floor(bounds["x"] * scale_x)) + 2)
    x1 = min(w, int(math.ceil((bounds["x"] + bounds["width"]) * scale_x)) - 2)
    y0 = max(0, int(math.floor(bounds["y"] * scale_y)) + 4)
    y1 = min(h, int(math.floor((bounds["y"] + bounds["height"] * 0.65) * scale_y)))
    col_hits: dict[int, int] = {}
    for y in range(y0, y1):
        row_off = y * w * 3
        for x in range(x0, x1):
            px = (rgb[row_off + x * 3], rgb[row_off + x * 3 + 1], rgb[row_off + x * 3 + 2])
            if rgb_close(px, CARET_AMBER_RGB):
                col_hits[x] = col_hits.get(x, 0) + 1
    min_hits = max(6, int(round(6 * scale_y)))
    caret_cols = sorted(x for x, cnt in col_hits.items() if cnt >= min_hits)
    if not caret_cols:
        # Diagnostic fallback: scan the whole image to see where amber pixels landed.
        global_cols: dict[int, int] = {}
        for y in range(h):
            row_off = y * w * 3
            for x in range(w):
                px = (rgb[row_off + x * 3], rgb[row_off + x * 3 + 1], rgb[row_off + x * 3 + 2])
                if rgb_close(px, CARET_AMBER_RGB):
                    global_cols[x] = global_cols.get(x, 0) + 1
        found_global = sorted(x for x, cnt in global_cols.items() if cnt >= min_hits)
        raise AssertionError(
            f"no vertical amber caret found inside scaled bounds "
            f"[{x0}..{x1}, {y0}..{y1}] (scale={scale_x:.3f}x{scale_y:.3f}, "
            f"png={w}x{h}, local_hits={col_hits}, global_caret_cols={found_global[:20]})"
        )
    return float(caret_cols[0]), caret_cols


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


def send_control_raw(proc: subprocess.Popen, reader: DeadlineLineReader, cmd: str) -> str:
    assert proc.stdin is not None
    proc.stdin.write((cmd + "\n").encode("utf-8"))
    proc.stdin.flush()
    return reader.read_line(f"control {cmd!r}", timeout=10.0)


def send_control(proc: subprocess.Popen, reader: DeadlineLineReader, cmd: str) -> str:
    resp = send_control_raw(proc, reader, cmd)
    assert resp.startswith("CONTROL_OK"), f"control {cmd!r} failed: {resp!r}"
    return resp


def parse_window_info(resp: str) -> dict[str, object]:
    # CONTROL_OK window-info driver=cocoa pos=100,80 win=800x540 output=800x540 density=1.0000 display_scale=1.0000 focused=1
    parts = dict(tok.split("=", 1) for tok in resp.split()[2:])
    pos_raw = parts["pos"]
    if pos_raw == "unavailable":
        has_pos = False
        pos_x: int | None = None
        pos_y: int | None = None
    else:
        px_str, py_str = pos_raw.split(",")
        has_pos = True
        pos_x = int(px_str)
        pos_y = int(py_str)
    win_w, win_h = (int(v) for v in parts["win"].split("x"))
    out_w, out_h = (int(v) for v in parts["output"].split("x"))
    focused = parts.get("focused") == "1"
    return {
        "driver": parts["driver"],
        "has_pos": has_pos,
        "pos_x": pos_x,
        "pos_y": pos_y,
        "win_w": win_w,
        "win_h": win_h,
        "out_w": out_w,
        "out_h": out_h,
        "scale_x": out_w / win_w if win_w > 0 else 0.0,
        "scale_y": out_h / win_h if win_h > 0 else 0.0,
        "density": float(parts["density"]),
        "display_scale": float(parts["display_scale"]),
        "focused": focused,
    }


def query_window_info(proc: subprocess.Popen, reader: DeadlineLineReader) -> dict[str, object]:
    return parse_window_info(send_control(proc, reader, "window-info"))


def format_window_metrics(info: dict[str, object]) -> str:
    origin = f"({info['pos_x']},{info['pos_y']})pt" if info.get("has_pos") else "unavailable"
    return (
        f"driver={info['driver']} origin={origin} focused={int(bool(info.get('focused')))} "
        f"win={info['win_w']}x{info['win_h']}pt output={info['out_w']}x{info['out_h']}px "
        f"scale={info['scale_x']:.3f}x{info['scale_y']:.3f} "
        f"density={info['density']:.4f} display_scale={info['display_scale']:.4f}"
    )


def wait_for_native_ready(
    proc: subprocess.Popen | None,
    reader: DeadlineLineReader | None,
    timeout: float = 2.0,
    *,
    stage: str = "startup",
    operator_focus_timeout: float = 0.0,
    query_info_fn=None,
    cue_stream=None,
    poll_interval: float = 0.05,
) -> tuple[dict[str, object], str]:
    """Wait until the host reports both a valid content origin and input focus.

    In unattended mode (operator_focus_timeout == 0), polls up to `timeout`
    seconds with no operator prompt. When operator_focus_timeout > 0, does a
    short initial check and—if the window is still unfocused—prints and flushes
    an operator cue identifying the window and stage, then polls up to
    `operator_focus_timeout` seconds. Returns (info, activation_mode) where
    activation_mode is 'unattended-raise' or 'operator-assisted'.
    """
    read_info = query_info_fn if query_info_fn is not None else (lambda: query_window_info(proc, reader))
    is_ready = lambda d: bool(d.get("has_pos")) and d.get("pos_x") is not None and d.get("pos_y") is not None and bool(d.get("focused"))

    initial_wait = min(timeout, 0.5) if operator_focus_timeout > 0.0 else timeout
    deadline = time.monotonic() + initial_wait
    info = read_info()
    while not is_ready(info) and time.monotonic() < deadline:
        time.sleep(poll_interval)
        info = read_info()
    if is_ready(info):
        return info, "unattended-raise"

    if operator_focus_timeout > 0.0 and not info.get("focused"):
        out = sys.stdout if cue_stream is None else cue_stream
        pid_str = f"pid={proc.pid}, " if proc is not None else ""
        if stage == "post-move-resize":
            reason = "Focus was lost after moving/resizing the window. "
        else:
            reason = ""
        print(
            f"[operator-cue] stage={stage} window={WINDOW_TITLE!r} ({pid_str}{format_window_metrics(info)}): "
            f"{reason}Click the window's title bar once to give it focus, then leave the pointer alone "
            f"(waiting up to {operator_focus_timeout:.1f}s)...",
            file=out,
            flush=True,
        )
        op_deadline = time.monotonic() + operator_focus_timeout
        while not is_ready(info) and time.monotonic() < op_deadline:
            time.sleep(poll_interval)
            info = read_info()
        if is_ready(info):
            print(
                f"[operator-cue] stage={stage} focus acquired ({format_window_metrics(info)}); "
                f"leave pointer alone while CGEvent clicks run.",
                file=out,
                flush=True,
            )
            return info, "operator-assisted"

    if not info.get("has_pos") or info.get("pos_x") is None or info.get("pos_y") is None:
        raise RuntimeError(
            f"[{stage}] native pointer mode requires a valid window content origin ({format_window_metrics(info)})"
        )
    raise RuntimeError(
        f"[{stage}] native pointer mode timed out waiting for input focus ({format_window_metrics(info)})"
    )


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


K_CG_EVENT_LEFT_MOUSE_DOWN = 1
K_CG_EVENT_LEFT_MOUSE_UP = 2
K_CG_EVENT_MOUSE_MOVED = 5
K_CG_MOUSE_BUTTON_LEFT = 0
K_CG_HID_EVENT_TAP = 0


class MacOSNativePointer:
    """Posts native macOS pointer events via CoreGraphics CGEventPost.
    Never falls back to SDL event injection.
    """

    def __init__(self) -> None:
        if sys.platform != "darwin":
            raise RuntimeError(f"--input-mode native requires macOS (current platform: {sys.platform})")
        cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

        cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
        cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cg.CGEventPost.restype = None
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        cf.CFRelease.restype = None

        self.preflight_access: bool | None = None
        if hasattr(cg, "CGPreflightPostEventAccess"):
            cg.CGPreflightPostEventAccess.argtypes = []
            cg.CGPreflightPostEventAccess.restype = ctypes.c_bool
            self.preflight_access = bool(cg.CGPreflightPostEventAccess())

        self.cg = cg
        self.cf = cf

    def _post(self, event_type: int, x: float, y: float) -> None:
        ev = self.cg.CGEventCreateMouseEvent(None, event_type, CGPoint(x, y), K_CG_MOUSE_BUTTON_LEFT)
        if not ev:
            raise RuntimeError(f"CGEventCreateMouseEvent(type={event_type}, x={x:.2f}, y={y:.2f}) returned NULL")
        try:
            self.cg.CGEventPost(K_CG_HID_EVENT_TAP, ev)
        finally:
            self.cf.CFRelease(ev)

    def click_screen(self, screen_x: float, screen_y: float) -> None:
        self._post(K_CG_EVENT_MOUSE_MOVED, screen_x, screen_y)
        time.sleep(0.03)
        self._post(K_CG_EVENT_LEFT_MOUSE_DOWN, screen_x, screen_y)
        time.sleep(0.03)
        self._post(K_CG_EVENT_LEFT_MOUSE_UP, screen_x, screen_y)
        time.sleep(0.08)


def deliver_click(
    proc: subprocess.Popen | None,
    reader: DeadlineLineReader | None,
    info: dict[str, object] | None,
    win_x: float,
    win_y: float,
    native_ptr: object | None,
    query_info_fn=None,
) -> tuple[str, tuple[float, float], dict[str, object] | None]:
    """Deliver a click at logical window coordinates (win_x, win_y).

    In native mode, re-reads current host window-info right before posting,
    refuses to post if origin is unavailable, focus was lost, or layout sizes
    changed since the target was measured, and converts using the latest origin.
    Returns (provenance_label, delivered_coords, live_info).
    """
    if native_ptr is not None:
        if query_info_fn is not None:
            live_info = query_info_fn()
        elif proc is not None and reader is not None:
            live_info = query_window_info(proc, reader)
        else:
            live_info = info
        assert live_info is not None
        if not live_info.get("has_pos") or live_info.get("pos_x") is None or live_info.get("pos_y") is None:
            raise RuntimeError(f"refusing to post native click without a valid window content origin: {live_info}")
        if not live_info.get("focused"):
            raise RuntimeError(f"refusing to post native click to an unfocused window: {live_info}")
        if info is not None:
            expected_sizes = (info["win_w"], info["win_h"], info["out_w"], info["out_h"])
            live_sizes = (live_info["win_w"], live_info["win_h"], live_info["out_w"], live_info["out_h"])
            if live_sizes != expected_sizes:
                raise RuntimeError(
                    f"window/output layout size changed before native click: "
                    f"expected {expected_sizes}, got {live_sizes}"
                )
        screen_x = float(live_info["pos_x"]) + win_x
        screen_y = float(live_info["pos_y"]) + win_y
        native_ptr.click_screen(screen_x, screen_y)
        return "macos-cgevent", (screen_x, screen_y), live_info
    assert proc is not None and reader is not None
    send_control(proc, reader, f"click {win_x:.2f} {win_y:.2f}")
    time.sleep(0.05)
    return "sdl-injected", (win_x, win_y), info


def verify_native_pointer_guards() -> None:
    """Controlled failure and zero-origin checks:
    - Unavailable content origin -> refuses to click; poster receives zero clicks.
    - Unfocused target window -> refuses to click; poster receives zero clicks.
    - Legitimate (0, 0) content origin with focus -> posts exact converted screen point.
    """
    class RecordingPoster:
        def __init__(self) -> None:
            self.calls: list[tuple[float, float]] = []

        def click_screen(self, x: float, y: float) -> None:
            self.calls.append((x, y))

    poster = RecordingPoster()

    # 1. Unavailable origin (SDL_GetWindowPosition returned false).
    unavail = parse_window_info(
        "CONTROL_OK window-info driver=cocoa pos=unavailable win=800x540 output=800x540 density=1.0000 display_scale=1.0000 focused=1"
    )
    assert unavail["has_pos"] is False and unavail["pos_x"] is None and unavail["pos_y"] is None
    try:
        deliver_click(None, None, unavail, 66.5, 211.25, poster)
    except RuntimeError as exc:
        assert "origin" in str(exc), str(exc)
    else:
        raise AssertionError("expected RuntimeError when window origin is unavailable")
    assert len(poster.calls) == 0, f"poster must receive zero clicks on unavailable origin, got {poster.calls}"

    # 2. Unfocused window (SDL_RaiseWindow / focus unavailable).
    unfocused = parse_window_info(
        "CONTROL_OK window-info driver=cocoa pos=100,80 win=800x540 output=800x540 density=1.0000 display_scale=1.0000 focused=0"
    )
    assert unfocused["has_pos"] is True and unfocused["focused"] is False
    try:
        deliver_click(None, None, unfocused, 66.5, 211.25, poster)
    except RuntimeError as exc:
        assert "unfocused" in str(exc), str(exc)
    else:
        raise AssertionError("expected RuntimeError when target window is unfocused")
    assert len(poster.calls) == 0, f"poster must receive zero clicks on unfocused window, got {poster.calls}"

    # 3. Legitimate (0, 0) content origin with focus.
    zero_origin = parse_window_info(
        "CONTROL_OK window-info driver=cocoa pos=0,0 win=800x540 output=800x540 density=1.0000 display_scale=1.0000 focused=1"
    )
    assert zero_origin["has_pos"] is True and zero_origin["pos_x"] == 0 and zero_origin["pos_y"] == 0
    mode, coords, _ = deliver_click(None, None, zero_origin, 66.5, 211.25, poster)
    assert mode == "macos-cgevent" and coords == (66.5, 211.25), (mode, coords)
    assert poster.calls == [(66.5, 211.25)], poster.calls
    print("[native-guards] unavailable origin & unfocused window posted 0 clicks; legitimate (0,0) origin converted cleanly")


def verify_operator_focus_wait() -> None:
    """Controlled tests for opt-in operator-assisted focus waiting:
    1. Delayed focus: prints cue identifying the window and stage, waits until
       focused=1, returns activation='operator-assisted', and posts no click
       before readiness.
    2. Never-acquired focus: times out with the stage name and preserved
       window/output measurements, posting zero test clicks.
    """
    class RecordingPoster:
        def __init__(self) -> None:
            self.calls: list[tuple[float, float]] = []

        def click_screen(self, x: float, y: float) -> None:
            self.calls.append((x, y))

    # 1. Delayed focus (focused=0 for first 3 reads, then focused=1).
    poster = RecordingPoster()
    cue_buf = io.StringIO()
    polls = {"n": 0}

    def delayed_info() -> dict[str, object]:
        polls["n"] += 1
        focused_flag = 1 if polls["n"] >= 4 else 0
        return parse_window_info(
            f"CONTROL_OK window-info driver=cocoa pos=100,80 win=800x540 output=1600x1080 "
            f"density=2.0000 display_scale=2.0000 focused={focused_flag}"
        )

    ready_info, activation = wait_for_native_ready(
        None,
        None,
        timeout=0.02,
        stage="startup",
        operator_focus_timeout=1.0,
        query_info_fn=delayed_info,
        cue_stream=cue_buf,
        poll_interval=0.01,
    )
    assert activation == "operator-assisted", activation
    assert ready_info["focused"] is True and ready_info["out_w"] == 1600
    cue_text = cue_buf.getvalue()
    assert WINDOW_TITLE in cue_text and "stage=startup" in cue_text and "title bar" in cue_text, cue_text
    assert "output=1600x1080px" in cue_text, cue_text
    assert len(poster.calls) == 0, f"no click may be posted before readiness: {poster.calls}"

    mode, coords, _ = deliver_click(None, None, ready_info, 66.5, 211.25, poster, query_info_fn=lambda: ready_info)
    assert mode == "macos-cgevent" and coords == (166.5, 291.25) and len(poster.calls) == 1

    # 2. Never-acquired focus after move/resize: preserves stage & 2x measurements, posts 0 clicks.
    poster2 = RecordingPoster()
    cue_buf2 = io.StringIO()
    always_unfocused = lambda: parse_window_info(
        "CONTROL_OK window-info driver=cocoa pos=152,135 win=640x480 output=1280x960 "
        "density=2.0000 display_scale=2.0000 focused=0"
    )
    try:
        wait_for_native_ready(
            None,
            None,
            timeout=0.02,
            stage="post-move-resize",
            operator_focus_timeout=0.05,
            query_info_fn=always_unfocused,
            cue_stream=cue_buf2,
            poll_interval=0.01,
        )
    except RuntimeError as exc:
        msg = str(exc)
        assert "post-move-resize" in msg, msg
        assert "win=640x480pt" in msg and "output=1280x960px" in msg and "scale=2.000x2.000" in msg, msg
        assert "focused=0" in msg, msg
    else:
        raise AssertionError("expected RuntimeError when focus is never acquired")
    assert "Focus was lost after moving/resizing" in cue_buf2.getvalue(), cue_buf2.getvalue()
    assert len(poster2.calls) == 0, f"zero clicks may be posted on timeout: {poster2.calls}"
    print("[operator-focus-guards] delayed focus acquired & never-focused timeout preserved metrics with 0 premature clicks")


def verify_two_click_native_guards(app_bin: Path, client_bin: Path, capture_dir: Path) -> None:
    """Exercise verify_grapheme_clicks directly with a recording native poster on a
    real dummy-SDL shared-text host to prove per-click host-state re-reads:
    1. Focus loss after click 1 withholds click 2 (only 1 click posted).
    2. Origin move after click 1 (same layout size) converts click 2 with the new origin.
    3. Layout size change after click 1 withholds click 2 (only 1 click posted).
    """
    sock_dir = Path(tempfile.mkdtemp(prefix="dagda-two-click-guards."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "shared.sock"
    proc = None
    try:
        env = dict(os.environ)
        env["SDL_VIDEODRIVER"] = "dummy"
        env.pop("DAGDA_SDL_HIGH_PIXEL_DENSITY", None)
        proc = subprocess.Popen(
            [str(app_bin), "--size", "800x540", "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
            env=env,
        )
        assert proc.stdout is not None
        reader = DeadlineLineReader(proc.stdout)
        wait_for_startup(proc, reader, sock, timeout=10.0)

        el0 = inspect_role(client_bin, sock, "canvas.title")
        b0 = el0["bounds"]
        send_control(proc, reader, f"click {b0['x'] + 2.0:.2f} {b0['y'] + b0['height'] * 0.5:.2f}")
        send_control(proc, reader, f"text Caf{E_ACUTE_DECOMPOSED} ")
        wait_for_role_text(client_bin, sock, "canvas.title", f"Caf{E_ACUTE_DECOMPOSED} Slide Title")

        # Case 1: Focus lost after click 1 -> click 2 must be withheld.
        state = {"focused": True, "dx": 0, "dy": 0, "dw": 0, "reads": 0}

        def read_info() -> dict[str, object]:
            state["reads"] += 1
            base = query_window_info(proc, reader)
            base["focused"] = state["focused"]
            base["has_pos"] = True
            base["pos_x"] = int(base["pos_x"] or 0) + state["dx"]
            base["pos_y"] = int(base["pos_y"] or 0) + state["dy"]
            base["win_w"] = int(base["win_w"]) + state["dw"]
            return base

        class ForwardingPoster:
            def __init__(self, on_after_first) -> None:
                self.calls: list[tuple[float, float]] = []
                self.on_after_first = on_after_first

            def click_screen(self, sx: float, sy: float) -> None:
                self.calls.append((sx, sy))
                cur = query_window_info(proc, reader)
                wx = sx - (int(cur["pos_x"] or 0) + state["dx"])
                wy = sy - (int(cur["pos_y"] or 0) + state["dy"])
                send_control(proc, reader, f"click {wx:.2f} {wy:.2f}")
                time.sleep(0.03)
                if len(self.calls) == 1 and self.on_after_first is not None:
                    self.on_after_first()

        poster_focus = ForwardingPoster(lambda: state.__setitem__("focused", False))
        try:
            verify_grapheme_clicks(
                stage="guard-focus-loss",
                proc=proc,
                reader=reader,
                client_bin=client_bin,
                sock=sock,
                capture_dir=capture_dir,
                prefix_before_e="Caf",
                suffix_after_e=" Slide Title",
                left_marker="[",
                right_marker="]",
                native_ptr=poster_focus,
                require_min_scale=0.0,
                query_info_fn=read_info,
            )
        except RuntimeError as exc:
            assert "unfocused" in str(exc), str(exc)
        else:
            raise AssertionError("expected RuntimeError when focus is lost between click 1 and click 2")
        assert len(poster_focus.calls) == 1, f"second click must be withheld on focus loss: {poster_focus.calls}"
        assert state["reads"] >= 3, f"expected per-click window-info re-reads, got {state['reads']}"

        # Case 2: Only origin shifts (+50, +30) after click 1 -> click 2 uses updated origin and succeeds.
        state.update({"focused": True, "dx": 0, "dy": 0, "dw": 0, "reads": 0})
        poster_move = ForwardingPoster(lambda: (state.__setitem__("dx", 50), state.__setitem__("dy", 30)))
        res_move = verify_grapheme_clicks(
            stage="guard-origin-shift",
            proc=proc,
            reader=reader,
            client_bin=client_bin,
            sock=sock,
            capture_dir=capture_dir,
            prefix_before_e="Caf[",
            suffix_after_e=" Slide Title",
            left_marker="<",
            right_marker=">",
            native_ptr=poster_move,
            require_min_scale=0.0,
            query_info_fn=read_info,
        )
        assert len(poster_move.calls) == 2, poster_move.calls
        # Click 2's y must be shifted by +30 relative to click 1's y (same mid_y, +30 origin shift).
        assert abs((poster_move.calls[1][1] - poster_move.calls[0][1]) - 30.0) <= 0.5, poster_move.calls
        assert res_move["text"].encode("utf-8") == f"Caf[<{E_ACUTE_DECOMPOSED}> Slide Title".encode("utf-8")

        # Case 3: Layout size changes after click 1 -> click 2 must be withheld.
        state.update({"focused": True, "dx": 0, "dy": 0, "dw": 0, "reads": 0})
        poster_resize = ForwardingPoster(lambda: state.__setitem__("dw", -40))
        try:
            verify_grapheme_clicks(
                stage="guard-size-change",
                proc=proc,
                reader=reader,
                client_bin=client_bin,
                sock=sock,
                capture_dir=capture_dir,
                prefix_before_e="Caf[<",
                suffix_after_e="> Slide Title",
                left_marker="(",
                right_marker=")",
                native_ptr=poster_resize,
                require_min_scale=0.0,
                query_info_fn=read_info,
            )
        except RuntimeError as exc:
            assert "size changed" in str(exc), str(exc)
        else:
            raise AssertionError("expected RuntimeError when layout size changes between click 1 and click 2")
        assert len(poster_resize.calls) == 1, f"second click must be withheld on size change: {poster_resize.calls}"

        send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        assert proc.returncode == 0
        proc = None
        print("[two-click-guards] focus-loss withheld click 2; origin-shift converted click 2 with latest origin; size-change withheld click 2")
    finally:
        stop_process(proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


def query_measure(proc: subprocess.Popen, reader: DeadlineLineReader, px: float, text: str) -> float:
    if not text:
        return 0.0
    resp = send_control(proc, reader, f"measure {px:.4f} {text}")
    return float(resp.split()[2])


def inspect_role(client_bin: Path, sock: Path, role: str) -> dict:
    code, resp = run_client(client_bin, sock, "inspect", role)
    assert code == 0 and resp.get("ok") is True and len(resp["elements"]) == 1, (code, resp)
    return resp["elements"][0]


def wait_for_role_text(client_bin: Path, sock: Path, role: str, expected: str, timeout: float = 3.0) -> dict:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        el = inspect_role(client_bin, sock, role)
        last = el
        if el["text"].encode("utf-8") == expected.encode("utf-8"):
            return el
        time.sleep(0.01)
    raise AssertionError(
        f"timed out waiting for {role} == {expected.encode('utf-8')!r}; "
        f"got {last['text'].encode('utf-8')!r}"
    )


def field_text_layout(el: dict) -> tuple[float, float]:
    """Exact logical text_x and px formula matching text_edit_layout."""
    b = el["bounds"]
    cb = el["canvas_bounds"]
    canvas_scale = b["width"] / cb["width"]
    text_scale = min(max(canvas_scale, 0.4), 2.0)
    px = max(24.0 * text_scale, 12.0)
    pad_x = max(16.0 * text_scale, 10.0)
    pad = min(pad_x, max((b["width"] - 2.0) * 0.5, 0.0))
    return b["x"] + pad, px


def verify_grapheme_clicks(
    stage: str,
    proc: subprocess.Popen,
    reader: DeadlineLineReader,
    client_bin: Path,
    sock: Path,
    capture_dir: Path,
    prefix_before_e: str,
    suffix_after_e: str,
    left_marker: str,
    right_marker: str,
    native_ptr: object | None,
    require_min_scale: float,
    query_info_fn=None,
    activation: str = "none",
) -> dict[str, object]:
    read_info = query_info_fn if query_info_fn is not None else (lambda: query_window_info(proc, reader))
    info = read_info()
    if require_min_scale > 0.0:
        assert info["scale_x"] >= require_min_scale and info["scale_y"] >= require_min_scale, (
            f"[{stage}] required min scale {require_min_scale:.2f}x on both axes, "
            f"got scale={info['scale_x']:.3f}x{info['scale_y']:.3f} "
            f"(win={info['win_w']}x{info['win_h']}pt output={info['out_w']}x{info['out_h']}px "
            f"density={info['density']:.4f} display_scale={info['display_scale']:.4f})"
        )
    el = inspect_role(client_bin, sock, "canvas.title")
    b = el["bounds"]
    assert b["x"] > 0 and b["y"] > 0, f"expected translated field origin, got {b}"
    text_x, px = field_text_layout(el)
    mid_y = b["y"] + b["height"] * 0.5

    # Verify left-of-midpoint click on decomposed e + U+0301.
    w_before = query_measure(proc, reader, px, prefix_before_e)
    w_after = query_measure(proc, reader, px, prefix_before_e + E_ACUTE_DECOMPOSED)
    grapheme_w = w_after - w_before
    assert grapheme_w >= 4.0, f"decomposed e+U+0301 advance too small: {grapheme_w}"

    left_edge = text_x + w_before
    click_left_x = left_edge + grapheme_w * 0.25
    click_mode, left_delivered, _ = deliver_click(
        proc, reader, info, click_left_x, mid_y, native_ptr, query_info_fn=read_info
    )

    shot_left = capture_dir / f"{stage}-left-caret.png"
    send_control(proc, reader, f"screenshot {shot_left}")
    png_w, png_h, rgb = decode_png_rgb(shot_left)
    assert (png_w, png_h) == (info["out_w"], info["out_h"]), (
        (png_w, png_h),
        (info["out_w"], info["out_h"]),
    )
    caret_left_px, _ = find_caret_x_pixels(png_w, png_h, rgb, b, info["scale_x"], info["scale_y"])
    caret_left_pt = caret_left_px / info["scale_x"]
    assert abs(caret_left_pt - left_edge) <= 2.0, (
        f"[{stage}] left caret mismatch: painted={caret_left_pt:.2f}pt "
        f"(px={caret_left_px:.1f}, scale_x={info['scale_x']:.3f}) vs expected={left_edge:.2f}pt"
    )

    send_control(proc, reader, f"text {left_marker}")
    expected_after_left = prefix_before_e + left_marker + E_ACUTE_DECOMPOSED + suffix_after_e
    wait_for_role_text(client_bin, sock, "canvas.title", expected_after_left)

    # Verify right-of-midpoint click on decomposed e + U+0301.
    new_prefix = prefix_before_e + left_marker
    w_before_r = query_measure(proc, reader, px, new_prefix)
    w_after_r = query_measure(proc, reader, px, new_prefix + E_ACUTE_DECOMPOSED)
    grapheme_w_r = w_after_r - w_before_r
    assert grapheme_w_r >= 4.0, grapheme_w_r

    right_edge = text_x + w_after_r
    click_right_x = text_x + w_before_r + grapheme_w_r * 0.75
    _, right_delivered, latest_info = deliver_click(
        proc, reader, info, click_right_x, mid_y, native_ptr, query_info_fn=read_info
    )
    if latest_info is not None:
        info = latest_info

    shot_right = capture_dir / f"{stage}-right-caret.png"
    send_control(proc, reader, f"screenshot {shot_right}")
    png_w2, png_h2, rgb2 = decode_png_rgb(shot_right)
    assert (png_w2, png_h2) == (info["out_w"], info["out_h"]), (
        (png_w2, png_h2),
        (info["out_w"], info["out_h"]),
    )
    caret_right_px, _ = find_caret_x_pixels(png_w2, png_h2, rgb2, b, info["scale_x"], info["scale_y"])
    caret_right_pt = caret_right_px / info["scale_x"]
    assert abs(caret_right_pt - right_edge) <= 2.0, (
        f"[{stage}] right caret mismatch: painted={caret_right_pt:.2f}pt "
        f"(px={caret_right_px:.1f}, scale_x={info['scale_x']:.3f}) vs expected={right_edge:.2f}pt"
    )

    send_control(proc, reader, f"text {right_marker}")
    expected_after_right = new_prefix + E_ACUTE_DECOMPOSED + right_marker + suffix_after_e
    el_final = wait_for_role_text(client_bin, sock, "canvas.title", expected_after_right)

    origin_str = f"({info['pos_x']},{info['pos_y']})pt" if info["has_pos"] else "unavailable"
    print(
        f"[{stage}] driver={info['driver']} activation={activation} click_input={click_mode} text_input=sdl-injected "
        f"win_origin={origin_str} focused={int(bool(info['focused']))} win={info['win_w']}x{info['win_h']}pt "
        f"output={info['out_w']}x{info['out_h']}px png={png_w}x{png_h}px "
        f"scale={info['scale_x']:.3f}x{info['scale_y']:.3f} "
        f"density={info['density']:.4f} display_scale={info['display_scale']:.4f} "
        f"field=({b['x']:.2f},{b['y']:.2f},{b['width']:.2f}x{b['height']:.2f}) px={px:.2f} "
        f"left_click=({left_delivered[0]:.2f},{left_delivered[1]:.2f}) "
        f"right_click=({right_delivered[0]:.2f},{right_delivered[1]:.2f}) "
        f"left_caret={caret_left_pt:.2f}pt(px={caret_left_px:.1f},want={left_edge:.2f}pt) "
        f"right_caret={caret_right_pt:.2f}pt(px={caret_right_px:.1f},want={right_edge:.2f}pt) "
        f"utf8={el_final['text'].encode('utf-8').hex(' ')}"
    )
    return {"info": info, "bounds": b, "text": el_final["text"]}


def main() -> int:
    parser = argparse.ArgumentParser(description="Cocoa / native-window caret and grapheme hit-test probe")
    parser.add_argument("--require-driver", default="", help="Fail if SDL_GetCurrentVideoDriver() does not match")
    parser.add_argument(
        "--input-mode",
        choices=("sdl", "native"),
        default="sdl",
        help="Click delivery mode: 'sdl' (SDL_PushEvent in logical points) or 'native' (macOS CGEventPost; no fallback)",
    )
    parser.add_argument(
        "--require-min-scale",
        type=float,
        default=0.0,
        help="Fail if output/window pixel ratio on either axis is below this value (e.g. 2.0 for Retina; no fallback)",
    )
    parser.add_argument(
        "--high-density",
        action="store_true",
        help="Opt-in experiment: set DAGDA_SDL_HIGH_PIXEL_DENSITY=1 when launching the host window",
    )
    parser.add_argument(
        "--wait-for-focus",
        type=float,
        default=0.0,
        help="Opt-in desktop mode: wait up to N seconds for the operator to click the window title bar for focus (0=unattended CI)",
    )
    parser.add_argument("--capture-dir", default="", help="Directory for PNG captures")
    args = parser.parse_args()
    if args.wait_for_focus < 0.0:
        parser.error("--wait-for-focus must be >= 0")

    native_ptr: MacOSNativePointer | None = None
    if args.input_mode == "native":
        native_ptr = MacOSNativePointer()
        print(
            f"[native-pointer] CoreGraphics loaded; CGPreflightPostEventAccess={native_ptr.preflight_access} "
            f"(high_density_opt_in={args.high_density})"
        )

    capture_dir = Path(args.capture_dir) if args.capture_dir else ROOT / "build" / "cocoa-caret-capture"
    capture_dir.mkdir(parents=True, exist_ok=True)

    build_dir = ROOT / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    app_bin = build_dir / "shared-text"
    client_bin = build_dir / "dagda-client"

    subprocess.check_call([str(ODIN), "build", "examples/shared-text", "-collection:dagda=.", f"-out:{app_bin}"], cwd=ROOT)
    subprocess.check_call([str(ODIN), "build", "examples/dagda-client", "-collection:dagda=.", f"-out:{client_bin}"], cwd=ROOT)

    verify_startup_timeout_bounded()
    verify_native_pointer_guards()
    verify_operator_focus_wait()
    verify_two_click_native_guards(app_bin, client_bin, capture_dir)

    sock_dir = Path(tempfile.mkdtemp(prefix="dagda-cocoa-caret."))
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "shared.sock"
    proc = None
    try:
        env = dict(os.environ)
        if args.high_density:
            env["DAGDA_SDL_HIGH_PIXEL_DENSITY"] = "1"
        else:
            env.pop("DAGDA_SDL_HIGH_PIXEL_DENSITY", None)

        proc = subprocess.Popen(
            [str(app_bin), "--size", "800x540", "--socket", str(sock), "--control-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=ROOT,
            env=env,
        )
        assert proc.stdout is not None
        reader = DeadlineLineReader(proc.stdout)
        wait_for_startup(proc, reader, sock, timeout=10.0)

        # Verify out-of-range move-window coordinates are rejected by the live host.
        bad_move = send_control_raw(proc, reader, "move-window 4294967296 4294967296")
        assert bad_move == "CONTROL_ERR invalid move-window", f"unexpected reply for overflow move-window: {bad_move!r}"

        # Settle initial window dimensions and paint the window on screen before any operator cue.
        init_png = capture_dir / "00-init.png"
        prev_info = None
        for _ in range(10):
            send_control(proc, reader, f"screenshot {init_png}")
            cur_info = query_window_info(proc, reader)
            if prev_info == cur_info:
                break
            prev_info = cur_info
            time.sleep(0.05)

        activation_stage1 = "none"
        if native_ptr is not None:
            send_control(proc, reader, "raise")
            info0, activation_stage1 = wait_for_native_ready(
                proc,
                reader,
                timeout=2.0,
                stage="startup",
                operator_focus_timeout=args.wait_for_focus,
            )
        else:
            info0 = query_window_info(proc, reader)

        origin0_str = f"({info0['pos_x']},{info0['pos_y']})pt" if info0["has_pos"] else "unavailable"
        print(
            f"[startup] driver={info0['driver']} activation={activation_stage1} high_density_opt_in={args.high_density} "
            f"win_origin={origin0_str} focused={int(bool(info0['focused']))} win={info0['win_w']}x{info0['win_h']}pt "
            f"output={info0['out_w']}x{info0['out_h']}px scale={info0['scale_x']:.3f}x{info0['scale_y']:.3f} "
            f"density={info0['density']:.4f} display_scale={info0['display_scale']:.4f}"
        )
        if args.require_driver:
            assert info0["driver"] == args.require_driver, (
                f"expected SDL video driver {args.require_driver!r}, got {info0['driver']!r}"
            )
        if args.require_min_scale > 0.0:
            assert info0["scale_x"] >= args.require_min_scale and info0["scale_y"] >= args.require_min_scale, (
                f"required min scale {args.require_min_scale:.2f}x on both axes, "
                f"got scale={info0['scale_x']:.3f}x{info0['scale_y']:.3f} "
                f"(win={info0['win_w']}x{info0['win_h']}pt output={info0['out_w']}x{info0['out_h']}px "
                f"density={info0['density']:.4f} display_scale={info0['display_scale']:.4f})"
            )

        # Insert decomposed "Cafe\u0301 " at start of canvas.title using pointer click + TEXT_INPUT.
        el0 = inspect_role(client_bin, sock, "canvas.title")
        b0 = el0["bounds"]
        deliver_click(proc, reader, info0, b0["x"] + 2.0, b0["y"] + b0["height"] * 0.5, native_ptr)
        send_control(proc, reader, f"text Caf{E_ACUTE_DECOMPOSED} ")
        wait_for_role_text(client_bin, sock, "canvas.title", f"Caf{E_ACUTE_DECOMPOSED} Slide Title")

        # Stage 1: Initial 800x540 window.
        res1 = verify_grapheme_clicks(
            stage="initial-800x540",
            proc=proc,
            reader=reader,
            client_bin=client_bin,
            sock=sock,
            capture_dir=capture_dir,
            prefix_before_e="Caf",
            suffix_after_e=" Slide Title",
            left_marker="[",
            right_marker="]",
            native_ptr=native_ptr,
            require_min_scale=args.require_min_scale,
            activation=activation_stage1,
        )

        # Stage 2: Move (under native mode) and resize to 640x480, wait for Cocoa/WM to settle,
        # then reacquire window origin & field bounds and repeat clicks.
        if native_ptr is not None:
            assert res1["info"]["has_pos"] and res1["info"]["pos_x"] is not None and res1["info"]["pos_y"] is not None
            new_pos_x = int(res1["info"]["pos_x"]) + 40
            new_pos_y = int(res1["info"]["pos_y"]) + 40
            send_control(proc, reader, f"move-window {new_pos_x} {new_pos_y}")
            send_control(proc, reader, "raise")
        send_control(proc, reader, "resize 640x480")
        deadline = time.monotonic() + 2.0
        el_after_resize = inspect_role(client_bin, sock, "canvas.title")
        while el_after_resize["bounds"] == res1["bounds"] and time.monotonic() < deadline:
            time.sleep(0.05)
            send_control(proc, reader, f"screenshot {capture_dir / '01-resize-settle.png'}")
            el_after_resize = inspect_role(client_bin, sock, "canvas.title")
        assert el_after_resize["bounds"] != res1["bounds"], (
            f"field bounds did not change after resize: {el_after_resize['bounds']}"
        )
        activation_stage2 = "none"
        if native_ptr is not None:
            _, activation_stage2 = wait_for_native_ready(
                proc,
                reader,
                timeout=2.0,
                stage="post-move-resize",
                operator_focus_timeout=args.wait_for_focus,
            )

        res2 = verify_grapheme_clicks(
            stage="resized-640x480",
            proc=proc,
            reader=reader,
            client_bin=client_bin,
            sock=sock,
            capture_dir=capture_dir,
            prefix_before_e="Caf[",
            suffix_after_e="] Slide Title",
            left_marker="<",
            right_marker=">",
            native_ptr=native_ptr,
            require_min_scale=args.require_min_scale,
            activation=activation_stage2,
        )
        assert res2["bounds"] != res1["bounds"]

        send_control(proc, reader, "quit")
        proc.wait(timeout=5)
        assert proc.returncode == 0 and not sock.exists()
        proc = None
        print("cocoa_caret_probe: PASS")
        return 0
    finally:
        stop_process(proc)
        shutil.rmtree(sock_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
