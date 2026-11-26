#!/usr/bin/env python3
"""Verify hit-test through a real dagda-client at two viewport
sizes: the same canvas point hits the same element a pointer
would, in logical window coordinates as reported by inspect."""
import json, os, select, shutil, subprocess, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
ODIN = ROOT / "scripts" / "odin.sh"

def start(host, sock, w, h):
    sock_dir = sock.parent; sock_dir.mkdir(exist_ok=True); os.chmod(sock_dir, 0o700)
    proc = subprocess.Popen([str(host), str(sock), str(w), str(h)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=ROOT)
    fd, buf, deadline = proc.stdout.fileno(), b"", time.monotonic() + 10
    while b"\n" not in buf:
        left = deadline - time.monotonic()
        if left <= 0: raise AssertionError("startup timeout")
        ready, _, _ = select.select([fd], [], [], left)
        if not ready: raise AssertionError("startup timeout")
        chunk = os.read(fd, 4096)
        if not chunk: raise AssertionError("host closed stdout")
        buf += chunk
    assert buf.decode().strip() == f"Listening {sock}"
    return proc

def client(client_bin, sock, *args, expect_ok=True):
    r = subprocess.run([str(client_bin), str(sock), *args], capture_output=True, text=True, timeout=15)
    if expect_ok: assert r.returncode == 0, (args, r.stdout, r.stderr)
    return r.returncode, (json.loads(r.stdout) if r.stdout.strip() else {})

def inspect(client_bin, sock, role):
    _, resp = client(client_bin, sock, "inspect", role)
    return resp["elements"][0]

def main():
    tmp = Path(tempfile.mkdtemp(prefix="dagda-hit-test-"))
    try:
        host, client_bin = tmp / "hit-host", tmp / "dagda-client"
        for src, out in [("dagda/driver/tests/hit_host", host), ("examples/dagda-client", client_bin)]:
            subprocess.check_call([str(ODIN), "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
        for width, height in [(1200, 540), (720, 540)]:
            sock = tmp / f"sock-{width}" / "app.sock"
            proc = start(host, sock, width, height)
            try:
                over = inspect(client_bin, sock, "over")
                b = over["bounds"]
                centre = (b["x"] + b["width"] / 2, b["y"] + b["height"] / 2)
                _, hit = client(client_bin, sock, "hit-test", str(centre[0]), str(centre[1]))
                assert hit == {"ok": True, "id": 2}, hit  # overlap: topmost, same as a pointer
                # A point only in the under element (ID 0 is valid):
                u = inspect(client_bin, sock, "under")["bounds"]
                _, hit0 = client(client_bin, sock, "hit-test", str(u["x"] + 5), str(u["y"] + 5))
                assert hit0 == {"ok": True, "id": 0}, hit0
                _, miss = client(client_bin, sock, "hit-test", "2", "2")
                assert miss == {"ok": True, "id": None}, miss  # letterbox / outside at this size may vary; 2,2 is outside canvas sheet only at wide sizes
                code, bad = client(client_bin, sock, "hit-test", "abc", "1", expect_ok=False)
                assert code == 2 or bad.get("ok") is False, (code, bad)
            finally:
                proc.terminate(); proc.wait(timeout=10)
        print("hit-test client checks passed at two viewport sizes")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

if __name__ == "__main__":
    raise SystemExit(main())
