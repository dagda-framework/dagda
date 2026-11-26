#!/usr/bin/env python3
"""Idle-window rebuild acceptance.

A real worker thread publishes a model update under the app's
mutex and calls sdlhost.request_rebuild. With no synthetic
input, expose, resize, or driver action between publication
and presentation, the changed label must be presented (proven
passively through the app's on_present file) and inspected.
Also covers preedit survival, stale handles, and the negative
control where the worker publishes without requesting.
"""
import json
import os
import select
import struct
import zlib
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ODIN = ROOT / "scripts" / "odin.sh"


class Reader:
    def __init__(self, proc):
        self.fd, self.buf = proc.stdout.fileno(), b""

    def line(self, timeout=10):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buf:
            left = deadline - time.monotonic()
            if left <= 0:
                raise AssertionError("timed out waiting for app")
            ready, _, _ = select.select([self.fd], [], [], left)
            if not ready:
                raise AssertionError("timed out waiting for app")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise AssertionError("app closed stdout")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode().strip()


def cleanup(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


class App:
    def __init__(self, app_bin, client_bin, tmp, name, env_extra):
        self.dir = tmp / name
        self.dir.mkdir()
        os.chmod(self.dir, 0o700)
        self.sock = self.dir / "app.sock"
        self.present = self.dir / "present.txt"
        self.result = self.dir / "result.txt"
        self.trigger = self.dir / "trigger"
        self.handle_file = self.dir / "handle.txt"
        env = {**os.environ, "SDL_VIDEODRIVER": os.environ.get("SDL_VIDEODRIVER", "dummy"),
               "SDL_AUDIODRIVER": "dummy", "PRESENT_FILE": str(self.present),
               "RESULT_FILE": str(self.result), "TRIGGER_FILE": str(self.trigger),
               "HANDLE_FILE": str(self.handle_file), **env_extra}
        self.proc = subprocess.Popen([str(app_bin), "--socket", str(self.sock), "--control-stdin"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, bufsize=0, env=env, cwd=ROOT)
        self.reader = Reader(self.proc)
        self.client_bin = client_bin
        assert self.reader.line() == f"Listening {self.sock}"

    def control(self, cmd):
        self.proc.stdin.write((cmd + "\n").encode())
        self.proc.stdin.flush()
        line = self.reader.line()
        assert line.startswith("CONTROL_OK"), (cmd, line)
        return line

    def client(self, *args):
        r = subprocess.run([str(self.client_bin), str(self.sock), *args], capture_output=True, text=True, timeout=10)
        assert r.returncode == 0, (args, r.stdout, r.stderr)
        return json.loads(r.stdout)

    def inspect(self, role):
        return self.client("inspect", role)["elements"][0]

    def wait_text(self, role, text, timeout=5):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            last = self.inspect(role)
            if last["text"] == text:
                return last
            time.sleep(0.02)
        raise AssertionError(f"timed out waiting for {role} == {text!r}; last={last}")

    def wait_present(self, needle, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.present.exists() and needle in self.present.read_text():
                return self.present.read_text()
            time.sleep(0.02)
        raise AssertionError(f"timed out waiting for presentation of {needle!r}")

    def fire(self, content="go"):
        self.trigger.write_text(content)

    def close_window(self):
        self.control("quit")

    def quit(self):
        self.control("quit")
        self.proc.wait(timeout=10)


def count_preedit_pixels(path, bounds):
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
        filt = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if filt == 1: line[i] = (line[i] + a) & 0xFF
            elif filt == 2: line[i] = (line[i] + b) & 0xFF
            elif filt == 3: line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filt == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        px[y * stride:(y + 1) * stride] = line
        prev = line
    x0, y0 = int(bounds["x"]), int(bounds["y"])
    x1, y1 = int(bounds["x"] + bounds["width"]), int(bounds["y"] + bounds["height"])
    hits = 0
    for y in range(max(0, y0), min(h, y1)):
        for x in range(max(0, x0), min(w, x1)):
            rgb = tuple(px[(y * w + x) * bpp:(y * w + x) * bpp + 3])
            if all(abs(a - b) <= 4 for a, b in zip(rgb, (62, 78, 118))):
                hits += 1
    return hits


def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-worker-rebuild-"))
    apps = []
    try:
        app_bin, client_bin = tmp / "worker-rebuild", tmp / "dagda-client"
        for src, out in [("examples/worker-rebuild", app_bin), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)

        # 1. Idle window: worker publishes and requests; the new
        # label is presented with no intervening input of any kind.
        app = App(app_bin, client_bin, tmp, "idle", {"WORKER_MODE": "request"})
        apps.append(app)
        assert app.inspect("worker.label")["text"] == "tick 0"
        app.wait_present("tick 0")
        app.fire()
        presented = app.wait_present("tick 1")
        assert app.inspect("worker.label")["text"] == "tick 1"
        fields = dict(part.split("=", 1) for part in presented.split() if "=" in part)
        assert fields["builder"] == fields["host"] != "0", presented  # builder ran on the host thread
        assert "result=Posted" in app.result.read_text()
        print(f"[1] idle rebuild presented: {presented.strip()}")

        # 2. Focused editable field with selection + preedit: a
        # worker update to a different element preserves them,
        # and the input session finishes normally.
        field = app.inspect("worker.field")
        fb = field["bounds"]
        app.control(f"click {fb['x'] + fb['width'] - 5:.2f} {fb['y'] + fb['height'] / 2:.2f}")
        app.control("key shift+left")
        app.control("preedit X")
        shot = app.dir / "before-worker.png"
        deadline = time.monotonic() + 5
        while True:
            app.control(f"screenshot {shot}")
            if count_preedit_pixels(shot, fb) >= 20:
                break
            assert time.monotonic() < deadline, "preedit never became visible before worker publication"
        # Publish a different element through the same worker
        # path while this composition is active (second trigger).
        app.fire("other")
        assert app.wait_text("worker.other", "other 1")["text"] == "other 1"
        app.wait_present("other 1")
        # Observe the active composing field/preedit after the
        # worker presentation, before sending any final text.
        # If a rebuild cancelled the composition, this fails.
        shot = app.dir / "after-worker.png"
        app.control(f"screenshot {shot}")
        hits = count_preedit_pixels(shot, fb)
        assert hits >= 20, f"composition was lost across the worker rebuild (preedit pixels={hits})"
        print(f"[2] composing field/preedit still active after worker presentation (preedit pixels={hits})")
        # Finish the composition normally at the intended place.
        app.control("key enter")
        app.control("text Y")
        assert app.wait_text("worker.field", "FielY")["text"] == "FielY"
        print("[2] editable session finished normally after the worker-presented frame")

        app.quit()
        apps.remove(app)

        # 3. Negative control: publish without requesting stays stale.
        neg = App(app_bin, client_bin, tmp, "negative", {"WORKER_MODE": "publish"})
        apps.append(neg)
        neg.wait_present("tick 0")
        time.sleep(1.5)  # let any compositor map/expose events settle first
        neg.fire()
        time.sleep(1.0)
        assert neg.inspect("worker.label")["text"] == "tick 0"
        assert "tick 1" not in (neg.present.read_text() if neg.present.exists() else "")
        print("[3] negative control: published tick 1 stayed unpresented at tick 0")
        neg.quit()
        apps.remove(neg)

        # 4. Window identity in one process: window 1 closes,
        # a late request is safe, then window 2 (a new generation
        # in the same process) is never woken by window 1's handle.
        dual = App(app_bin, client_bin, tmp, "dual", {"WORKER_MODE": "idle", "LATE_REQUEST": "1", "TWO_WINDOWS": "1"})
        apps.append(dual)
        dual.close_window()  # first window closes; the app starts window 2
        assert dual.reader.line() == f"Listening {dual.sock}"
        assert "late result=Stale" in dual.result.read_text(), dual.result.read_text()
        dual.fire()
        deadline = time.monotonic() + 5
        while "stale" not in (dual.result.read_text() if dual.result.exists() else "") and time.monotonic() < deadline:
            time.sleep(0.02)
        assert "stale result=Stale" in dual.result.read_text(), dual.result.read_text()
        assert dual.inspect("worker.label")["text"] == "tick 0"
        print("[4] stale handle never woke the later window; late request was safe")
        dual.quit()
        apps.remove(dual)

        print("worker rebuild acceptance: all checks passed")
        return 0
    finally:
        for app in apps:
            cleanup(app.proc)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
