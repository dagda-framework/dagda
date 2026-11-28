#!/usr/bin/env python3
"""Windows local-transport proof (also runnable on POSIX).

Builds the windows_host fixture and the real dagda-client,
then, over a Winsock AF_UNIX (or POSIX Unix) socket file:

1. a separate client process inspects and invokes a target,
   and re-inspects the changed state;
2. a second server cannot take over the live endpoint, and
   the first server keeps serving;
3. a clean shutdown removes the endpoint and a restart on
   the same path succeeds.

    python3 dagda/driver/tests/windows_transport_test.py

ODIN points at the Odin compiler (odin.exe on Windows).
"""
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ODIN = os.environ.get("ODIN") or str(ROOT / "scripts" / "odin.sh")
EXE = ".exe" if os.name == "nt" else ""


def read_line(proc, stage, timeout=10.0):
    # A thread does the blocking read: select() on a pipe is
    # not available on Windows.
    import threading
    box = {}

    def _read():
        try:
            box["line"] = proc.stdout.readline()
        except Exception as exc:  # noqa: BLE001
            box["error"] = exc

    worker = threading.Thread(target=_read, daemon=True)
    worker.start()
    worker.join(timeout)
    if worker.is_alive():
        raise TimeoutError(f"timed out waiting for {stage}")
    if "error" in box:
        raise AssertionError(f"host stdout failed during {stage}: {box['error']!r}")
    line = box.get("line") or b""
    if not line:
        raise AssertionError(f"host closed stdout during {stage}")
    return line.decode().rstrip("\r\n")


def stop(proc):
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


def client(client_bin, sock, *args):
    done = subprocess.run([str(client_bin), str(sock), *args], capture_output=True, text=True, timeout=10)
    assert done.stdout.strip(), f"empty client reply for {args}: {done.stderr!r}"
    return done.returncode, json.loads(done.stdout)


def inspect_text(client_bin, sock):
    code, resp = client(client_bin, sock, "inspect", "win.target")
    assert code == 0 and resp["ok"] is True, resp
    return resp["elements"][0]["text"]


def start(host_bin, sock, stop_file):
    proc = subprocess.Popen([str(host_bin), str(sock), str(stop_file)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    try:
        line = read_line(proc, "startup")
        assert line == f"Listening {sock}", line
        return proc
    except BaseException:
        stop(proc)
        raise


def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-windows-transport."))
    proc = None
    try:
        host_bin, client_bin = tmp / f"windows-host{EXE}", tmp / f"dagda-client{EXE}"
        for src, out in [("dagda/driver/tests/windows_host", host_bin), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([ODIN, "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
        sock_dir = tmp / "sock"
        sock_dir.mkdir()
        sock = sock_dir / "app.sock"
        stop_file = tmp / "stop"

        proc = start(host_bin, sock, stop_file)
        assert inspect_text(client_bin, sock) == "count=0"
        code, inv = client(client_bin, sock, "invoke", "7", "activate")
        assert code == 0 and inv["ok"] is True, inv
        assert inspect_text(client_bin, sock) == "count=1"
        print("inspect/invoke from a separate client process: ok")

        second = subprocess.Popen([str(host_bin), str(sock), str(stop_file)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        try:
            rc = second.wait(timeout=10)
            assert rc != 0, "second server unexpectedly took over the live endpoint"
        finally:
            stop(second)
        assert inspect_text(client_bin, sock) == "count=1"
        print("second server cannot take over the live endpoint: ok")

        stop_file.write_text("stop")
        rc = proc.wait(timeout=10)
        proc = None
        assert rc == 0, f"clean shutdown exited {rc}"
        assert not sock.exists(), f"endpoint left behind after clean shutdown: {sock}"
        print("clean shutdown removed the endpoint: ok")

        proc = start(host_bin, sock, stop_file.with_name("stop2"))
        assert inspect_text(client_bin, sock) == "count=0"
        code, inv = client(client_bin, sock, "invoke", "7", "activate")
        assert code == 0 and inv["ok"] is True, inv
        assert inspect_text(client_bin, sock) == "count=1"
        stop_file.with_name("stop2").write_text("stop")
        rc = proc.wait(timeout=10)
        proc = None
        assert rc == 0
        print("restart on the same path after clean shutdown: ok")
        print(f"windows transport proof passed (platform={sys.platform}, arch={os.environ.get('PROCESSOR_ARCHITECTURE', '?')})")
        return 0
    finally:
        stop(proc)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
