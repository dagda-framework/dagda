#!/usr/bin/env python3
"""End-to-end tests for the local title driver.

Builds the real host and client with the pinned Odin compiler, then
drives one host process through separate client processes and raw
socket checks. Each run uses a temporary socket directory.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
ODIN = os.path.join(ROOT, "scripts", "odin.sh")

FIXTURES = [
    ('{"op":"inspect","role":"slide.title"}',
     '{"ok":true,"id":1,"revision":0,"text":"Quarterly results","role":"slide.title"}'),
    ('{"op":"preview","id":1,"base_revision":0,"text":"Revenue grew 12%"}',
     '{"ok":true,"id":1,"revision":0,"text":"Revenue grew 12%"}'),
    ('{"op":"commit","id":1,"base_revision":0,"text":"Revenue grew 12%"}',
     '{"ok":true,"id":1,"revision":1,"text":"Revenue grew 12%"}'),
    ('{"op":"commit","id":1,"base_revision":0,"text":"Late edit"}',
     '{"ok":false,"error":"Stale_Revision","revision":1}'),
    ('{"op":"undo","id":1,"base_revision":1}',
     '{"ok":true,"id":1,"revision":2,"text":"Quarterly results","changed":true}'),
]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30, **kw)


def build(out_dir):
    host = os.path.join(out_dir, "title-host")
    client = os.path.join(out_dir, "title-client")
    for src, out in [("examples/title-driver-host", host),
                     ("examples/title-driver-client", client)]:
        r = run([ODIN, "build", src, "-collection:dagda=.", f"-out:{out}"], cwd=ROOT)
        assert r.returncode == 0, f"build {src} failed:\n{r.stdout}{r.stderr}"
    return host, client


def client(client_bin, sock, *args, expect_ok=True):
    r = run([client_bin, sock, *args])
    if expect_ok:
        assert r.returncode == 0, f"client {args} rc={r.returncode}: {r.stdout}{r.stderr}"
    return r.stdout.strip(), r.returncode


def raw_exchange(sock_path, chunks, replies=1):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect(sock_path)
        for chunk in chunks:
            s.sendall(chunk)
            time.sleep(0.05)
        data = b""
        while data.count(b"\n") < replies:
            part = s.recv(4096)
            if not part:
                break
            data += part
        return data.decode().strip().splitlines()


def main():
    tmp = tempfile.mkdtemp(prefix="dagda-driver-test-")
    sock_dir = os.path.join(tmp, "sockets")
    os.mkdir(sock_dir)
    sock = os.path.join(sock_dir, "title.sock")
    host = client_bin = None
    proc = None
    try:
        host, client_bin = build(tmp)
        proc = subprocess.Popen([host, sock], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        for _ in range(100):
            if os.path.exists(sock):
                break
            if proc.poll() is not None:
                raise AssertionError(f"host exited early: {proc.stdout.read()}")
            time.sleep(0.05)
        assert os.path.exists(sock), "host did not create socket"

        # Real client processes against one retained host/model, in
        # fixture order: discover, preview (no mutation), commit,
        # stale rejection, undo to revision 2, inspect from a new client.
        out, _ = client(client_bin, sock, "inspect", "slide.title")
        assert out == FIXTURES[0][1], out
        out, _ = client(client_bin, sock, "preview", "1", "0", "Revenue grew 12%")
        assert out == FIXTURES[1][1], out
        out, _ = client(client_bin, sock, "inspect", "slide.title")
        assert out == FIXTURES[0][1], f"preview mutated document: {out}"
        out, _ = client(client_bin, sock, "commit", "1", "0", "Revenue grew 12%")
        assert out == FIXTURES[2][1], out
        out, rc = client(client_bin, sock, "commit", "1", "0", "Late edit", expect_ok=False)
        assert rc == 1 and out == FIXTURES[3][1], (rc, out)
        out, _ = client(client_bin, sock, "undo", "1", "1")
        assert out == FIXTURES[4][1], out
        out, _ = client(client_bin, sock, "inspect", "slide.title")
        assert out == '{"ok":true,"id":1,"revision":2,"text":"Quarterly results","role":"slide.title"}', out

        # No-op commit, empty undo, missing role and missing ID.
        out, _ = client(client_bin, sock, "commit", "1", "2", "Quarterly results")
        assert json.loads(out) == {"ok": True, "id": 1, "revision": 2, "text": "Quarterly results"}, out
        out, _ = client(client_bin, sock, "undo", "1", "2")
        assert json.loads(out) == {"ok": True, "id": 1, "revision": 2, "text": "Quarterly results", "changed": False}, out
        out, rc = client(client_bin, sock, "inspect", "slide.missing", expect_ok=False)
        assert rc == 1 and json.loads(out) == {"ok": False, "error": "Unknown_Role"}, out
        out, rc = client(client_bin, sock, "commit", "99", "2", "X", expect_ok=False)
        assert rc == 1 and json.loads(out) == {"ok": False, "error": "Unknown_Object"}, out

        # Raw transport: a line split across reads, then two lines in
        # one read, then a malformed line that must not kill the host.
        lines = raw_exchange(sock, [b'{"op":"inspect","role":"slide.ti', b'tle"}\n'])
        assert json.loads(lines[0])["revision"] == 2, lines
        lines = raw_exchange(sock, [FIXTURES[0][0].encode() + b"\n" + FIXTURES[0][0].encode() + b"\n"], replies=2)
        assert len(lines) == 2, lines
        lines = raw_exchange(sock, [b"this is not json\n", FIXTURES[0][0].encode() + b"\n"], replies=2)
        assert json.loads(lines[0]) == {"ok": False, "error": "Malformed_Request"}, lines
        assert json.loads(lines[1])["ok"] is True, lines

        # Host owns its endpoint: SIGTERM removes the socket file.
        proc.terminate()
        proc.wait(timeout=10)
        assert not os.path.exists(sock), "host left its socket file behind"
        proc = None
        print("e2e: all driver checks passed")
    finally:
        if proc is not None:
            proc.kill()
            proc.wait(timeout=10)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
