#!/usr/bin/env python3
"""Docs smoke test: build the first-app guide exactly as published.

Extracts the guide's Odin snippet verbatim into a fresh
my-counter project beside a temporary Dagda root whose build/
directory starts absent, then runs the guide's first two shell
build blocks in order, in ONE Bash process (the first block
does `cd my-counter`, and the guide promises the reader is
still there for the second). The commands are read from the
guide, so future documentation edits are exercised too.

The temporary Dagda root is assembled from symlinks to the
real checkout's sources plus its own real (initially absent)
build/ directory. The test only ever removes the temporary
tree it created; the caller's checkout build/ is never touched.
"""
import json
import os
import re
import select
import shutil
import stat
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUIDE = Path(os.environ.get("GUIDE_PATH", ROOT / "docs" / "first-app.md"))


def fenced_blocks(text, lang):
    return re.findall(rf"```{lang}\n(.*?)```", text, re.S)


def main():
    guide = GUIDE.read_text()
    snippets = fenced_blocks(guide, "odin")
    assert len(snippets) == 1, f"expected exactly one published Odin snippet, found {len(snippets)}"
    build_section = guide.split("## Build and run", 1)[1]
    blocks = fenced_blocks(build_section, "sh")
    assert len(blocks) >= 2, "guide is missing its two build blocks"

    tmp = Path(tempfile.mkdtemp(prefix="dagda-first-app-smoke-"))
    try:
        # Temporary Dagda root beside my-counter: source entries
        # are symlinks into the real checkout; build/ is the
        # test's own real directory and starts absent.
        dagda_root = tmp / "dagda"
        dagda_root.mkdir()
        for name in ("scripts", "dagda", "examples", ".tools", "dagda.lock"):
            (dagda_root / name).symlink_to(ROOT / name, target_is_directory=(ROOT / name).is_dir())
        project = tmp / "my-counter"
        project.mkdir()
        (project / "main.odin").write_text(snippets[0])

        env = {**os.environ, "DAGDA": str(dagda_root)}
        script = "\n".join(blocks[:2])  # one Bash process for both blocks
        subprocess.check_call(["bash", "-e", "-c", script], cwd=tmp, env=env)

        app_bin = project / "my-counter"
        client_bin = dagda_root / "build" / "dagda-client"
        for binary in (app_bin, client_bin):
            mode = binary.stat().st_mode
            assert stat.S_ISREG(mode) and os.access(binary, os.X_OK), \
                f"{binary} is not a regular executable file (mode {oct(mode)})"
        print(f"first-app smoke: built {app_bin} and {client_bin} from the published guide")
        run_counter(app_bin, client_bin, tmp)
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


class Reader:
    def __init__(self, proc):
        self.fd, self.buf = proc.stdout.fileno(), b""

    def line(self, timeout=10):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buf:
            left = deadline - time.monotonic()
            if left <= 0:
                raise AssertionError("timed out waiting for guide app")
            ready, _, _ = select.select([self.fd], [], [], left)
            if not ready:
                raise AssertionError("timed out waiting for guide app")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise AssertionError("guide app closed stdout")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode().strip()


def run_counter(app_bin, client_bin, tmp):
    sock_dir = tmp / "sock"
    sock_dir.mkdir()
    os.chmod(sock_dir, 0o700)
    sock = sock_dir / "counter.sock"
    env = {**os.environ, "SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy"}
    proc = subprocess.Popen([str(app_bin), "--socket", str(sock), "--control-stdin"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, bufsize=0, env=env)
    reader = Reader(proc)

    def cleanup():
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)

    def control(cmd):
        proc.stdin.write((cmd + "\n").encode())
        proc.stdin.flush()
        line = reader.line()
        assert line.startswith("CONTROL_OK"), (cmd, line)
        return line

    def client(*args):
        r = subprocess.run([str(client_bin), str(sock), *args], capture_output=True, text=True, timeout=10)
        assert r.returncode == 0, (args, r.stdout, r.stderr)
        return json.loads(r.stdout)

    def count():
        return client("inspect", "counter.value")["elements"][0]["text"]

    try:
        assert reader.line() == f"Listening {sock}"
        button = client("inspect", "counter.increment")["elements"][0]
        bounds = button["bounds"]
        cx = bounds["x"] + bounds["width"] / 2
        cy = bounds["y"] + bounds["height"] / 2
        hit = client("hit-test", str(cx), str(cy))
        assert hit == {"ok": True, "id": button["id"]}, hit
        assert count() == "0", count()  # hit-test changed nothing
        control(f"click {cx:.2f} {cy:.2f}")
        assert count() == "1", count()
        client("invoke", str(button["id"]), "activate")
        assert count() == "2", count()
        control("quit")
        status = proc.wait(timeout=10)
        assert status == 0, f"guide app exited with status {status} after quit"
        assert not sock.exists()
        print(f"first-app runtime: hit-test id={button['id']}, click -> 1, invoke -> 2, clean shutdown")
    finally:
        cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
