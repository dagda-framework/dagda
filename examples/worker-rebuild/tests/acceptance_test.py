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
        # Publish a different element through the same worker
        # path while this composition is active (second trigger).
        app.fire("other")
        assert app.wait_text("worker.other", "other 1")["text"] == "other 1"
        app.wait_present("other")
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
